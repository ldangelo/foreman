defmodule ForemanServer.Aggregates.RunPrWatchTest do
  @moduledoc """
  The E9 PR commands on the `Run` aggregate: observation events on terminal
  runs, replay into `pr_watch`/`pr_fixes`, and every fix-thread guard.
  """
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.Run

  @url "https://github.com/acme/repo/pull/7"

  defp started do
    Run.apply_event(Run.initial_state(), %{
      event_type: "RunStarted",
      run_id: "r1",
      task_id: "t1",
      project_id: "p1",
      sequence: 1
    })
  end

  defp terminal(type) do
    Run.apply_event(started(), %{event_type: type, run_id: "r1", project_id: "p1", sequence: 2})
  end

  # Fold an accepted command's event back into the state, like the actor does.
  defp accept(state, type, payload) do
    assert {:ok, %{} = spec} =
             Run.handle_command(state, %{type: type, payload: Map.put(payload, :run_id, "r1")})

    {Run.apply_event(state, %{event_type: spec.event_type, payload: spec.payload}), spec}
  end

  defp reject(state, type, payload),
    do: Run.handle_command(state, %{type: type, payload: Map.put(payload, :run_id, "r1")})

  defp checks_payload(extra \\ %{}) do
    Map.merge(
      %{
        pr_url: @url,
        head_sha: "sha-1",
        digest: "d1",
        checks_state: "failing",
        pr_status: "open",
        observation_seq: 1
      },
      extra
    )
  end

  defp watched(status \\ "open") do
    {state, _} = accept(started(), "run.pr.checks", checks_payload(%{pr_status: status}))
    state
  end

  describe "run.pr.checks / run.pr.review" do
    for type <- ["RunCompleted", "RunFailed", "RunCancelled"] do
      test "are accepted on a #{type} run and replay into pr_watch" do
        state = terminal(unquote(type))
        assert state.terminal?

        {state, spec} = accept(state, "run.pr.checks", checks_payload())
        assert spec.event_type == "PrChecksChanged"
        assert spec.stream_id == "run:r1"
        assert spec.payload.project_id == "p1" and spec.payload.task_id == "t1"

        {state, spec} =
          accept(state, "run.pr.review", %{
            pr_url: @url,
            head_sha: "sha-1",
            digest: "r1",
            review_decision: "changes_requested",
            pr_status: "open"
          })

        assert spec.event_type == "PrReviewChanged"

        assert %{
                 checks_state: "failing",
                 checks_digest: "d1",
                 review_decision: "changes_requested",
                 review_digest: "r1",
                 status: "open",
                 watching: true
               } =
                 state.pr_watch[@url]
      end
    end

    test "an unknown run is rejected" do
      assert {:error, {:not_found, :run, "r1"}} =
               Run.handle_command(Run.initial_state(), %{
                 type: "run.pr.checks",
                 payload: Map.put(checks_payload(), :run_id, "r1")
               })
    end

    test "missing digest, bad checks_state and bad decision each have their own error" do
      assert {:error, {:missing_or_invalid, :digest}} =
               reject(started(), "run.pr.checks", Map.delete(checks_payload(), :digest))

      assert {:error, {:missing_or_invalid, :checks_state}} =
               reject(started(), "run.pr.checks", checks_payload(%{checks_state: "great"}))

      assert {:error, {:missing_or_invalid, :pr_url}} =
               reject(started(), "run.pr.checks", Map.delete(checks_payload(), :pr_url))

      assert {:error, {:missing_or_invalid, :review_decision}} =
               reject(started(), "run.pr.review", %{
                 pr_url: @url,
                 head_sha: "s",
                 digest: "d",
                 review_decision: "MAYBE"
               })
    end

    test "a payload naming another project is refused" do
      assert {:error, {:missing_or_invalid, :project_id}} =
               reject(started(), "run.pr.checks", checks_payload(%{project_id: "other"}))
    end

    test "a stream with an unrelated future event still replays (catch-all)" do
      state =
        Run.apply_event(watched(), %{event_type: "SomeFutureEvent", payload: %{run_id: "r1"}})

      assert state.pr_watch[@url].checks_state == "failing"
    end
  end

  describe "fix requests" do
    test "operator fix_ci on a watched open PR emits PrFixRequested with attempt 1 and the PR head" do
      {state, spec} = accept(watched(), "run.pr.fix_ci", %{note: "please"})

      assert spec.event_type == "PrFixRequested"

      assert %{
               kind: "ci",
               attempt: 1,
               trigger: "operator",
               head_sha: "sha-1",
               pr_url: @url,
               note: "please"
             } = spec.payload

      assert state.pr_fixes[@url].in_flight == :requested
    end

    test "the three commands map to three kinds" do
      for {type, kind} <- [
            {"run.pr.fix_ci", "ci"},
            {"run.pr.address_comments", "comments"},
            {"run.pr.resolve_conflicts", "conflicts"}
          ] do
        assert {_state, %{payload: %{kind: ^kind}}} = accept(watched(), type, %{})
      end
    end

    test "a conflicted PR may be fixed; merged, closed and unwatched PRs may not" do
      assert {_s, _} = accept(watched("conflicted"), "run.pr.resolve_conflicts", %{})
      assert {:error, {:pr_not_open, "merged"}} = reject(watched("merged"), "run.pr.fix_ci", %{})
      assert {:error, {:pr_not_open, "closed"}} = reject(watched("closed"), "run.pr.fix_ci", %{})
      assert {:error, {:pr_not_watched, nil}} = reject(started(), "run.pr.fix_ci", %{})

      assert {:error, {:pr_not_watched, "https://x/pull/9"}} =
               reject(watched(), "run.pr.fix_ci", %{pr_url: "https://x/pull/9"})
    end

    test "a stopped watch refuses fixes until it is started again" do
      {stopped, _} = accept(watched(), "run.pr.watch_stop", %{})
      assert {:error, {:pr_not_watched, @url}} = reject(stopped, "run.pr.fix_ci", %{pr_url: @url})
      {again, _} = accept(stopped, "run.pr.watch_start", %{})
      assert {_s, _} = accept(again, "run.pr.fix_ci", %{})
    end

    test "with two watched PRs an operator must name the PR" do
      {state, _} =
        accept(
          watched(),
          "run.pr.checks",
          checks_payload(%{pr_url: "https://github.com/acme/repo/pull/8", head_sha: "sha-8"})
        )

      assert {:error, {:pr_url_required, "r1"}} = reject(state, "run.pr.fix_ci", %{})
      assert {_s, %{payload: %{pr_url: @url}}} = accept(state, "run.pr.fix_ci", %{pr_url: @url})
    end

    test "only one fix may be in flight; fix_started records the jobsite; a restarted request is refused" do
      {state, _} = accept(watched(), "run.pr.fix_ci", %{})
      assert {:error, {:fix_in_flight, @url}} = reject(state, "run.pr.address_comments", %{})

      {state, spec} = accept(state, "run.pr.fix_started", %{pr_url: @url, jobsite_id: "js-1"})
      assert %{kind: "ci", attempt: 1, jobsite_id: "js-1"} = spec.payload
      assert state.pr_fixes[@url].in_flight == "js-1"

      assert {:error, {:fix_already_started, @url, "js-1"}} =
               reject(state, "run.pr.fix_started", %{pr_url: @url, jobsite_id: "js-2"})

      assert {:error, {:fix_in_flight, @url}} = reject(state, "run.pr.fix_ci", %{})
    end

    test "fix_finished clears the marker and an outcome nobody asked for is refused" do
      assert {:error, {:no_fix_in_flight, @url}} =
               reject(watched(), "run.pr.fix_finished", %{pr_url: @url, outcome: "pushed"})

      {state, _} = accept(watched(), "run.pr.fix_ci", %{})

      assert {:error, {:missing_or_invalid, :outcome}} =
               reject(state, "run.pr.fix_finished", %{pr_url: @url, outcome: "meh"})

      {state, spec} =
        accept(state, "run.pr.fix_finished", %{
          pr_url: @url,
          outcome: "pushed",
          new_head_sha: "sha-2"
        })

      assert %{kind: "ci", attempt: 1, outcome: "pushed", new_head_sha: "sha-2"} = spec.payload
      assert state.pr_fixes[@url].in_flight == nil
      assert state.pr_fixes[@url].last_fix_head_sha == "sha-2"
    end

    test "fix_finished also ends a request whose jobsite never started" do
      {state, _} = accept(watched(), "run.pr.fix_ci", %{})

      assert {_s, %{payload: %{outcome: "failed", error_code: "jobsite_start_failed"}}} =
               accept(state, "run.pr.fix_finished", %{
                 pr_url: @url,
                 outcome: "failed",
                 error_code: "jobsite_start_failed"
               })
    end
  end

  describe "bounds" do
    defp run_fix(state, outcome, head \\ nil, finished_at \\ nil, trigger \\ "auto") do
      {state, _} =
        accept(state, "run.pr.fix_ci", %{
          trigger: trigger,
          max_attempts: 3,
          requested_at: finished_at
        })

      {state, _} = accept(state, "run.pr.fix_started", %{pr_url: @url, jobsite_id: "js"})

      {state, _} =
        accept(state, "run.pr.fix_finished", %{
          pr_url: @url,
          outcome: outcome,
          new_head_sha: head,
          finished_at: finished_at
        })

      state
    end

    test "auto fixes stop at max_attempts, per kind" do
      state = watched() |> run_fix("pushed", "s2") |> run_fix("pushed", "s3")

      assert {:error, {:fix_attempts_exhausted, "ci", 2}} =
               reject(state, "run.pr.fix_ci", %{trigger: "auto", max_attempts: 2})

      # another kind has its own counter
      assert {_s, %{payload: %{kind: "comments", attempt: 1}}} =
               accept(state, "run.pr.address_comments", %{trigger: "auto", max_attempts: 2})
    end

    test "an operator is bounded only by the hard cap, and force does not lift it" do
      state =
        Enum.reduce(1..5, watched(), fn n, acc ->
          run_fix(acc, "pushed", "s#{n}", nil, "operator")
        end)

      hard = Run.PrWatch.hard_cap()

      assert {:error, {:fix_attempts_exhausted, "ci", ^hard}} =
               reject(state, "run.pr.fix_ci", %{force: true})
    end

    test "an operator may exceed the auto cap but not the hard cap" do
      state = watched() |> run_fix("pushed", "s2") |> run_fix("pushed", "s3")
      assert {_s, %{payload: %{attempt: 3}}} = accept(state, "run.pr.fix_ci", %{})
    end

    test "auto does not retry a no_change fix on the same head; a new head allows it" do
      state = run_fix(watched(), "no_change")

      assert {:error, {:fix_no_progress, "ci"}} =
               reject(state, "run.pr.fix_ci", %{trigger: "auto", max_attempts: 3})

      # operator may still ask (bounded by the hard cap)
      assert {_s, _} = accept(state, "run.pr.fix_ci", %{})

      # the PR head moved (someone pushed): progress is possible again
      {moved, _} =
        accept(
          state,
          "run.pr.checks",
          checks_payload(%{head_sha: "sha-9", digest: "d9", observation_seq: 2})
        )

      assert {_s, _} = accept(moved, "run.pr.fix_ci", %{trigger: "auto", max_attempts: 3})
    end

    test "auto respects the cooldown after the last fix finished" do
      state = run_fix(watched(), "pushed", "s2", 1_000_000)

      assert {:error, {:fix_cooling_down, 1_300_000}} =
               reject(state, "run.pr.fix_ci", %{
                 trigger: "auto",
                 max_attempts: 5,
                 cooldown_seconds: 300,
                 requested_at: 1_100_000
               })

      assert {_s, _} =
               accept(state, "run.pr.fix_ci", %{
                 trigger: "auto",
                 max_attempts: 5,
                 cooldown_seconds: 300,
                 requested_at: 1_400_000
               })
    end

    test "auto with a cooldown refuses a wrong-typed cooldown_seconds instead of raising" do
      state = run_fix(watched(), "pushed", "s2", 1_000_000)

      for bad <- ["300", 1.5, -1, false] do
        assert {:error, {:invalid_integer, :cooldown_seconds, ^bad}} =
                 reject(state, "run.pr.fix_ci", %{
                   trigger: "auto",
                   max_attempts: 5,
                   cooldown_seconds: bad,
                   requested_at: 1_100_000
                 })
      end
    end

    test "auto with a cooldown but no requested_at is refused, not silently un-cooled" do
      state = run_fix(watched(), "pushed", "s2", 1_000_000)

      assert {:error, {:invalid_integer, :requested_at, nil}} =
               reject(state, "run.pr.fix_ci", %{
                 trigger: "auto",
                 max_attempts: 5,
                 cooldown_seconds: 300
               })
    end

    test "auto with a cooldown and a non-integer requested_at is refused, not silently un-cooled" do
      state = run_fix(watched(), "pushed", "s2", 1_000_000)

      for bad <- ["1100000", 1.5, false] do
        assert {:error, {:invalid_integer, :requested_at, ^bad}} =
                 reject(state, "run.pr.fix_ci", %{
                   trigger: "auto",
                   max_attempts: 5,
                   cooldown_seconds: 300,
                   requested_at: bad
                 })
      end
    end

    test "fix_exhausted is recorded once per head and blocks that kind until the head moves" do
      {state, spec} =
        accept(watched(), "run.pr.fix_exhausted", %{
          pr_url: @url,
          kind: "ci",
          reason: "max_attempts",
          head_sha: "sha-1"
        })

      assert spec.event_type == "PrFixExhausted"

      assert {:ok, nil} =
               reject(state, "run.pr.fix_exhausted", %{
                 pr_url: @url,
                 kind: "ci",
                 reason: "max_attempts",
                 head_sha: "sha-1"
               })

      assert {:error, {:fix_exhausted, "ci"}} = reject(state, "run.pr.fix_ci", %{})
      assert {_s, _} = accept(state, "run.pr.fix_ci", %{force: true})

      {moved, _} =
        accept(
          state,
          "run.pr.checks",
          checks_payload(%{head_sha: "sha-2", digest: "d2", observation_seq: 2})
        )

      assert {_s, _} = accept(moved, "run.pr.fix_ci", %{})
    end

    test "auto cap validation" do
      assert {:error, {:invalid_integer, :max_attempts, 9}} =
               reject(watched(), "run.pr.fix_ci", %{trigger: "auto", max_attempts: 9})
    end
  end

  describe "watch lifecycle and create" do
    test "watch_stop is idempotent and works on a terminal run; an unknown PR is refused" do
      {state, _spec} = accept(terminal("RunCompleted"), "run.pr.checks", checks_payload())
      {state, stop} = accept(state, "run.pr.watch_stop", %{pr_url: @url, reason: "merged"})
      assert stop.event_type == "PrWatchStopped" and stop.payload.reason == "merged"
      refute state.pr_watch[@url].watching
      assert {:ok, nil} = reject(state, "run.pr.watch_stop", %{pr_url: @url})

      assert {:error, {:pr_not_watched, "https://x/pull/1"}} =
               reject(state, "run.pr.watch_stop", %{pr_url: "https://x/pull/1"})

      assert {:error, {:missing_or_invalid, :reason}} =
               reject(watched(), "run.pr.watch_stop", %{reason: "whim"})
    end

    test "run.pr.create records the PR the side effect opened" do
      assert {:ok,
              %{
                event_type: "PrCreated",
                payload: %{pr_url: @url, head_branch: "foreman/r1/p", base_branch: "main"}
              }} =
               reject(terminal("RunCompleted"), "run.pr.create", %{
                 pr_url: @url,
                 head_branch: "foreman/r1/p",
                 base_branch: "main"
               })

      assert {:error, {:missing_or_invalid, :head_branch}} =
               reject(started(), "run.pr.create", %{pr_url: @url, base_branch: "main"})
    end
  end

  test "PrUpdated and PrMerged keep the watch record's status current" do
    state = started()

    state =
      Run.apply_event(state, %{
        event_type: "PrUpdated",
        payload: %{
          run_id: "r1",
          pr_url: @url,
          pr_status: :conflicted,
          head_sha: "h",
          base_branch: "main"
        }
      })

    assert state.pr_watch[@url].status == "conflicted"

    state =
      Run.apply_event(state, %{event_type: "PrMerged", payload: %{run_id: "r1", pr_url: @url}})

    assert state.pr_watch[@url].status == "merged"
  end

  test "every event PrWatch can emit advances the run state (the lists cannot diverge)" do
    other = "https://github.com/acme/repo/pull/8"

    steps = [
      {"run.pr.checks", checks_payload()},
      {"run.pr.review",
       %{
         pr_url: @url,
         head_sha: "sha-1",
         digest: "r1",
         review_decision: "approved",
         pr_status: "open"
       }},
      {"run.pr.fix_ci", %{pr_url: @url}},
      {"run.pr.fix_started", %{pr_url: @url, jobsite_id: "js"}},
      {"run.pr.fix_finished", %{pr_url: @url, outcome: "pushed", new_head_sha: "s2"}},
      {"run.pr.fix_exhausted",
       %{pr_url: @url, kind: "ci", reason: "max_attempts", head_sha: "s2"}},
      {"run.pr.watch_stop", %{pr_url: @url, reason: "operator"}},
      {"run.pr.watch_start", %{pr_url: @url, reason: "operator"}},
      {"run.pr.create", %{pr_url: other, head_branch: "foreman/r1/p", base_branch: "main"}}
    ]

    {_state, emitted} =
      Enum.reduce(steps, {terminal("RunCompleted"), []}, fn {type, payload}, {state, acc} ->
        {next, spec} = accept(state, type, payload)
        # PrCreated is an audit record: PrUpdated/PrReady carry the PR into pr_watch.
        if spec.event_type != "PrCreated",
          do: assert(next != state, "#{spec.event_type} did not advance the run state")

        {next, [spec.event_type | acc]}
      end)

    assert Enum.sort(Enum.uniq(emitted)) == Enum.sort(Run.PrWatch.event_types())
  end
end
