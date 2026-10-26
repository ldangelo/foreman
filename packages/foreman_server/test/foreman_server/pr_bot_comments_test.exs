defmodule ForemanServer.PrBotCommentsTest do
  @moduledoc """
  foreman-v9y3x: a review bot on the account (CodeRabbit posts a walkthrough as a PR conversation
  comment, and a `CodeRabbit` commit status that stays PENDING while it works) must not make the
  PR look like it has comments to address.

  The chain under test is the real one: a `PrStatus` goes through `Observer.observe/2`, the
  run's `pr_watch` projection records it, and `Overview.PrActions` derives the card's buttons
  from that record.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.{PrAssociate, ProjectionStore}
  alias ForemanServer.Overview.PrActions
  alias ForemanServer.PrWatcher.{AutoFix, Observer}
  alias ForemanServer.TestSupport.PrWatchSupport, as: Support
  alias ForemanServer.Threads.Thread

  @walkthrough %{
    id: "IC_walkthrough",
    author: "coderabbitai",
    bot: true,
    body: "## Walkthrough\nA 9.7 KB summary of the change.",
    url: nil,
    created_at: nil
  }

  @pending_bot_status %{
    name: "CodeRabbit",
    kind: :status_context,
    state: :pending,
    conclusion: "PENDING",
    url: "https://coderabbit.ai",
    workflow: nil
  }

  setup do
    run = Support.start_run!(complete: true)
    {:ok, _} = PrAssociate.store(run.run_id, run.pr_url)
    {:ok, run}
  end

  defp person_comment(body),
    do: %{@walkthrough | id: "IC_person", author: "alice", bot: false, body: body}

  defp observe!(ctx, status) do
    assert {:ok, _result} =
             Observer.observe(ctx.pr_url,
               fetch_fun: fn _url -> {:ok, status} end,
               auto_fix: false
             )

    assert [record] = ProjectionStore.pr_watch(ctx.run_id)
    record
  end

  defp card_action(ctx, record, kind) do
    thread = %Thread{
      id: "run:" <> ctx.run_id,
      door: :workflow,
      project_id: ctx.project_id,
      title: "t",
      status: "completed",
      run_ids: [ctx.run_id],
      pr_url: ctx.pr_url
    }

    pr = %{pr_url: ctx.pr_url, pr_state: :open}
    Enum.find(PrActions.build(thread, pr, [record]), &(&1.kind == kind))
  end

  test "a bot's walkthrough and its pending status leave Address comments and Fix CI off", ctx do
    status =
      Support.status(
        comments: [@walkthrough],
        checks: [@pending_bot_status],
        checks_state: :pending
      )

    record = observe!(ctx, status)

    assert record.comment_ids == []

    assert %{enabled: false, reason: "There are no unresolved review comments."} =
             card_action(ctx, record, :address_comments)

    # GitHub's own roll-up is pending while the bot works, and it is recorded as such. Nothing
    # reads "pending" but the poll interval (`PrMonitor.next_interval/3`): it enables no action.
    assert record.checks_state == "pending"
    assert %{enabled: false, reason: "CI is not failing."} = card_action(ctx, record, :fix_ci)

    refute "PrReviewChanged" in Support.run_event_types(ctx.run_id)
  end

  test "a person's comment beside the bot's still enables Address comments", ctx do
    record =
      observe!(ctx, Support.status(comments: [@walkthrough, person_comment("please rename foo")]))

    assert record.comment_ids == ["IC_person"]
    assert %{enabled: true, reason: nil} = card_action(ctx, record, :address_comments)
    assert "PrReviewChanged" in Support.run_event_types(ctx.run_id)
  end

  test "the comments auto-fix kind never fires on a conversation comment, bot or person", ctx do
    status = Support.status(comments: [@walkthrough, person_comment("please rename foo")])
    record = observe!(ctx, status)

    assert :none =
             AutoFix.decide(
               ctx.run_id,
               ctx.pr_url,
               status,
               record,
               %{"kinds" => ["comments"]},
               System.system_time(:millisecond)
             )
  end
end
