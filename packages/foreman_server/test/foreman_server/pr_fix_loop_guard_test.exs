defmodule ForemanServer.PrFixLoopGuardTest do
  @moduledoc """
  The fix-thread loop guard (E9-S4): a flaky or unfixable PR must never spawn fix
  after fix. Every bound lives in the `Run` aggregate and is checked from its own
  authoritative state; `PrWatcher.AutoFix` only decides *what* to ask for and
  reports a give-up. Each guard has its own test so removing exactly one of them
  fails exactly its test. `coordinator` requests (the MCP `foreman_pr_fix` tool)
  are bounded like `auto`; only an operator is exempt from the per-request
  bounds, and nobody from the hard cap.
  """
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.Run
  alias ForemanServer.GitHub.PrStatus
  alias ForemanServer.PrWatcher.AutoFix

  @url "https://github.com/acme/repo/pull/7"
  @bounded_triggers ["auto", "coordinator"]

  defp watched(head \\ "sha-1") do
    state =
      Run.apply_event(Run.initial_state(), %{
        event_type: "RunStarted",
        run_id: "r1",
        task_id: "t1",
        project_id: "p1",
        sequence: 1
      })

    {state, _} =
      accept(state, "run.pr.checks", %{
        pr_url: @url,
        head_sha: head,
        digest: "d-#{head}",
        checks_state: "failing",
        pr_status: "open",
        observation_seq: 1
      })

    state
  end

  defp accept(state, type, payload) do
    assert {:ok, %{} = spec} = reject(state, type, payload)
    {Run.apply_event(state, %{event_type: spec.event_type, payload: spec.payload}), spec}
  end

  defp reject(state, type, payload),
    do: Run.handle_command(state, %{type: type, payload: Map.put(payload, :run_id, "r1")})

  # request -> started -> finished with `outcome`
  defp run_fix(state, trigger, outcome, opts \\ []) do
    {state, _} =
      accept(state, "run.pr.fix_ci", %{
        trigger: trigger,
        max_attempts: Keyword.get(opts, :max_attempts, 5),
        cooldown_seconds: Keyword.get(opts, :cooldown_seconds, 0),
        requested_at: Keyword.get(opts, :at)
      })

    {state, _} = accept(state, "run.pr.fix_started", %{pr_url: @url, jobsite_id: "js"})

    {state, _} =
      accept(state, "run.pr.fix_finished", %{
        pr_url: @url,
        outcome: outcome,
        new_head_sha: Keyword.get(opts, :new_head),
        finished_at: Keyword.get(opts, :at)
      })

    state
  end

  defp move_head(state, head) do
    {state, _} =
      accept(state, "run.pr.checks", %{
        pr_url: @url,
        head_sha: head,
        digest: "d-#{head}",
        checks_state: "failing",
        pr_status: "open",
        observation_seq: 2
      })

    state
  end

  describe "hard cap (depth)" do
    test "no trigger, not even a forced operator request, gets past the per-kind hard cap" do
      hard = Run.PrWatch.hard_cap()

      state =
        Enum.reduce(1..hard, watched(), fn n, acc ->
          run_fix(acc, "operator", "pushed", new_head: "s#{n}")
        end)

      assert {:error, {:fix_attempts_exhausted, "ci", ^hard}} =
               reject(state, "run.pr.fix_ci", %{trigger: "operator", force: true})

      for trigger <- @bounded_triggers do
        assert {:error, {:fix_attempts_exhausted, "ci", ^hard}} =
                 reject(state, "run.pr.fix_ci", %{trigger: trigger, max_attempts: hard})
      end

      # the cap is per kind: another kind still has its whole budget
      assert {_s, %{payload: %{kind: "comments", attempt: 1}}} =
               accept(state, "run.pr.address_comments", %{})
    end
  end

  describe "max attempts" do
    for trigger <- @bounded_triggers do
      test "#{trigger}: stops at the requested max_attempts, counted per kind" do
        state =
          watched()
          |> run_fix(unquote(trigger), "pushed", new_head: "s2")
          |> run_fix(unquote(trigger), "pushed", new_head: "s3")

        assert {:error, {:fix_attempts_exhausted, "ci", 2}} =
                 reject(state, "run.pr.fix_ci", %{trigger: unquote(trigger), max_attempts: 2})

        assert {_s, %{payload: %{kind: "comments", attempt: 1}}} =
                 accept(state, "run.pr.address_comments", %{
                   trigger: unquote(trigger),
                   max_attempts: 2
                 })
      end
    end

    test "a coordinator request that names no cap gets the default auto cap, not the hard cap" do
      state =
        watched()
        |> run_fix("coordinator", "pushed", new_head: "s2", max_attempts: 2)
        |> run_fix("coordinator", "pushed", new_head: "s3", max_attempts: 2)

      assert {:error, {:fix_attempts_exhausted, "ci", 2}} =
               reject(state, "run.pr.fix_ci", %{trigger: "coordinator"})

      # an operator is not held to the auto cap
      assert {_s, %{payload: %{attempt: 3}}} =
               accept(state, "run.pr.fix_ci", %{trigger: "operator"})
    end

    test "an unknown trigger is refused rather than treated as an exempt operator" do
      assert {:error, {:missing_or_invalid, :trigger}} =
               reject(watched(), "run.pr.fix_ci", %{trigger: "robot"})
    end
  end

  describe "no progress" do
    for trigger <- @bounded_triggers do
      test "#{trigger}: a fix that changed nothing is not retried on the same head" do
        state = run_fix(watched(), unquote(trigger), "no_change")

        assert {:error, {:fix_no_progress, "ci"}} =
                 reject(state, "run.pr.fix_ci", %{trigger: unquote(trigger), max_attempts: 5})

        # a new head (someone pushed) makes progress possible again
        assert {_s, _} =
                 accept(move_head(state, "sha-9"), "run.pr.fix_ci", %{
                   trigger: unquote(trigger),
                   max_attempts: 5
                 })
      end
    end

    test "an operator may still ask after a no_change fix" do
      state = run_fix(watched(), "auto", "no_change")

      assert {_s, %{payload: %{attempt: 2, trigger: "operator"}}} =
               accept(state, "run.pr.fix_ci", %{})
    end

    test "a failed fix is not no-progress (only no_change is)" do
      state = run_fix(watched(), "auto", "failed")
      assert {_s, _} = accept(state, "run.pr.fix_ci", %{trigger: "auto", max_attempts: 5})
    end
  end

  describe "cooldown" do
    for trigger <- @bounded_triggers do
      test "#{trigger}: waits cooldown_seconds after the last fix finished" do
        state =
          run_fix(watched(), unquote(trigger), "pushed", new_head: "s2", at: 1_000_000)

        assert {:error, {:fix_cooling_down, 1_300_000}} =
                 reject(state, "run.pr.fix_ci", %{
                   trigger: unquote(trigger),
                   max_attempts: 5,
                   cooldown_seconds: 300,
                   requested_at: 1_100_000
                 })

        assert {_s, _} =
                 accept(state, "run.pr.fix_ci", %{
                   trigger: unquote(trigger),
                   max_attempts: 5,
                   cooldown_seconds: 300,
                   requested_at: 1_300_000
                 })
      end
    end

    test "an operator is not made to wait" do
      state = run_fix(watched(), "auto", "pushed", new_head: "s2", at: 1_000_000)

      assert {_s, _} =
               accept(state, "run.pr.fix_ci", %{
                 trigger: "operator",
                 cooldown_seconds: 300,
                 requested_at: 1_100_000
               })
    end
  end

  describe "one fix in flight" do
    test "a second request is refused while one is requested or running, for every trigger" do
      {requested, _} = accept(watched(), "run.pr.fix_ci", %{trigger: "auto"})
      {running, _} = accept(requested, "run.pr.fix_started", %{pr_url: @url, jobsite_id: "js"})

      for state <- [requested, running],
          trigger <- ["operator", "auto", "coordinator"],
          type <- ["run.pr.fix_ci", "run.pr.address_comments", "run.pr.resolve_conflicts"] do
        assert {:error, {:fix_in_flight, @url}} = reject(state, type, %{trigger: trigger})
      end
    end

    test "finishing the fix frees the slot" do
      state = run_fix(watched(), "auto", "pushed", new_head: "s2")
      assert {_s, _} = accept(state, "run.pr.fix_ci", %{trigger: "auto", max_attempts: 5})
    end
  end

  describe "exhausted" do
    defp exhaust(state, reason \\ "max_attempts") do
      {state, _} =
        accept(state, "run.pr.fix_exhausted", %{
          pr_url: @url,
          kind: "ci",
          reason: reason,
          head_sha: "sha-1"
        })

      state
    end

    test "after PrFixExhausted the kind is blocked on that head for non-forced requests" do
      state = exhaust(watched())

      for trigger <- ["operator" | @bounded_triggers] do
        assert {:error, {:fix_exhausted, "ci"}} =
                 reject(state, "run.pr.fix_ci", %{trigger: trigger})
      end

      # other kinds are unaffected
      assert {_s, _} = accept(state, "run.pr.address_comments", %{trigger: "auto"})
      # a new head clears it
      assert {_s, _} = accept(move_head(state, "sha-2"), "run.pr.fix_ci", %{trigger: "auto"})
    end
  end

  describe "AutoFix policy" do
    @settings %{"kinds" => ["ci", "comments", "conflicts"], "max_attempts" => 2}

    defp pr_status(overrides \\ []) do
      struct!(
        %PrStatus{
          status: :open,
          head_sha: "sha-1",
          head_branch: "foreman/run/phase",
          base_branch: "main",
          checks_state: :failing
        },
        overrides
      )
    end

    defp record(overrides \\ []) do
      Map.merge(
        %{
          watching: true,
          fix: %{in_flight: nil, exhausted: %{}, attempts: %{}}
        },
        Map.new(overrides)
      )
    end

    test "requests one bounded auto fix carrying the project's cap and cooldown" do
      assert {:request, command} =
               AutoFix.decide("r1", @url, pr_status(), record(), @settings, 5)

      assert command.type == "run.pr.fix_ci"
      assert command.payload.trigger == "auto"
      assert command.payload.max_attempts == 2
      assert command.payload.cooldown_seconds == 0
      assert command.aggregate_id == "run:r1"
    end

    test "no settings, or no watch record, means no fix" do
      assert :none = AutoFix.decide("r1", @url, pr_status(), record(), nil, 5)
      assert :none = AutoFix.decide("r1", @url, pr_status(), nil, @settings, 5)
    end

    test "nothing is requested while a fix is in flight" do
      in_flight = record(fix: %{in_flight: :requested, exhausted: %{}, attempts: %{}})
      assert :none = AutoFix.decide("r1", @url, pr_status(), in_flight, @settings, 5)
    end

    test "nothing is requested for a kind exhausted on this head, but a new head retries" do
      exhausted = record(fix: %{in_flight: nil, exhausted: %{"ci" => "sha-1"}, attempts: %{}})
      assert :none = AutoFix.decide("r1", @url, pr_status(), exhausted, @settings, 5)

      assert {:request, _} =
               AutoFix.decide("r1", @url, pr_status(head_sha: "sha-2"), exhausted, @settings, 5)
    end

    test "only enabled kinds trigger, and a stopped watch triggers nothing" do
      ci_off = %{@settings | "kinds" => ["comments"]}
      assert :none = AutoFix.decide("r1", @url, pr_status(), record(), ci_off, 5)

      assert :none =
               AutoFix.decide("r1", @url, pr_status(), record(watching: false), @settings, 5)
    end

    test "the request's command id carries the attempt, so a retry of the same attempt dedupes" do
      attempts = record(fix: %{in_flight: nil, exhausted: %{}, attempts: %{"ci" => 1}})
      assert {:request, first} = AutoFix.decide("r1", @url, pr_status(), record(), @settings, 5)
      assert {:request, second} = AutoFix.decide("r1", @url, pr_status(), attempts, @settings, 5)
      assert first.command_id != second.command_id
    end

    test "the give-up is reported for max_attempts and no_progress refusals only" do
      {:request, request} = AutoFix.decide("r1", @url, pr_status(), record(), @settings, 5)

      assert {:ok, %{type: "run.pr.fix_exhausted", payload: %{reason: "max_attempts"}}} =
               AutoFix.exhausted_command(
                 "r1",
                 @url,
                 request,
                 {:fix_attempts_exhausted, "ci", 2},
                 "sha-1"
               )

      assert {:ok, %{payload: %{reason: "no_progress", head_sha: "sha-1"}}} =
               AutoFix.exhausted_command("r1", @url, request, {:fix_no_progress, "ci"}, "sha-1")

      for quiet <- [
            {:fix_in_flight, @url},
            {:fix_cooling_down, 1},
            {:fix_exhausted, "ci"},
            {:fix_attempts_exhausted, "comments", 2}
          ] do
        assert :none = AutoFix.exhausted_command("r1", @url, request, quiet, "sha-1")
      end
    end

    test "an auto loop on a PR that never gets better ends after max_attempts with one give-up" do
      # decide -> aggregate -> (re-fail) ... driven through the real aggregate
      final =
        Enum.reduce_while(1..10, {watched(), 0}, fn _, {state, spawned} ->
          record = state.pr_fixes |> Map.get(@url, Run.PrWatch.new_fixes()) |> as_record()

          case AutoFix.decide("r1", @url, pr_status(), record, @settings, 5) do
            :none ->
              {:halt, {state, spawned}}

            {:request, command} ->
              case Run.handle_command(state, command) do
                {:ok, spec} ->
                  state =
                    Run.apply_event(state, %{event_type: spec.event_type, payload: spec.payload})

                  state = finish_fix(state, "pushed", "sha-#{spawned + 2}")
                  state = move_head(state, "sha-#{spawned + 2}")
                  {:cont, {state, spawned + 1}}

                {:error, reason} ->
                  {:ok, exhausted} =
                    AutoFix.exhausted_command("r1", @url, command, reason, "sha-#{spawned + 1}")

                  {:halt, {state, spawned, exhausted}}
              end
          end
        end)

      assert {_state, 2, %{type: "run.pr.fix_exhausted", payload: %{reason: "max_attempts"}}} =
               final
    end

    defp as_record(fixes), do: %{watching: true, fix: fixes}

    defp finish_fix(state, outcome, new_head) do
      {state, _} = accept(state, "run.pr.fix_started", %{pr_url: @url, jobsite_id: "js"})

      {state, _} =
        accept(state, "run.pr.fix_finished", %{
          pr_url: @url,
          outcome: outcome,
          new_head_sha: new_head
        })

      state
    end
  end
end
