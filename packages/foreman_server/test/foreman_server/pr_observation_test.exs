defmodule ForemanServer.PrObservationTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{PrObservation, ProjectionStore}
  alias ForemanServer.TestSupport.PrWatchSupport, as: Support

  defp types(commands), do: Enum.map(commands, & &1.type)

  # Dispatch what the observer produced and return the stored watch record.
  defp apply!(commands, run_id, pr_url) do
    Enum.each(commands, &Support.dispatch!/1)
    Enum.find(ProjectionStore.pr_watch(run_id), &(&1.pr_url == pr_url))
  end

  setup do
    run = Support.start_run!(complete: true)
    {:ok, run}
  end

  describe "digests" do
    test "checks digest ignores check order and comment churn, but not the head sha" do
      a =
        Support.status(
          checks: [Support.failing_check("a"), Support.failing_check("b")],
          checks_state: :failing
        )

      b = %{
        a
        | checks: Enum.reverse(a.checks),
          comments: [%{id: "IC_1", author: "x", body: "hi", url: nil, created_at: nil}]
      }

      assert PrObservation.checks_digest(a) == PrObservation.checks_digest(b)

      refute PrObservation.checks_digest(a) ==
               PrObservation.checks_digest(%{a | head_sha: "sha-2"})
    end

    test "review digest ignores comment bodies and check state, but sees a new comment id" do
      c = fn id, body -> %{id: id, author: "x", body: body, url: nil, created_at: nil} end
      a = Support.status(comments: [c.("IC_1", "one")])

      assert PrObservation.review_digest(a) ==
               PrObservation.review_digest(%{
                 a
                 | comments: [c.("IC_1", "edited")],
                   checks_state: :failing
               })

      refute PrObservation.review_digest(a) ==
               PrObservation.review_digest(%{
                 a
                 | comments: [c.("IC_1", "one"), c.("IC_2", "two")]
               })
    end

    test "unresolved thread ids drive the review digest; resolved ones do not" do
      thread = fn id, resolved ->
        %{id: id, resolved: resolved, outdated: false, path: "a.ex", line: 1, comments: []}
      end

      none = Support.status(threads: [thread.("T1", true)])
      one = Support.status(threads: [thread.("T1", true), thread.("T2", false)])

      assert PrObservation.thread_ids(one) == ["T2"]

      assert PrObservation.review_digest(none) ==
               PrObservation.review_digest(Support.status(threads: nil))

      refute PrObservation.review_digest(none) == PrObservation.review_digest(one)
    end
  end

  describe "commands/4" do
    test "a first sighting of a PR with nothing to report is just the run.pr.update", %{
      run_id: run_id,
      pr_url: pr_url
    } do
      assert {:ok, commands} = PrObservation.commands(run_id, pr_url, Support.status(), nil)
      assert types(commands) == ["run.pr.update"]
    end

    test "failing checks add run.pr.checks; repeating the identical observation emits nothing",
         ctx do
      status = Support.status(checks: [Support.failing_check("unit")], checks_state: :failing)

      assert {:ok, commands} = PrObservation.commands(ctx.run_id, ctx.pr_url, status, nil)
      assert types(commands) == ["run.pr.update", "run.pr.checks"]
      record = apply!(commands, ctx.run_id, ctx.pr_url)

      assert record.checks_state == "failing"
      assert record.failing == ["unit"]
      assert {:ok, []} = PrObservation.commands(ctx.run_id, ctx.pr_url, status, record)
    end

    test "a new comment changes only the review command, never the checks command", ctx do
      status = Support.status(checks: [Support.failing_check("unit")], checks_state: :failing)
      {:ok, first} = PrObservation.commands(ctx.run_id, ctx.pr_url, status, nil)
      record = apply!(first, ctx.run_id, ctx.pr_url)

      commented = %{
        status
        | comments: [%{id: "IC_9", author: "r", body: "fix this", url: nil, created_at: nil}]
      }

      assert {:ok, [review]} = PrObservation.commands(ctx.run_id, ctx.pr_url, commented, record)
      assert review.type == "run.pr.review"
      assert review.payload.comment_ids == ["IC_9"]
      assert review.payload.new_comment_count == 1
    end

    test "a new head sha changes both the update and the checks command", ctx do
      status = Support.status(checks: [Support.failing_check("unit")], checks_state: :failing)
      {:ok, first} = PrObservation.commands(ctx.run_id, ctx.pr_url, status, nil)
      record = apply!(first, ctx.run_id, ctx.pr_url)

      pushed = %{status | head_sha: "sha-2"}
      assert {:ok, commands} = PrObservation.commands(ctx.run_id, ctx.pr_url, pushed, record)
      assert types(commands) == ["run.pr.update", "run.pr.checks"]
    end

    test "fail -> pass -> fail on the SAME sha yields three distinct events (observation_seq)",
         ctx do
      failing = Support.status(checks: [Support.failing_check("unit")], checks_state: :failing)

      passing =
        Support.status(
          checks: [%{Support.failing_check("unit") | state: :passing, conclusion: "SUCCESS"}],
          checks_state: :passing
        )

      r1 = step(ctx, failing, nil)
      r2 = step(ctx, passing, r1)
      r3 = step(ctx, failing, r2)

      assert [r1.checks_seq, r2.checks_seq, r3.checks_seq] == [1, 2, 3]
      assert r1.checks_digest == r3.checks_digest

      events = Support.run_events(ctx.run_id)
      assert Enum.count(events, &(&1.event_type == "PrChecksChanged")) == 3
    end

    test "the command id is deterministic: two observers reading the same previous collapse to one event",
         ctx do
      status = Support.status(checks: [Support.failing_check("unit")], checks_state: :failing)
      {:ok, [_u1, c1]} = PrObservation.commands(ctx.run_id, ctx.pr_url, status, nil)
      {:ok, [_u2, c2]} = PrObservation.commands(ctx.run_id, ctx.pr_url, status, nil)

      assert c1.command_id == c2.command_id
      Support.dispatch!(c1)
      Support.dispatch!(c2)

      assert Enum.count(Support.run_events(ctx.run_id), &(&1.event_type == "PrChecksChanged")) ==
               1
    end

    test "an unknown run is a typed error", %{pr_url: pr_url} do
      assert {:error, {:run_not_found, "run-nope"}} =
               PrObservation.commands("run-nope", pr_url, Support.status(), nil)
    end
  end

  defp step(ctx, status, previous) do
    {:ok, commands} = PrObservation.commands(ctx.run_id, ctx.pr_url, status, previous)
    apply!(commands, ctx.run_id, ctx.pr_url)
  end
end
