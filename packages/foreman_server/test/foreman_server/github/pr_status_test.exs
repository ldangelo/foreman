defmodule ForemanServer.GitHub.PrStatusTest do
  use ExUnit.Case, async: true

  alias ForemanServer.GitHub.PrStatus

  @url "https://github.com/acme/repo/pull/7"

  defp runner(output, code \\ 0), do: fn "gh", _args, _opts -> {output, code} end

  defp payload(state, mergeable) do
    Jason.encode!(%{
      "state" => state,
      "mergeable" => mergeable,
      "headRefOid" => "abc123def456",
      "headRefName" => "foreman/task/run",
      "baseRefName" => "main"
    })
  end

  describe "fetch/2 maps GitHub state to a typed status" do
    test "MERGED is :merged whatever `mergeable` says" do
      assert {:ok, %PrStatus{status: :merged}} =
               PrStatus.fetch(@url, command_runner: runner(payload("MERGED", "UNKNOWN")))
    end

    test "CLOSED without a merge is :closed" do
      assert {:ok, %PrStatus{status: :closed}} =
               PrStatus.fetch(@url, command_runner: runner(payload("CLOSED", "UNKNOWN")))
    end

    test "an OPEN PR with merge conflicts is :conflicted, a clean one is :open" do
      assert {:ok, %PrStatus{status: :conflicted}} =
               PrStatus.fetch(@url, command_runner: runner(payload("OPEN", "CONFLICTING")))

      assert {:ok, %PrStatus{status: :open}} =
               PrStatus.fetch(@url, command_runner: runner(payload("OPEN", "MERGEABLE")))
    end

    test "carries the head sha, head branch and base branch GitHub reported" do
      assert {:ok,
              %PrStatus{
                head_sha: "abc123def456",
                head_branch: "foreman/task/run",
                base_branch: "main"
              }} = PrStatus.fetch(@url, command_runner: runner(payload("OPEN", "MERGEABLE")))
    end

    test "asks gh for exactly the PR url it was given" do
      test_pid = self()

      runner = fn "gh", args, _opts ->
        send(test_pid, {:gh_args, args})
        {payload("OPEN", "MERGEABLE"), 0}
      end

      {:ok, _} = PrStatus.fetch(@url, command_runner: runner)
      assert_received {:gh_args, ["pr", "view", @url, "--json", _fields]}
    end
  end

  describe "fetch/2 never guesses" do
    test "an unrecognised state is an error, not :open" do
      assert {:error, {:gh_unexpected_payload, %{"state" => "DRAFT"}}} =
               PrStatus.fetch(@url, command_runner: runner(payload("DRAFT", "MERGEABLE")))
    end

    test "a payload missing the head sha is an error" do
      body = Jason.encode!(%{"state" => "OPEN", "mergeable" => "MERGEABLE"})

      assert {:error, {:gh_unexpected_payload, _}} =
               PrStatus.fetch(@url, command_runner: runner(body))
    end

    test "a blank head sha is an error, not an empty string carried forward" do
      body =
        Jason.encode!(%{
          "state" => "OPEN",
          "mergeable" => "MERGEABLE",
          "headRefOid" => "",
          "headRefName" => "b",
          "baseRefName" => "main"
        })

      assert {:error, {:gh_unexpected_payload, _}} =
               PrStatus.fetch(@url, command_runner: runner(body))
    end

    test "non-JSON output is :gh_unparsable, distinct from a gh failure" do
      assert {:error, {:gh_unparsable, "not json"}} =
               PrStatus.fetch(@url, command_runner: runner("not json"))
    end

    test "a non-zero gh exit surfaces gh's own message and code" do
      assert {:error, {:gh_failed, 1, "GraphQL: Could not resolve to a PullRequest"}} =
               PrStatus.fetch(@url,
                 command_runner: runner("GraphQL: Could not resolve to a PullRequest\n", 1)
               )
    end
  end

  # foreman-v9y3x: `gh pr view` names a comment's author by login only, and a GraphQL login has
  # no `[bot]` marker, so who is a Bot is read from GraphQL by the comments' node ids.
  describe "fetch/2 with threads: true reads who wrote each conversation comment" do
    defp comment(id, login) do
      %{
        "id" => id,
        "author" => %{"login" => login},
        "body" => "text of #{id}",
        "url" => "https://github.com/acme/repo/pull/7#issuecomment-#{id}",
        "createdAt" => "2026-10-23T00:00:00Z"
      }
    end

    defp view_with(comments) do
      Jason.encode!(%{
        "state" => "OPEN",
        "mergeable" => "MERGEABLE",
        "headRefOid" => "abc123def456",
        "headRefName" => "foreman/task/run",
        "baseRefName" => "main",
        "comments" => comments
      })
    end

    defp nodes(list), do: Jason.encode!(%{"data" => %{"nodes" => list}})
    defp actor(id, type), do: %{"id" => id, "author" => %{"__typename" => type}}

    # `gh pr view` answers with `comments`; every `gh api graphql` call is recorded and
    # answered with `graphql`, an `{output, exit code}` pair.
    defp github(comments, graphql) do
      test_pid = self()

      fn "gh", args, _opts ->
        send(test_pid, {:gh, args})

        case args do
          ["pr", "view" | _] -> {view_with(comments), 0}
          ["api", "graphql" | _] -> graphql
        end
      end
    end

    test "a Bot author is flagged, every other actor is not" do
      runner =
        github(
          [comment("IC_bot", "coderabbitai"), comment("IC_person", "alice")],
          {nodes([actor("IC_bot", "Bot"), actor("IC_person", "User")]), 0}
        )

      assert {:ok, %PrStatus{comments: [bot, person]}} =
               PrStatus.fetch(@url, threads: true, command_runner: runner)

      assert %{id: "IC_bot", author: "coderabbitai", bot: true} = bot
      assert %{id: "IC_person", author: "alice", bot: false} = person

      assert_received {:gh, ["pr", "view" | _]}
      assert_received {:gh, ["api", "graphql" | graphql_args]}
      assert Enum.any?(graphql_args, &String.contains?(&1, "nodes(ids:$ids)"))
      assert "ids[]=IC_bot" in graphql_args
      assert "ids[]=IC_person" in graphql_args
    end

    test "without threads: true the poll stays one call and the author type is unknown" do
      runner = github([comment("IC_1", "alice")], {"unused", 1})

      assert {:ok, %PrStatus{comments: [%{id: "IC_1", bot: nil}]}} =
               PrStatus.fetch(@url, command_runner: runner)

      assert_received {:gh, ["pr", "view" | _]}
      refute_received {:gh, ["api", "graphql" | _]}
    end

    test "a PR with no conversation comment makes no author lookup" do
      runner = github([], {"unused", 1})

      assert {:ok, %PrStatus{comments: []}} =
               PrStatus.fetch(@url, threads: true, command_runner: runner)

      refute_received {:gh, ["api", "graphql" | _]}
    end

    test "a comment deleted since it was listed stays unknown; a deleted author is not a Bot" do
      runner =
        github(
          [comment("IC_gone", "x"), comment("IC_ghost", "ghost")],
          {nodes([nil, %{"id" => "IC_ghost", "author" => nil}]), 0}
        )

      assert {:ok,
              %PrStatus{comments: [%{id: "IC_gone", bot: nil}, %{id: "IC_ghost", bot: false}]}} =
               PrStatus.fetch(@url, threads: true, command_runner: runner)
    end

    test "a lookup that fails or answers garbage is a typed error, never a guessed flag" do
      comments = [comment("IC_1", "alice")]

      assert {:error, {:gh_failed, 1, "GraphQL: rate limited"}} =
               PrStatus.fetch(@url,
                 threads: true,
                 command_runner: github(comments, {"GraphQL: rate limited\n", 1})
               )

      assert {:error, {:gh_unparsable, "not json"}} =
               PrStatus.fetch(@url,
                 threads: true,
                 command_runner: github(comments, {"not json", 0})
               )

      for garbage <- [
            nodes([%{"id" => "IC_1", "author" => %{"login" => "no typename"}}]),
            nodes([%{"not" => "a comment node"}]),
            Jason.encode!(%{"data" => %{}})
          ] do
        assert {:error, {:gh_unexpected_payload, _}} =
                 PrStatus.fetch(@url,
                   threads: true,
                   command_runner: github(comments, {garbage, 0})
                 )
      end
    end
  end

  # TRD-030: `gh pr view` reports whether the token's own user wrote a comment
  # (`viewerDidAuthor`); an absent or non-boolean field is never read as true.
  describe "fetch/2 reads viewer_did_author" do
    defp authored(id, field) do
      Map.merge(comment(id, "foreman-bot"), field)
    end

    defp viewer_flags(comments) do
      assert {:ok, %PrStatus{comments: read}} =
               PrStatus.fetch(@url, command_runner: github(comments, {"unused", 1}))

      Map.new(read, &{&1.id, &1.viewer_did_author})
    end

    test "true only when GitHub says the token's own user wrote the comment" do
      flags =
        viewer_flags([
          authored("IC_own", %{"viewerDidAuthor" => true}),
          authored("IC_other", %{"viewerDidAuthor" => false})
        ])

      assert flags == %{"IC_own" => true, "IC_other" => false}
    end

    test "a comment without the field is not the viewer's, nor is a non-boolean value" do
      flags =
        viewer_flags([
          comment("IC_absent", "alice"),
          authored("IC_null", %{"viewerDidAuthor" => nil}),
          authored("IC_string", %{"viewerDidAuthor" => "true"}),
          authored("IC_one", %{"viewerDidAuthor" => 1})
        ])

      assert flags == %{
               "IC_absent" => false,
               "IC_null" => false,
               "IC_string" => false,
               "IC_one" => false
             }
    end

    test "the flag survives the author lookup of threads: true" do
      runner =
        github(
          [authored("IC_own", %{"viewerDidAuthor" => true}), comment("IC_p", "alice")],
          {nodes([actor("IC_own", "User"), actor("IC_p", "User")]), 0}
        )

      assert {:ok, %PrStatus{comments: [own, person]}} =
               PrStatus.fetch(@url, threads: true, command_runner: runner)

      assert %{id: "IC_own", viewer_did_author: true, bot: false} = own
      assert %{id: "IC_p", viewer_did_author: false, bot: false} = person
    end
  end

  describe "fetch/2 carries the changed paths and the size of the diff" do
    defp file_item(i),
      do: %{
        "path" => "lib/f#{i}.ex",
        "additions" => i,
        "deletions" => 1,
        "changeType" => "MODIFIED"
      }

    defp sized(extra) do
      Map.merge(
        %{
          "state" => "OPEN",
          "mergeable" => "MERGEABLE",
          "headRefOid" => "abc123def456",
          "headRefName" => "b",
          "baseRefName" => "main"
        },
        extra
      )
    end

    defp fetch_sized(extra) do
      PrStatus.fetch(@url, command_runner: runner(Jason.encode!(sized(extra))))
    end

    test "asks gh for the four fields in the same call as the head sha" do
      test_pid = self()

      runner = fn "gh", args, _opts ->
        send(test_pid, {:gh_args, args})
        {Jason.encode!(sized(%{})), 0}
      end

      {:ok, _} = PrStatus.fetch(@url, command_runner: runner)
      assert_received {:gh_args, ["pr", "view", @url, "--json", fields]}
      listed = String.split(fields, ",")
      assert Enum.all?(~w(headRefOid files changedFiles additions deletions), &(&1 in listed))
    end

    test "a small PR carries its files (path, additions, deletions only) and totals, complete" do
      assert {:ok, %PrStatus{} = status} =
               fetch_sized(%{
                 "files" => [file_item(2), file_item(3)],
                 "changedFiles" => 2,
                 "additions" => 5,
                 "deletions" => 2
               })

      assert status.files == [
               %{path: "lib/f2.ex", additions: 2, deletions: 1},
               %{path: "lib/f3.ex", additions: 3, deletions: 1}
             ]

      assert {status.changed_files, status.additions, status.deletions} == {2, 5, 2}
      refute PrStatus.files_incomplete?(status)
    end

    test "100 of 223 files: the list is kept as listed, the totals are the PR's own, and it is incomplete" do
      assert {:ok, status} =
               fetch_sized(%{
                 "files" => Enum.map(1..100, &file_item/1),
                 "changedFiles" => 223,
                 "additions" => 9_000,
                 "deletions" => 400
               })

      assert length(status.files) == 100
      assert hd(status.files).path == "lib/f1.ex"
      assert List.last(status.files).path == "lib/f100.ex"
      assert status.changed_files == 223
      assert {status.additions, status.deletions} == {9_000, 400}
      assert PrStatus.files_incomplete?(status)
    end

    test "a list longer than the cap keeps the first 100 as GitHub lists them" do
      assert {:ok, status} =
               fetch_sized(%{
                 "files" => Enum.map(1..130, &file_item/1),
                 "changedFiles" => 130,
                 "additions" => 1,
                 "deletions" => 1
               })

      assert length(status.files) == 100
      assert List.last(status.files).path == "lib/f100.ex"
      assert PrStatus.files_incomplete?(status)
    end

    test "a response that omits the fields leaves them nil and is incomplete, never an empty list" do
      assert {:ok, status} = fetch_sized(%{})

      assert {status.files, status.changed_files, status.additions, status.deletions} ==
               {nil, nil, nil, nil}

      assert PrStatus.files_incomplete?(status)
    end

    test "files without a count, or a count without files, is incomplete" do
      assert {:ok, no_count} = fetch_sized(%{"files" => [file_item(1)]})
      assert PrStatus.files_incomplete?(no_count)

      assert {:ok, no_files} = fetch_sized(%{"changedFiles" => 0})
      assert PrStatus.files_incomplete?(no_files)
    end

    test "an explicit empty list for a zero-file PR is complete" do
      assert {:ok, status} = fetch_sized(%{"files" => [], "changedFiles" => 0})
      refute PrStatus.files_incomplete?(status)
    end

    test "a file item without a path, or with a blank or non-string one, is a typed error" do
      for bad <- [
            %{"additions" => 1, "deletions" => 1},
            %{"path" => "", "additions" => 1, "deletions" => 1},
            %{"path" => 7, "additions" => 1, "deletions" => 1}
          ] do
        assert {:error, {:gh_unexpected_payload, ^bad}} =
                 fetch_sized(%{"files" => [file_item(1), bad], "changedFiles" => 2})
      end
    end

    test "a file item with a negative or non-integer count is a typed error" do
      for bad <- [
            %{"path" => "a", "additions" => -1, "deletions" => 0},
            %{"path" => "a", "additions" => 0, "deletions" => "2"},
            %{"path" => "a"}
          ] do
        assert {:error, {:gh_unexpected_payload, ^bad}} =
                 fetch_sized(%{"files" => [bad], "changedFiles" => 1})
      end
    end

    test "a files field that is not a list is a typed error" do
      assert {:error, {:gh_unexpected_payload, _}} =
               fetch_sized(%{"files" => %{"path" => "a"}})
    end

    test "a negative or non-integer total is a typed error, not a clamped value" do
      for {key, bad} <- [
            {"changedFiles", -3},
            {"additions", -1},
            {"deletions", "9"},
            {"changedFiles", 2.5}
          ] do
        assert {:error, {:gh_unexpected_payload, {^key, ^bad}}} = fetch_sized(%{key => bad})
      end
    end

    test "a renamed file is listed once, under its new path" do
      renamed = %{
        "path" => "lib/new_name.ex",
        "additions" => 0,
        "deletions" => 0,
        "changeType" => "RENAMED"
      }

      assert {:ok, %PrStatus{files: [%{path: "lib/new_name.ex"}]}} =
               fetch_sized(%{"files" => [renamed], "changedFiles" => 1})
    end
  end
end
