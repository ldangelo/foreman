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

    test "source is stored as given: watch, gate or absent; any other value is refused" do
      for source <- ["watch", "gate"] do
        {_state, spec} = accept(started(), "run.pr.checks", checks_payload(%{source: source}))
        assert spec.payload.source == source
      end

      {_state, spec} = accept(started(), "run.pr.checks", checks_payload())
      assert spec.payload.source == nil

      for bad <- ["operator", "", :watch, 1] do
        assert {:error, {:missing_or_invalid, :source}} =
                 reject(started(), "run.pr.checks", checks_payload(%{source: bad}))
      end
    end

    test "the evidence fields are validated, normalised, stored, and replay to the live fold" do
      checks = [
        %{
          name: "unit",
          kind: :check_run,
          state: :failing,
          conclusion: "FAILURE",
          workflow: "ci",
          started_at: "2026-11-12T13:58:43Z",
          completed_at: "2026-11-12T13:58:49Z"
        }
      ]

      payload =
        checks_payload(%{
          checks: checks,
          checks_truncated: true,
          evidence_digest: "e1",
          observation_ref: "n-1",
          required: [%{name: "unit", kind: "check_run"}],
          policy_version: "p1"
        })

      {live, spec} = accept(started(), "run.pr.checks", payload)

      assert %{
               checks: [%{"name" => "unit", "kind" => "check_run", "state" => "failing"}],
               checks_truncated: true,
               evidence_digest: "e1",
               observation_ref: "n-1",
               required: [%{"name" => "unit", "kind" => "check_run"}],
               policy_version: "p1"
             } = spec.payload

      assert %{items: [%{"name" => "unit"}], truncated: true, evidence_digest: "e1"} =
               live.pr_watch[@url].evidence.checks

      # What the actor stores is JSON; folding it back (string keys) equals the live fold.
      replayed =
        Run.apply_event(started(), %{
          event_type: spec.event_type,
          payload: spec.payload |> Jason.encode!() |> Jason.decode!()
        })

      assert replayed.pr_watch == live.pr_watch
    end

    test "a payload without checks stores no list: it is nil, never zero checks" do
      {state, spec} = accept(started(), "run.pr.checks", checks_payload())
      assert spec.payload.checks == nil
      assert state.pr_watch[@url].evidence.checks == nil
    end

    test "unknown kind or state, a non-list, over 100 checks or over 20 required are refused" do
      good = %{name: "unit", kind: "check_run", state: "failing"}

      for {key, value} <- [
            {:checks, [%{good | kind: "webhook"}]},
            {:checks, [%{good | state: "great"}]},
            {:checks, "nope"},
            {:checks, List.duplicate(good, 101)},
            {:required, List.duplicate(%{name: "a", kind: "check_run"}, 21)},
            {:required, [%{name: "a"}]},
            {:checks_truncated, "yes"},
            {:policy_version, 7}
          ] do
        assert {:error, {:missing_or_invalid, ^key}} =
                 reject(started(), "run.pr.checks", checks_payload(%{key => value}))
      end
    end

    test "change is stored as given: digest, evidence or absent; any other value is refused" do
      for change <- ["digest", "evidence", nil] do
        {_state, spec} = accept(started(), "run.pr.checks", checks_payload(%{change: change}))
        assert spec.payload.change == change
      end

      for bad <- ["both", "", :digest, 1] do
        assert {:error, {:missing_or_invalid, :change}} =
                 reject(started(), "run.pr.checks", checks_payload(%{change: bad}))
      end
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

  describe "run.pr.ready_failed (TRD-033)" do
    defp ready_failed(extra \\ %{}) do
      Map.merge(
        %{pr_url: @url, stage: "head_read", reason: "gh_failed:1", failed_at: 5},
        extra
      )
    end

    for type <- ["RunCompleted", "RunFailed", "RunCancelled"] do
      test "is accepted on a #{type} run and folds into evidence.delivery_issue" do
        {state, spec} = accept(terminal(unquote(type)), "run.pr.ready_failed", ready_failed())

        assert spec.event_type == "PrReadyFailed"
        assert spec.stream_id == "run:r1"

        assert %{
                 run_id: "r1",
                 project_id: "p1",
                 task_id: "t1",
                 pr_url: @url,
                 stage: "head_read",
                 reason: "gh_failed:1",
                 failed_at: 5
               } = spec.payload

        assert state.pr_watch[@url].evidence.delivery_issue ==
                 %{stage: "head_read", reason: "gh_failed:1", failed_at: 5}
      end
    end

    test "carries the repo_id it is given and nothing else outside its fields" do
      {_state, spec} =
        accept(
          started(),
          "run.pr.ready_failed",
          ready_failed(%{repo_id: "b", gh_output: "secret"})
        )

      assert spec.payload.repo_id == "b"
      refute Map.has_key?(spec.payload, :gh_output)
    end

    test "needs an explicit pr_url, even when the run watches exactly one PR" do
      state = watched()

      assert {:error, {:missing_or_invalid, :pr_url}} =
               reject(state, "run.pr.ready_failed", Map.delete(ready_failed(), :pr_url))
    end

    test "refuses a stage outside head_read | ready_dispatch, a missing reason and a bad failed_at" do
      for stage <- ["push", "", nil, "HEAD_READ"] do
        assert {:error, {:missing_or_invalid, :stage}} =
                 reject(started(), "run.pr.ready_failed", ready_failed(%{stage: stage}))
      end

      assert {:error, {:missing_or_invalid, :reason}} =
               reject(started(), "run.pr.ready_failed", ready_failed(%{reason: nil}))

      assert {:error, {:missing_or_invalid, :failed_at}} =
               reject(started(), "run.pr.ready_failed", ready_failed(%{failed_at: "now"}))
    end

    test "a project or task the run does not own is refused" do
      assert {:error, {:missing_or_invalid, :project_id}} =
               reject(started(), "run.pr.ready_failed", ready_failed(%{project_id: "other"}))
    end

    test "a later PrReady clears the condition; a PrReady for another PR does not" do
      {state, _} = accept(started(), "run.pr.ready_failed", ready_failed())
      other = "https://github.com/acme/repo/pull/9"

      ready = fn state, url ->
        Run.apply_event(state, %{
          event_type: "PrReady",
          payload: %{run_id: "r1", pr_url: url, head_sha: "h", base_branch: "main"}
        })
      end

      assert ready.(state, other).pr_watch[@url].evidence.delivery_issue != nil
      assert ready.(state, @url).pr_watch[@url].evidence.delivery_issue == nil
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

  describe "run.pr.findings (TRD-015)" do
    alias ForemanServer.Events.ReviewFindingsRecorded
    alias ForemanServer.PrEvidence

    defp finding(extra \\ %{}) do
      Map.merge(
        %{
          "severity" => "major",
          "path" => "lib/a.ex",
          "line" => 12,
          "description" => "unchecked input",
          "disposition" => "open",
          "source" => "repo-rules"
        },
        extra
      )
    end

    defp findings_cmd(extra \\ %{}) do
      Map.merge(
        %{
          pr_url: @url,
          repo_id: nil,
          head_sha: "sha-1",
          status: "recorded",
          findings: [finding()],
          defect: nil,
          defect_detail: nil,
          artifact_path: "/w/review.md",
          artifact_sha256: String.duplicate("c", 64),
          recorded_at: 1_800_000_000_000
        },
        extra
      )
    end

    test "the command is a system command of PrWatch, not an operator one" do
      assert "run.pr.findings" in Run.PrWatch.command_types()
      assert "ReviewFindingsRecorded" in Run.PrWatch.event_types()
      refute "run.pr.findings" in Run.PrWatch.operator_types()
    end

    for type <- ["RunCompleted", "RunFailed", "RunCancelled"] do
      test "is accepted on a #{type} run: every declared field of the event survives" do
        state = terminal(unquote(type))
        {state, spec} = accept(state, "run.pr.findings", findings_cmd(%{repo_id: "repo-b"}))

        assert spec.event_type == "ReviewFindingsRecorded"
        assert spec.stream_id == "run:r1"

        declared = ReviewFindingsRecorded |> struct() |> Map.from_struct() |> Map.keys()
        assert Enum.sort(Map.keys(spec.payload)) == Enum.sort(declared)

        assert %{
                 run_id: "r1",
                 project_id: "p1",
                 task_id: "t1",
                 pr_url: @url,
                 repo_id: "repo-b",
                 head_sha: "sha-1",
                 status: "recorded",
                 findings: [%{"severity" => "major", "line" => 12}],
                 defect: nil,
                 defect_detail: nil,
                 artifact_path: "/w/review.md",
                 recorded_at: 1_800_000_000_000
               } = spec.payload

        assert spec.payload.artifact_sha256 == String.duplicate("c", 64)
        assert state.pr_watch[@url].evidence.findings.head_sha == "sha-1"
        assert state.pr_watch[@url].evidence.findings.digest == spec.payload.digest
      end
    end

    test "the digest is derived from the normalised content, never taken from the payload" do
      {_, one} = accept(started(), "run.pr.findings", findings_cmd())

      {_, other} =
        accept(
          started(),
          "run.pr.findings",
          findings_cmd(%{findings: [finding(%{"line" => 13})]})
        )

      {_, malformed} =
        accept(
          started(),
          "run.pr.findings",
          findings_cmd(%{status: "malformed", findings: [], defect: "invalid_json"})
        )

      assert one.payload.digest ==
               PrEvidence.findings_digest(%{
                 status: "recorded",
                 defect: nil,
                 findings: [finding()]
               })

      assert one.payload.digest =~ ~r/\A[0-9a-f]{16}\z/
      # two records that differ only in one finding have different digests
      assert one.payload.digest != other.payload.digest
      assert one.payload.digest != malformed.payload.digest

      assert {:error, {:derived_field, :digest}} =
               reject(started(), "run.pr.findings", findings_cmd(%{digest: one.payload.digest}))

      assert {:error, {:derived_field, :digest}} =
               reject(started(), "run.pr.findings", findings_cmd(%{digest: "forged"}))
    end

    test "absent and malformed records are appended with their status, defect and no findings" do
      {state, absent} =
        accept(
          started(),
          "run.pr.findings",
          findings_cmd(%{
            status: "absent",
            findings: [],
            artifact_path: nil,
            artifact_sha256: nil
          })
        )

      assert %{status: "absent", findings: [], defect: nil, artifact_path: nil} = absent.payload
      assert state.pr_watch[@url].evidence.findings.status == "absent"

      {state, malformed} =
        accept(
          state,
          "run.pr.findings",
          findings_cmd(%{
            status: "malformed",
            findings: nil,
            defect: "legacy_format",
            defect_detail: "bullets"
          })
        )

      assert %{
               status: "malformed",
               findings: [],
               defect: "legacy_format",
               defect_detail: "bullets"
             } =
               malformed.payload

      assert state.pr_watch[@url].evidence.findings.defect == "legacy_format"
    end

    test "the judgement is carried on the same event, bound to its head, and folded into evidence.findings.judgement" do
      judgement = %{status: "recorded", level: "HIGH", rationale: "touches auth"}
      {state, spec} = accept(started(), "run.pr.findings", findings_cmd(%{judgement: judgement}))

      assert spec.event_type == "ReviewFindingsRecorded"

      assert %{status: "recorded", level: "HIGH", rationale: "touches auth", defect: nil} =
               spec.payload.judgement

      folded = state.pr_watch[@url].evidence.findings
      assert folded.head_sha == "sha-1"
      assert folded.judgement == spec.payload.judgement

      # the same judgement with string keys (a replayed payload) folds to the same value
      string_keyed = %{"status" => "recorded", "level" => "HIGH", "rationale" => "touches auth"}
      assert PrEvidence.normalise_judgement(string_keyed) == folded.judgement
    end

    test "no judgement is an absent one, never a recorded or neutral level" do
      {state, spec} = accept(started(), "run.pr.findings", findings_cmd())

      assert %{status: "absent", level: nil, rationale: nil, defect: nil} = spec.payload.judgement
      assert state.pr_watch[@url].evidence.findings.judgement == spec.payload.judgement

      {_, explicit} =
        accept(
          started(),
          "run.pr.findings",
          findings_cmd(%{judgement: %{status: "absent"}})
        )

      assert explicit.payload.judgement == spec.payload.judgement
      # an absent judgement keeps the digest the record had before the field existed
      assert explicit.payload.digest == spec.payload.digest

      assert spec.payload.digest ==
               PrEvidence.findings_digest(%{
                 status: "recorded",
                 defect: nil,
                 findings: [finding()]
               })
    end

    test "the judgement is part of the digest: another level or a malformed one is a new record" do
      {state, absent} = accept(started(), "run.pr.findings", findings_cmd())

      recorded = %{status: "recorded", level: "LOW", rationale: "small"}
      {state, low} = accept(state, "run.pr.findings", findings_cmd(%{judgement: recorded}))

      {state, high} =
        accept(
          state,
          "run.pr.findings",
          findings_cmd(%{judgement: %{recorded | level: "HIGH"}})
        )

      {state, malformed} =
        accept(
          state,
          "run.pr.findings",
          findings_cmd(%{
            judgement: %{status: "malformed", defect: "multiple_blocks", defect_detail: "two"}
          })
        )

      digests = Enum.map([absent, low, high, malformed], & &1.payload.digest)
      assert digests == Enum.uniq(digests)

      assert %{status: "malformed", defect: "multiple_blocks", level: nil} =
               state.pr_watch[@url].evidence.findings.judgement

      # the same judgement for the same head is a no-op repeat
      assert {:ok, nil} =
               reject(
                 state,
                 "run.pr.findings",
                 findings_cmd(%{judgement: malformed.payload.judgement})
               )
    end

    test "an invalid judgement is rejected and nothing is appended" do
      for bad <- [
            %{status: "recorded", level: "CRITICAL", rationale: "x"},
            %{status: "recorded", level: "LOW"},
            %{status: "recorded", level: "LOW", rationale: String.duplicate("x", 1001)},
            %{status: "recorded", level: "LOW", rationale: "a\e[31mb"},
            %{status: "recorded", level: "LOW", rationale: "x", defect: "invalid_json"},
            %{status: "absent", level: "LOW"},
            %{status: "malformed", defect: "nonsense"},
            %{status: "malformed", level: "HIGH", defect: "invalid_json"},
            %{status: "recorded", level: "LOW", rationale: "x", extra: 1},
            "HIGH"
          ] do
        assert {:error, {:missing_or_invalid, :judgement}} =
                 reject(started(), "run.pr.findings", findings_cmd(%{judgement: bad}))
      end
    end

    test "an invalid payload is rejected and nothing is appended" do
      too_many = List.duplicate(finding(), 101)

      bad = [
        {%{findings: [finding(%{"severity" => "blocker"})]}, :findings},
        {%{findings: [finding(%{"disposition" => "later"})]}, :findings},
        {%{findings: [finding(%{"line" => -1})]}, :findings},
        {%{findings: too_many}, :findings},
        {%{findings: "all good"}, :findings},
        {%{status: "absent", findings: [finding()]}, :findings},
        {%{status: "malformed", findings: [finding()], defect: "invalid_json"}, :findings},
        {%{status: "malformed", findings: [], defect: "bad_defect"}, :defect},
        {%{status: "malformed", findings: [], defect: nil}, :defect},
        {%{defect: "invalid_json"}, :defect},
        {%{status: "clean"}, :status},
        {%{status: nil}, :status},
        {%{head_sha: nil}, :head_sha},
        {%{head_sha: ""}, :head_sha},
        {%{defect_detail: String.duplicate("d", 501)}, :defect_detail},
        {%{artifact_sha256: "abc"}, :artifact_sha256},
        {%{artifact_sha256: String.duplicate("z", 64)}, :artifact_sha256},
        {%{artifact_path: String.duplicate("p", 1025)}, :artifact_path},
        {%{recorded_at: "now"}, :recorded_at},
        {%{recorded_at: nil}, :recorded_at},
        {%{recorded_at: -1}, :recorded_at},
        {%{project_id: "other"}, :project_id},
        {%{repo_id: ""}, :repo_id},
        {%{repo_id: 7}, :repo_id},
        {%{defect_detail: "a clean review has no defect text"}, :defect_detail}
      ]

      for {override, key} <- bad do
        assert {:error, {:missing_or_invalid, ^key}} =
                 reject(started(), "run.pr.findings", findings_cmd(override)),
               "override #{inspect(override)}"
      end

      assert {:error, {:missing_or_invalid, :pr_url}} =
               reject(started(), "run.pr.findings", Map.delete(findings_cmd(), :pr_url))

      assert {:error, {:not_found, :run, "r1"}} =
               Run.handle_command(Run.initial_state(), %{
                 type: "run.pr.findings",
                 payload: Map.put(findings_cmd(), :run_id, "r1")
               })
    end

    test "the same content for one head appends nothing; another head or other content appends" do
      {state, first} = accept(started(), "run.pr.findings", findings_cmd())

      # the same content again, even with another artifact and timestamp: a no-op
      assert {:ok, nil} =
               reject(
                 state,
                 "run.pr.findings",
                 findings_cmd(%{recorded_at: 2, artifact_path: "/other.md"})
               )

      {state2, second} = accept(state, "run.pr.findings", findings_cmd(%{head_sha: "sha-2"}))
      assert second.payload.digest == first.payload.digest
      assert state2.pr_watch[@url].evidence.findings.head_sha == "sha-2"

      {_, third} =
        accept(state2, "run.pr.findings", findings_cmd(%{head_sha: "sha-2", findings: []}))

      assert third.payload.digest != first.payload.digest

      # A, then B, then A again for one head is a change each time
      {state3, _} = accept(state, "run.pr.findings", findings_cmd(%{findings: []}))
      assert {:ok, %{}} = reject(state3, "run.pr.findings", findings_cmd())
    end

    test "the same content from a different artifact appends nothing and keeps the first artifact" do
      {state, first} = accept(started(), "run.pr.findings", findings_cmd())

      # TRD-015: "the same content recorded twice for one head (the same `digest`), then the
      # second command appends nothing". The artifact is not part of the digest, so a re-record
      # of the same findings from another artifact is that no-op and `evidence.findings` keeps
      # the first artifact's path and hash (TRD-034/TRD-041 must not rely on a refresh).
      again =
        findings_cmd(%{artifact_path: "/w/other.md", artifact_sha256: String.duplicate("d", 64)})

      assert {:ok, nil} = reject(state, "run.pr.findings", again)
      assert state.pr_watch[@url].evidence.findings.artifact_sha256 == String.duplicate("c", 64)
      assert state.pr_watch[@url].evidence.findings.artifact_path == first.payload.artifact_path
    end

    test "it is not a head observation: the PR's head, checks and watching are untouched" do
      state = watched()

      before =
        Map.take(state.pr_watch[@url], [
          :head_sha,
          :checks_state,
          :checks_digest,
          :watching,
          :status
        ])

      {state, _} = accept(state, "run.pr.findings", findings_cmd(%{head_sha: "sha-9"}))
      assert Map.take(state.pr_watch[@url], Map.keys(before)) == before
      assert state.pr_watch[@url].evidence.findings.head_sha == "sha-9"
    end

    test "a record belongs to its PR only: another PR of the run evaluates findings_absent" do
      other = "https://github.com/acme/other/pull/3"
      {state, _} = accept(watched(), "run.pr.findings", findings_cmd())

      {state, _} =
        accept(state, "run.pr.checks", checks_payload(%{pr_url: other, repo_id: "repo-b"}))

      ctx = %{
        head_sha: "sha-1",
        policy: %{required: [], version: "v1"},
        now_ms: 1,
        checks_ref: nil
      }

      codes = fn url ->
        state.pr_watch[url]
        |> PrEvidence.evaluate(ctx)
        |> Map.fetch!(:reasons)
        |> Enum.map(& &1.code)
      end

      refute :findings_absent in codes.(@url)
      assert :findings_absent in codes.(other)
      assert state.pr_watch[other].evidence.findings == nil
    end
  end

  test "every event PrWatch can emit advances the run state (the lists cannot diverge)" do
    other = "https://github.com/acme/repo/pull/8"

    steps = [
      {"run.pr.ready_failed",
       %{pr_url: @url, stage: "head_read", reason: "gh_failed:1", failed_at: 5}},
      {"run.pr.findings",
       %{pr_url: @url, head_sha: "sha-1", status: "recorded", findings: [], recorded_at: 6}},
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

    # `PrEvidenceWaived` is emitted by the `Run` aggregate's own operator-only clause beside
    # `merge_approve`, not by a `PrWatch` command: the waiver tests cover it.
    assert Enum.sort(Enum.uniq(emitted)) ==
             Enum.sort(Run.PrWatch.event_types() -- ["PrEvidenceWaived"])
  end
end
