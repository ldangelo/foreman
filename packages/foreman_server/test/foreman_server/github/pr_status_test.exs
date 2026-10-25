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
end
