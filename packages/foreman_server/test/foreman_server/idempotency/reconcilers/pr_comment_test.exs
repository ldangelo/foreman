defmodule ForemanServer.Idempotency.Reconcilers.PrCommentTest do
  @moduledoc """
  `Reconcilers.PrComment` (TRD-020): the verdict for an interrupted PR report comment.
  The token user's own comment carrying the marker for this run, head and digest is
  `:done`; a completely read list without it is `:not_done`; anything that cannot be read
  is `:unknown`, never `:not_done`.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias ForemanServer.Idempotency.Reconciler
  alias ForemanServer.Idempotency.Reconcilers.PrComment
  alias ForemanServer.PrReport

  @pr_url "https://github.com/acme/widgets/pull/7"
  @run_id "run-1"
  @head "0123456789abcdef0123456789abcdef01234567"
  @digest "d1d1d1d1"

  defp metadata(extra \\ %{}) do
    Map.merge(
      %{
        "run_id" => @run_id,
        "effect_class" => "pr_comment",
        "pr_url" => @pr_url,
        "head_sha" => @head,
        "digest" => @digest
      },
      extra
    )
  end

  defp comment(body, own?) do
    %{
      "id" => "IC_1",
      "url" => @pr_url <> "#issuecomment-1",
      "body" => body,
      "viewerDidAuthor" => own?,
      "isMinimized" => false,
      "createdAt" => "2026-11-12T10:00:00Z"
    }
  end

  defp marker(run_id \\ @run_id, head \\ @head, digest \\ @digest),
    do: PrReport.marker(run_id, head, digest) <> "\n\nreport"

  defp runner(comments) do
    answer = Jason.encode!(%{comments: comments})
    fn "gh", _args, _opts -> {answer, 0} end
  end

  describe "key/3 and intent/4" do
    test "the key is effect:pr_comment:<run>:<head>:<digest>, new for another head or digest" do
      key = PrComment.key(@run_id, @head, @digest)

      assert key == "effect:pr_comment:run-1:#{@head}:#{@digest}"
      assert key == PrComment.key(@run_id, @head, @digest)
      refute key == PrComment.key(@run_id, "other-head", @digest)
      refute key == PrComment.key(@run_id, @head, "other-digest")
      refute key == PrComment.key("run-2", @head, @digest)
    end

    test "the intent carries the run, url, head and digest and no cwd" do
      assert PrComment.intent(@run_id, @pr_url, @head, @digest) == %{
               run_id: @run_id,
               pr_url: @pr_url,
               head_sha: @head,
               digest: @digest
             }
    end
  end

  describe "reconcile/2 verdicts" do
    test "asks gh for the PR's comments by URL, with no cwd" do
      test = self()

      runner = fn "gh", args, opts ->
        send(test, {:ran, args, opts})
        {~s({"comments":[]}), 0}
      end

      assert PrComment.reconcile(metadata(), command_runner: runner) == :not_done
      assert_received {:ran, ["pr", "view", @pr_url, "--json", "comments"], opts}
      refute Keyword.has_key?(opts, :cd)
    end

    test "the token user's own comment with the marker for this run, head and digest is :done" do
      assert PrComment.reconcile(metadata(),
               command_runner: runner([comment("chatter", true), comment(marker(), true)])
             ) == :done
    end

    test "no comment at all is :not_done" do
      assert PrComment.reconcile(metadata(), command_runner: runner([])) == :not_done
    end

    test "a marker of another user is :not_done, however exact" do
      assert PrComment.reconcile(metadata(), command_runner: runner([comment(marker(), false)])) ==
               :not_done
    end

    test "a marker for another run, head or digest is :not_done" do
      for body <- [
            marker("run-2"),
            marker(@run_id, "f" <> binary_part(@head, 1, 39)),
            marker(@run_id, @head, "d2d2d2d2")
          ] do
        assert PrComment.reconcile(metadata(), command_runner: runner([comment(body, true)])) ==
                 :not_done
      end
    end

    test "a marker that is not the first line of the body is :not_done" do
      body = "quoted:\n" <> marker()

      assert PrComment.reconcile(metadata(), command_runner: runner([comment(body, true)])) ==
               :not_done
    end

    test "a failed gh is :unknown, never :not_done" do
      runner = fn "gh", _args, _opts -> {"error connecting to api.github.com", 1} end
      assert PrComment.reconcile(metadata(), command_runner: runner) == :unknown
    end

    test "an answer that is not a comment list is :unknown" do
      for answer <- ["not json", ~s({"message":"Bad credentials"}), ~s({"comments":[1]})] do
        runner = fn "gh", _args, _opts -> {answer, 0} end
        assert PrComment.reconcile(metadata(), command_runner: runner) == :unknown
      end
    end

    test "metadata without pr_url, head_sha, digest or run_id is :unknown and runs nothing" do
      test = self()

      runner = fn executable, args, opts ->
        send(test, {:ran, executable, args, opts})
        {~s({"comments":[]}), 0}
      end

      for field <- ["pr_url", "head_sha", "digest", "run_id"], value <- [nil, ""] do
        assert PrComment.reconcile(metadata(%{field => value}), command_runner: runner) ==
                 :unknown
      end

      refute_received {:ran, _, _, _}
    end

    test "a PR URL that is not a github.com pull request is :unknown and runs nothing" do
      runner = fn _executable, _args, _opts -> flunk("gh ran") end

      assert PrComment.reconcile(metadata(%{"pr_url" => "https://example.com/x/y/pull/1"}),
               command_runner: runner
             ) == :unknown
    end
  end

  describe "reconcile/2 never waits on gh for ever" do
    @tag timeout: 5_000
    test "a gh that does not answer within timeout_ms is :unknown, and the call returns promptly" do
      test = self()

      runner = fn _executable, _args, _opts ->
        send(test, {:runner, self()})
        Process.sleep(:infinity)
      end

      {elapsed_us, verdict} =
        :timer.tc(fn ->
          PrComment.reconcile(metadata(), command_runner: runner, timeout_ms: 50)
        end)

      assert verdict == :unknown
      assert elapsed_us < 3_000_000
      assert_received {:runner, runner_pid}
      refute Process.alive?(runner_pid)
    end
  end

  describe "the registry and the class's definition" do
    test "\"pr_comment\" maps to this module" do
      assert Reconciler.classes()["pr_comment"] == PrComment
    end

    test "the class is repeatable and never blocks a run, whatever the verdict" do
      assert Reconciler.repeatable?("pr_comment", metadata())
      refute Reconciler.blocks_run?("pr_comment", metadata())
    end

    test "with the entry removed the class is unregistered, not repeatable and blocking" do
      classes = Map.delete(Reconciler.classes(), "pr_comment")

      assert Reconciler.verdict("pr_comment", metadata(), classes: classes) == :unregistered
      refute Reconciler.repeatable?("pr_comment", metadata(), classes: classes)
      assert Reconciler.blocks_run?("pr_comment", metadata(), classes: classes)
    end
  end
end
