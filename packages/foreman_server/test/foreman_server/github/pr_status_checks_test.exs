defmodule ForemanServer.GitHub.PrStatusChecksTest do
  @moduledoc """
  `PrStatus.fetch/2` against the recorded `gh` JSON of spike S4
  (`docs/spikes/S4/*.json`, real PR #565 and fork PR #531 captures).
  """
  use ExUnit.Case, async: true

  alias ForemanServer.GitHub.PrStatus

  @url "https://github.com/ldangelo/foreman/pull/565"
  @fixtures Path.expand("../../../../../docs/spikes/S4", __DIR__)

  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!()

  # The spike captures omit the two branch names `PrStatus` also reads.
  defp view(name) do
    name
    |> fixture()
    |> Jason.decode!()
    |> Map.merge(%{"headRefName" => "feat/x", "baseRefName" => "main"})
    |> Jason.encode!()
  end

  defp runner(output, code \\ 0), do: fn "gh", _args, _opts -> {output, code} end

  defp fetch_payload(map), do: PrStatus.fetch(@url, command_runner: runner(Jason.encode!(map)))

  defp base(extra) do
    Map.merge(
      %{
        "state" => "OPEN",
        "mergeable" => "MERGEABLE",
        "headRefOid" => "abc",
        "headRefName" => "feat/x",
        "baseRefName" => "main"
      },
      extra
    )
  end

  describe "recorded PR #565 (merged, all checks green)" do
    test "normalises the heterogeneous statusCheckRollup into typed checks" do
      assert {:ok, status} = PrStatus.fetch(@url, command_runner: runner(view("pr565-view.json")))

      assert status.checks_state == :passing
      assert Enum.all?(status.checks, &(&1.state == :passing))
      assert Enum.any?(status.checks, &(&1.kind == :check_run and &1.workflow == "ci"))
      assert Enum.any?(status.checks, &(&1.kind == :status_context and &1.name == "CodeRabbit"))
    end

    test "maps review decision, review states and merge state; empty decision is nil" do
      assert {:ok, status} = PrStatus.fetch(@url, command_runner: runner(view("pr565-view.json")))
      assert status.merge_state_status == :unknown
      assert status.review_decision == nil

      assert Enum.map(status.reviews, & &1.state) |> Enum.uniq() |> Enum.sort() ==
               [:approved, :changes_requested]

      assert Enum.all?(status.reviews, &(is_binary(&1.id) and is_binary(&1.commit_oid)))
    end

    test "conversation comments carry id, author and a bounded body" do
      assert {:ok, status} = PrStatus.fetch(@url, command_runner: runner(view("pr565-view.json")))
      assert length(status.comments) == 5
      assert Enum.all?(status.comments, &(String.length(&1.body) <= 2000))
      assert Enum.all?(status.comments, &String.starts_with?(&1.id, "IC_"))
      refute status.comments_truncated
    end
  end

  describe "recorded fork PR #531 (only a StatusContext)" do
    test "an UNSTABLE open fork PR with a green StatusContext" do
      assert {:ok, status} =
               PrStatus.fetch(@url, command_runner: runner(view("pr531-fork-view.json")))

      assert status.status == :open
      assert status.merge_state_status == :unstable
      assert [%{kind: :status_context, state: :passing}] = status.checks
    end
  end

  describe "checks_state derivation" do
    defp run(conclusion, status \\ "COMPLETED"),
      do: %{
        "__typename" => "CheckRun",
        "name" => "n",
        "status" => status,
        "conclusion" => conclusion
      }

    test "no checks is :none" do
      assert {:ok, %{checks_state: :none, checks: []}} =
               fetch_payload(base(%{"statusCheckRollup" => []}))
    end

    test "one failure wins over pending and passing" do
      rollup = [run("SUCCESS"), run(nil, "IN_PROGRESS"), run("FAILURE")]

      assert {:ok, %{checks_state: :failing}} =
               fetch_payload(base(%{"statusCheckRollup" => rollup}))
    end

    test "any unfinished check without a failure is :pending" do
      rollup = [run("SUCCESS"), run(nil, "QUEUED")]

      assert {:ok, %{checks_state: :pending}} =
               fetch_payload(base(%{"statusCheckRollup" => rollup}))
    end

    test "TIMED_OUT, CANCELLED and ACTION_REQUIRED all fail; SKIPPED and NEUTRAL pass" do
      for failing <- ~w(TIMED_OUT CANCELLED ACTION_REQUIRED) do
        assert {:ok, %{checks_state: :failing}} =
                 fetch_payload(base(%{"statusCheckRollup" => [run(failing)]}))
      end

      for passing <- ~w(SKIPPED NEUTRAL) do
        assert {:ok, %{checks_state: :passing}} =
                 fetch_payload(base(%{"statusCheckRollup" => [run(passing)]}))
      end
    end

    test "a StatusContext in ERROR fails" do
      ctx = %{"__typename" => "StatusContext", "context" => "ci/x", "state" => "ERROR"}

      assert {:ok, %{checks_state: :failing}} =
               fetch_payload(base(%{"statusCheckRollup" => [ctx]}))
    end
  end

  describe "unknown enum values are typed errors, never guesses" do
    test "unknown check conclusion" do
      assert {:error, {:gh_unexpected_payload, %{"conclusion" => "EXPLODED"}}} =
               fetch_payload(base(%{"statusCheckRollup" => [run("EXPLODED")]}))
    end

    test "unknown reviewDecision" do
      assert {:error, {:gh_unexpected_payload, {:reviewDecision, "MAYBE"}}} =
               fetch_payload(base(%{"reviewDecision" => "MAYBE"}))
    end

    test "unknown mergeStateStatus" do
      assert {:error, {:gh_unexpected_payload, {:mergeStateStatus, "WEIRD"}}} =
               fetch_payload(base(%{"mergeStateStatus" => "WEIRD"}))
    end

    test "unknown review state" do
      review = %{"id" => "PRR_1", "state" => "VIBES", "author" => %{"login" => "a"}}

      assert {:error, {:gh_unexpected_payload, ^review}} =
               fetch_payload(base(%{"reviews" => [review]}))
    end
  end

  describe "bounds" do
    test "comment lists are cut at 100 (newest kept) and flagged" do
      comments =
        for n <- 1..130,
            do: %{
              "id" => "IC_#{n}",
              "author" => %{"login" => "a"},
              "body" => String.duplicate("x", 3000),
              "url" => "u"
            }

      assert {:ok, status} = fetch_payload(base(%{"comments" => comments}))
      assert status.comments_truncated
      assert length(status.comments) == 100
      assert hd(status.comments).id == "IC_31"
      assert List.last(status.comments).id == "IC_130"
      assert Enum.all?(status.comments, &(String.length(&1.body) == 2000))
    end

    test "minimised comments are dropped" do
      comments = [
        %{"id" => "IC_1", "body" => "spam", "isMinimized" => true},
        %{"id" => "IC_2", "body" => "real", "isMinimized" => false}
      ]

      assert {:ok, %{comments: [%{id: "IC_2"}]}} = fetch_payload(base(%{"comments" => comments}))
    end
  end

  describe "fetch_threads/2 with the recorded GraphQL response" do
    test "parses resolved/outdated threads and falls back to originalLine" do
      runner = fn "gh", args, _opts ->
        assert ["api", "graphql" | _] = args
        assert "owner=ldangelo" in args and "name=foreman" in args and "number=565" in args
        {fixture("pr565-review-threads.json"), 0}
      end

      assert {:ok, {threads, false}} = PrStatus.fetch_threads(@url, command_runner: runner)
      assert length(threads) == 5
      assert Enum.all?(threads, & &1.resolved)
      assert Enum.count(threads, & &1.outdated) == 4

      assert %{line: 88, path: "packages/foreman_server/lib/foreman_server/review/analyzer.ex"} =
               hd(threads)

      assert %{id: "4331773918"} = hd(hd(threads).comments)
    end

    test "fetch/2 with threads: true reads threads only when the PR has reviews" do
      test_pid = self()

      runner = fn "gh", args, _opts ->
        send(test_pid, {:gh, hd(args)})

        case args do
          ["pr" | _] ->
            {view("pr565-view.json"), 0}

          ["api", "graphql", "-f", "query=query($ids" <> _ | _] ->
            {fixture("pr565-comment-authors.json"), 0}

          ["api" | _] ->
            {fixture("pr565-review-threads.json"), 0}
        end
      end

      assert {:ok, %{threads: threads}} =
               PrStatus.fetch(@url, command_runner: runner, threads: true)

      assert length(threads) == 5
      assert_received {:gh, "pr"}
      assert_received {:gh, "api"}

      no_reviews = fn "gh", args, _opts ->
        send(test_pid, {:gh2, hd(args)})
        {Jason.encode!(base(%{"reviews" => []})), 0}
      end

      assert {:ok, %{threads: nil}} =
               PrStatus.fetch(@url, command_runner: no_reviews, threads: true)

      assert_received {:gh2, "pr"}
      refute_received {:gh2, "api"}
    end

    # foreman-v9y3x: the recorded GraphQL answer for PR #565's five conversation comments
    # (CodeRabbit's walkthrough and two later summaries, and the owner's two replies).
    test "recorded PR #565: CodeRabbit's three comments are Bots, the owner's two are not" do
      runner = fn "gh", args, _opts ->
        case args do
          ["pr" | _] ->
            {view("pr565-view.json"), 0}

          ["api", "graphql", "-f", "query=query($ids" <> _ | ids] ->
            assert Enum.count(ids, &String.starts_with?(&1, "ids[]=IC_")) == 5
            {fixture("pr565-comment-authors.json"), 0}

          ["api" | _] ->
            {fixture("pr565-review-threads.json"), 0}
        end
      end

      assert {:ok, %{comments: comments}} =
               PrStatus.fetch(@url, command_runner: runner, threads: true)

      assert Enum.map(comments, &{&1.author, &1.bot}) == [
               {"coderabbitai", true},
               {"ldangelo", false},
               {"coderabbitai", true},
               {"ldangelo", false},
               {"coderabbitai", true}
             ]
    end

    test "a non-PR url is a typed error" do
      assert {:error, {:gh_unexpected_payload, {:unrecognised_pr_url, "nope"}}} =
               PrStatus.fetch_threads("nope", command_runner: runner("{}"))
    end
  end

  test "the original five-field payload still parses (fields absent => empty defaults)" do
    assert {:ok, status} = fetch_payload(base(%{}))
    assert status.checks == [] and status.checks_state == :none
    assert status.review_decision == nil and status.merge_state_status == nil
  end
end
