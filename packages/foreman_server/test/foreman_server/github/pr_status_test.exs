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
end
