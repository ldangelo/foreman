defmodule ForemanServer.Workflow.RunExecutorPrReadyTest do
  # `run.pr.ready` is what puts a finished run's PR into the merge gate. The
  # Run aggregate handler, the `PrReady` event and `MergeGate` all existed, but
  # nothing in `lib/` ever dispatched the command, so `merge_gate` stayed nil and
  # `run.pr.merge` was refused for every real run. These tests drive the real
  # dispatch (real git, real event store, real aggregate) and read back the one
  # observable that matters: whether the gate is engaged for the run.
  use ExUnit.Case, async: false

  alias ForemanServer.Workflow.MergeGate
  alias ForemanServer.Workflow.RunExecutor

  setup do
    case GenServer.whereis(MergeGate) do
      nil -> {:ok, _pid} = MergeGate.start_link()
      _pid -> :ok
    end

    MergeGate.clear()

    repo = Path.join(System.tmp_dir!(), "pr-ready-#{System.unique_integer([:positive])}")
    File.rm_rf!(repo)
    File.mkdir_p!(repo)
    git!(repo, ["init", "--initial-branch=main", "--quiet"])
    git!(repo, ["config", "user.email", "t@x"])
    git!(repo, ["config", "user.name", "T"])
    File.write!(Path.join(repo, "README.md"), "seed")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "--no-gpg-sign", "-m", "seed", "--quiet"])
    git!(repo, ["branch", "foreman/run-branch"])

    run_id = "run-pr-ready-#{System.unique_integer([:positive])}"
    started = %{run_id: run_id, project_id: "project-pr-ready"}

    :ok =
      ForemanServer.EventStore.append_to_stream("run:#{run_id}", 0, [
        %EventStore.EventData{event_type: "RunStarted", data: started, metadata: %{}}
      ])

    :ok =
      ForemanServer.ProjectionStore.apply_events([
        %{event_type: "RunStarted", payload: started}
      ])

    on_exit(fn -> File.rm_rf(repo) end)

    %{repo: repo, run_id: run_id}
  end

  @pr_url "https://github.com/acme/repo/pull/42"

  test "a finished run's PR engages the merge gate", %{repo: repo, run_id: run_id} do
    refute MergeGate.pending_for_key?("run:#{run_id}")

    assert :ok = RunExecutor.__signal_pr_ready_for_test__(state(repo, run_id), @pr_url)

    assert MergeGate.pending_for_key?("run:#{run_id}"),
           "run.pr.ready must have put the PR into the merge gate"
  end

  # Found by the live acceptance run: with `stack_pr: true` the phase PR
  # suppressed the final auto-PR, and nothing then associated it with the run or
  # signalled `run.pr.ready`, so the thread never reached the merge gate.
  test "a run whose phase PR suppresses the final auto-PR still yields that PR for the merge gate",
       %{run_id: run_id} do
    phase_pr = fn index, status, url ->
      %{
        run_id: run_id,
        phase_id: "#{run_id}-p00#{index}",
        phase_index: index,
        phase_name: "phase-#{index}",
        status: status,
        pr_url: url,
        pr_number: index,
        base_branch: "main",
        head_branch: "foreman/run-branch",
        provider: "github",
        recorded_at: "2026-01-01T00:00:0#{index}Z"
      }
    end

    :ok =
      ForemanServer.ProjectionStore.apply_events([
        %{
          event_type: "PhasePrRecorded",
          payload: phase_pr.(1, "created", "https://github.com/acme/repo/pull/7")
        },
        %{
          event_type: "PhasePrRecorded",
          payload: phase_pr.(2, "existing", "https://github.com/acme/repo/pull/8")
        },
        %{event_type: "PhasePrRecorded", payload: phase_pr.(3, "noop", nil)}
      ])

    assert {:ok, "https://github.com/acme/repo/pull/8"} =
             RunExecutor.__maybe_auto_pr_for_test__(%{run_id: run_id})
  end

  test "signalling twice appends exactly one PrReady event", %{repo: repo, run_id: run_id} do
    st = state(repo, run_id)

    assert :ok = RunExecutor.__signal_pr_ready_for_test__(st, @pr_url)
    assert :ok = RunExecutor.__signal_pr_ready_for_test__(st, @pr_url)

    {:ok, events} = ForemanServer.EventStore.read_stream_forward("run:#{run_id}", 0, 1_000)

    assert Enum.count(events, &(&1.event_type == "PrReady")) == 1,
           "a repeated signal must not append a second PrReady (it would re-pend an approved gate)"
  end

  test "PrReady records the head AutoPR resolves from the artifact's FOREMAN_BRANCH override", %{
    repo: repo,
    run_id: run_id
  } do
    git!(repo, ["branch", "agent/chosen"])
    git!(repo, ["checkout", "--quiet", "agent/chosen"])
    File.write!(Path.join(repo, "chosen.txt"), "x")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "--no-gpg-sign", "-m", "on chosen", "--quiet"])
    chosen_sha = git!(repo, ["rev-parse", "agent/chosen"]) |> String.trim()
    refute chosen_sha == git!(repo, ["rev-parse", "foreman/run-branch"]) |> String.trim()

    artifact = Path.join(repo, "artifact.md")
    File.write!(artifact, "done\nFOREMAN_BRANCH=agent/chosen\n")

    st = %{state(repo, run_id) | current_phase: 0, phase_specs: [%{artifact_template: artifact}]}

    assert :ok = RunExecutor.__signal_pr_ready_for_test__(st, @pr_url)

    {:ok, events} = ForemanServer.EventStore.read_stream_forward("run:#{run_id}", 0, 1_000)
    [ready] = Enum.filter(events, &(&1.event_type == "PrReady"))

    assert ready.data.branch_name == "agent/chosen"
    assert ready.data.head_sha == chosen_sha
  end

  test "an unresolvable head branch fails loudly and never engages the gate", %{
    repo: repo,
    run_id: run_id
  } do
    bad = put_in(state(repo, run_id), [:last_worktree, :branch], "no/such/branch")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        RunExecutor.__signal_pr_ready_for_test__(bad, @pr_url)
      end)

    assert log =~ "run.pr.ready was NOT signalled"
    refute MergeGate.pending_for_key?("run:#{run_id}")
  end

  test "a run whose base branch was never recorded fails loudly and never engages the gate", %{
    repo: repo,
    run_id: run_id
  } do
    no_base = Map.delete(state(repo, run_id), :run_base_branch)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        RunExecutor.__signal_pr_ready_for_test__(no_base, @pr_url)
      end)

    assert log =~ "run.pr.ready was NOT signalled"
    refute MergeGate.pending_for_key?("run:#{run_id}")
  end

  defp state(repo, run_id) do
    %{
      run_id: run_id,
      task: %{task_id: "task-pr-ready", project_id: "project-pr-ready"},
      plan_context: %{"project_root" => repo},
      run_base_branch: {:ok, "main"},
      last_worktree: %{branch: "foreman/run-branch"},
      current_phase: nil,
      phase_specs: []
    }
  end

  defp git!(root, args) do
    {out, 0} = System.cmd("git", ["-C", root | args], stderr_to_stdout: true)
    out
  end
end
