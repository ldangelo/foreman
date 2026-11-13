defmodule ForemanServer.GitHub.PrCommentTest do
  @moduledoc """
  TRD-019: `GitHub.PrComment` builds exactly the documented `gh` arguments (never `-F`, never
  `--body-file`, no `cd`), bounds every call, never reads a failure as success, and refuses a
  URL it cannot parse before running anything. `Command.run/4` without `:cd` is covered here
  too. No real `gh` runs: every call goes through a recording runner.
  """

  use ExUnit.Case, async: true

  alias ForemanServer.GitHub.PrComment
  alias ForemanServer.GitHub.PrStatus
  alias ForemanServer.Idempotency.Reconcilers.Command

  @pr_url "https://github.com/o/r/pull/7"
  @comment_url "https://github.com/o/r/pull/7#issuecomment-123"

  # A runner that reports each call to the test and answers `{output, code}`.
  defp runner(output, code \\ 0) do
    test = self()

    fn executable, args, opts ->
      send(test, {:ran, executable, args, opts})
      {output, code}
    end
  end

  defp written(overrides \\ %{}) do
    Jason.encode!(
      Map.merge(
        %{"id" => 123, "node_id" => "IC_kwDOabc", "html_url" => @comment_url},
        overrides
      )
    )
  end

  defp item(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "IC_kwDOabc",
        "url" => @comment_url,
        "body" => "hello",
        "viewerDidAuthor" => true,
        "isMinimized" => false,
        "createdAt" => "2026-11-13T10:00:00Z"
      },
      overrides
    )
  end

  defp comments(items), do: Jason.encode!(%{"comments" => items})

  describe "PR URLs" do
    @hostile_pr_urls [
      "https://evil.example/github.com/o/r/pull/7",
      "https://evil.example/github.com/o/r/pull/7?x=1",
      "https://github.com.evil.example/o/r/pull/7",
      "https://notgithub.com/o/r/pull/7",
      "http://github.com/o/r/pull/7",
      "github.com/o/r/pull/7",
      "https://github.com/o/r/pull/7?x=1",
      "https://github.com/o/r/pull/7#issuecomment-1",
      "https://github.com/o/r/pull/7/files",
      "https://github.com/o/r/pull/7/extra/segments",
      "https://github.com/o/r/pull/7 ",
      "https://github.com/o/r/pull/7\n",
      "https://github.com/o/r/pull/",
      "https://github.com/o/r/pull/x",
      "https://github.com/../r/pull/7",
      "https://github.com/o/../pull/7",
      "https://github.com/./r/pull/7",
      "https://github.com/o/r/issues/7",
      "https://github.com/o/r/pull/7/../../x",
      "https://user@github.com/o/r/pull/7",
      "https://github.com:8443/o/r/pull/7",
      "prefix https://github.com/o/r/pull/7",
      ""
    ]

    test "PrComment.parse_pr_url/1 accepts a github.com pull URL (with at most a trailing slash) and nothing else" do
      assert PrComment.parse_pr_url("https://github.com/o/r/pull/7") == {:ok, "o", "r", 7}
      assert PrComment.parse_pr_url("https://github.com/o/r/pull/7/") == {:ok, "o", "r", 7}

      assert PrComment.parse_pr_url("https://github.com/Acme-1/re.po_x/pull/42") ==
               {:ok, "Acme-1", "re.po_x", 42}

      for url <- @hostile_pr_urls do
        assert {:error, {:gh_unexpected_payload, {:unrecognised_pr_url, ^url}}} =
                 PrComment.parse_pr_url(url)
      end
    end

    test "PrStatus.parse_pr_url/1 keeps its lax reading for the read paths (threads)" do
      for url <- [
            "https://github.com/o/r/pull/7",
            "https://github.com/o/r/pull/7/files",
            "https://github.com/o/r/pull/7#issuecomment-1",
            "https://github.com/o/r/pull/7?x=1",
            "http://github.com/o/r/pull/7",
            "https://www.github.com/o/r/pull/7",
            "github.com/o/r/pull/7"
          ] do
        assert PrStatus.parse_pr_url(url) == {:ok, "o", "r", 7}
      end

      assert {:error, {:gh_unexpected_payload, {:unrecognised_pr_url, "https://g/o/r/pull/7"}}} =
               PrStatus.parse_pr_url("https://g/o/r/pull/7")
    end

    test "list/2 and create/3 refuse a hostile URL and run nothing" do
      for url <- @hostile_pr_urls do
        assert {:error, {:gh_unexpected_payload, _}} =
                 PrComment.list(url, command_runner: runner(comments([])))

        assert {:error, {:gh_unexpected_payload, _}} =
                 PrComment.create(url, "b", command_runner: runner(written()))
      end

      refute_received {:ran, _, _, _}
    end
  end

  describe "create/3" do
    test "runs gh api POST arguments with -f, no -F, no --body-file and no cd" do
      body = "<!-- marker -->\n@user true null 7 @file"

      assert {:ok, %{id: "IC_kwDOabc", rest_id: 123, url: @comment_url}} =
               PrComment.create(@pr_url, body, command_runner: runner(written()))

      assert_received {:ran, "gh", args, opts}
      assert args == ["api", "repos/o/r/issues/7/comments", "-f", "body=" <> body]
      refute "-F" in args
      refute "--body-file" in args
      assert opts == [stderr_to_stdout: true]
    end

    test "a PR URL outside github.com runs nothing" do
      assert {:error, {:gh_unexpected_payload, _}} =
               PrComment.create("https://example.com/o/r/issues/7", "b",
                 command_runner: runner("")
               )

      refute_received {:ran, _, _, _}
    end

    test "gh output merged into otherwise valid JSON (a warning before it) is a typed error, not success" do
      assert {:error, {:gh_unparsable, _}} =
               PrComment.create(@pr_url, "b",
                 command_runner: runner("warning: a new release is available\n" <> written())
               )

      assert {:error, {:gh_unparsable, _}} =
               PrComment.update(@comment_url, "b",
                 command_runner: runner("warning: x\n" <> written())
               )

      assert {:error, {:gh_unparsable, _}} =
               PrComment.list(@pr_url,
                 command_runner: runner("warning: x\n" <> comments([item()]))
               )
    end

    test "a non-zero exit is an error carrying the output, never success" do
      assert PrComment.create(@pr_url, "b", command_runner: runner("HTTP 403: nope\n", 1)) ==
               {:error, {:gh_failed, 1, "HTTP 403: nope"}}

      assert {:error, {:gh_unparsable, _}} =
               PrComment.create(@pr_url, "b", command_runner: runner("not json"))

      assert {:error, {:gh_unexpected_payload, _}} =
               PrComment.create(@pr_url, "b", command_runner: runner(~s({"id": "x"})))
    end
  end

  describe "update/3" do
    test "patches the numeric id of the comment URL fragment" do
      assert {:ok, %{rest_id: 123}} =
               PrComment.update(@comment_url, "new body", command_runner: runner(written()))

      assert_received {:ran, "gh", args, opts}

      assert args == [
               "api",
               "-X",
               "PATCH",
               "repos/o/r/issues/comments/123",
               "-f",
               "body=new body"
             ]

      assert opts == [stderr_to_stdout: true]
    end

    test "an issues URL with the fragment is accepted" do
      assert {:ok, _} =
               PrComment.update(
                 "https://github.com/o/r/issues/7#issuecomment-5",
                 "b",
                 command_runner: runner(written())
               )

      assert_received {:ran, "gh", [_, _, _, "repos/o/r/issues/comments/5" | _], _}
    end

    test "a URL without the fragment, outside github.com or with a bad id runs nothing" do
      for url <- [
            "https://github.com/o/r/pull/7",
            "https://github.com/../r/pull/7#issuecomment-1",
            "https://github.com/o/r/pull/7#issuecomment-",
            "https://github.com/o/r/pull/7#issuecomment-12x",
            "https://example.com/o/r/pull/7#issuecomment-123",
            "https://example.com/github.com/o/r/pull/7#issuecomment-123",
            "http://github.com/o/r/pull/7#issuecomment-123",
            "not a url"
          ] do
        assert {:error, {:gh_unexpected_payload, _}} =
                 PrComment.update(url, "b", command_runner: runner(written()))
      end

      refute_received {:ran, _, _, _}
    end

    test "a non-zero exit is an error" do
      assert PrComment.update(@comment_url, "b", command_runner: runner("HTTP 404\n", 1)) ==
               {:error, {:gh_failed, 1, "HTTP 404"}}
    end
  end

  describe "list/2" do
    test "runs gh pr view --json comments with no cd and returns each comment oldest first" do
      newer = item(%{"id" => "B", "createdAt" => "2026-11-13T12:00:00Z", "isMinimized" => true})
      older = item(%{"id" => "A", "body" => String.duplicate("long ", 1000)})

      assert {:ok, [first, second]} =
               PrComment.list(@pr_url, command_runner: runner(comments([newer, older])))

      assert_received {:ran, "gh", ["pr", "view", @pr_url, "--json", "comments"], opts}
      assert opts == [stderr_to_stdout: true]

      assert first == %{
               id: "A",
               url: @comment_url,
               body: older["body"],
               viewer_did_author: true,
               minimized: false,
               created_at: "2026-11-13T10:00:00Z"
             }

      assert second.id == "B"
      assert second.minimized == true
      assert String.length(first.body) == 5000
    end

    test "an empty comment list is an empty list" do
      assert PrComment.list(@pr_url, command_runner: runner(comments([]))) == {:ok, []}
    end

    test "an item missing id or body, or with a wrong-shaped field, is a typed error" do
      for bad <- [
            Map.delete(item(), "id"),
            Map.delete(item(), "body"),
            item(%{"id" => ""}),
            item(%{"body" => nil}),
            item(%{"viewerDidAuthor" => "yes"}),
            Map.delete(item(), "isMinimized"),
            item(%{"createdAt" => nil})
          ] do
        assert PrComment.list(@pr_url, command_runner: runner(comments([item(), bad]))) ==
                 {:error, {:gh_unexpected_payload, bad}}
      end
    end

    test "an answer that is not a comment list is a typed error" do
      assert {:error, {:gh_unexpected_payload, %{"x" => 1}}} =
               PrComment.list(@pr_url, command_runner: runner(~s({"x":1})))

      assert {:error, {:gh_unparsable, "oops"}} =
               PrComment.list(@pr_url, command_runner: runner("oops"))

      assert PrComment.list(@pr_url, command_runner: runner("boom", 4)) ==
               {:error, {:gh_failed, 4, "boom"}}
    end

    test "a URL outside github.com runs nothing" do
      assert {:error, {:gh_unexpected_payload, _}} =
               PrComment.list("https://example.com/o/r/pull/7", command_runner: runner(""))

      refute_received {:ran, _, _, _}
    end
  end

  describe "the time bound" do
    test "a runner that never answers is {:error, {:timeout, ms}} for every call" do
      hung = fn _cmd, _args, _opts -> Process.sleep(:infinity) end

      assert PrComment.list(@pr_url, command_runner: hung, timeout_ms: 30) ==
               {:error, {:timeout, 30}}

      assert PrComment.create(@pr_url, "b", command_runner: hung, timeout_ms: 30) ==
               {:error, {:timeout, 30}}

      assert PrComment.update(@comment_url, "b", command_runner: hung, timeout_ms: 30) ==
               {:error, {:timeout, 30}}
    end

    test "without :timeout_ms the call is bounded by the Command default (the runner runs in a bounded task)" do
      test = self()

      inline = fn _cmd, _args, _opts ->
        send(test, {:runner_pid, self()})
        {comments([]), 0}
      end

      assert Command.default_timeout_ms() == 30_000
      assert {:ok, []} = PrComment.list(@pr_url, command_runner: inline)
      assert_received {:runner_pid, runner_pid}
      refute runner_pid == test

      assert {:ok, {_, 0}} = Command.run(inline, "gh", [], timeout_ms: :infinity)
      assert_received {:runner_pid, inline_pid}
      assert inline_pid == test
    end

    test "a runner that raises or answers something else is an error" do
      raising = fn _cmd, _args, _opts -> raise "boom" end
      odd = fn _cmd, _args, _opts -> :ok end

      assert {:error, {:command_raised, "boom"}} =
               PrComment.list(@pr_url, command_runner: raising, timeout_ms: 1_000)

      assert {:error, {:unexpected_runner_result, :ok}} =
               PrComment.list(@pr_url, command_runner: odd)
    end
  end

  describe "Command.run/4 cd" do
    test "without :cd the runner gets no :cd and merged stderr" do
      assert {:ok, {"out", 0}} = Command.run(runner("out"), "gh", ["a"], [])
      assert_received {:ran, "gh", ["a"], opts}
      assert opts == [stderr_to_stdout: true]
      refute Keyword.has_key?(opts, :cd)
    end

    test "with :cd (and :env) the behaviour is unchanged" do
      assert {:ok, {"out", 0}} =
               Command.run(runner("out"), "git", ["b"], cd: "/work", env: [{"A", "1"}])

      assert_received {:ran, "git", ["b"], opts}
      assert opts == [cd: "/work", stderr_to_stdout: true, env: [{"A", "1"}]]
    end
  end
end
