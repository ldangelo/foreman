defmodule ForemanServer.TaskProviders.KataLifecycleTest do
  @moduledoc """
  A Foreman run's life against a Kata project (TRD-KATA-T033..T036): the claim before any agent is
  dispatched, the close on success, and the reopen, comment and release on failure.

  Every run goes through the production entry points. The real `RunExecutor` GenServer drives a
  real phase on the Jobsite engine, in a real git worktree, and the real `KataAdapter` answers its
  provider calls. Only the `kata` process boundary is scripted (`KataRunnerMock`, through
  `KataScript`), so each test asserts the exact `kata` argv sequence the run produced.

  ## Ordering of the close and the phase commit (TRD-KATA-T034)

  `RunExecutor` closes the task from `finalize_run/1`, which `finish_phases/1` reaches only after the
  Jobsite engine has run every phase to its end, the `:commit` step included. The close therefore
  cannot fire before a phase's commit. "close issued after the commit" below asserts it on the
  repository: the branch tip is read from inside the scripted `kata close`, while the close is being
  issued, and must already be the commit the close names.
  """

  use ExUnit.Case, async: false

  import Mox

  alias ForemanServer.{AgentRuntime, CommandGateway, EventStore, ProjectionStore, RunAdmission}
  alias ForemanServer.AgentRuntime.AdapterCatalog
  alias ForemanServer.TaskProvider.Issue
  alias ForemanServer.TaskProvider.Registry, as: TaskProviderRegistry
  alias ForemanServer.TaskProviders.BeadsAdapter.CodeMap.ProviderErrorInput
  alias ForemanServer.TaskProviders.KataAdapter
  alias ForemanServer.TaskProviders.KataAdapter.BuildProviderError
  alias ForemanServer.TaskProviders.KataRunnerMock
  alias ForemanServer.TaskProviders.ProviderError
  alias ForemanServer.Test.Support.CapabilityStubProvider
  alias ForemanServer.TestSupport.{DispatcherRestart, RunSlotsReset}
  alias ForemanServer.Workflow.RunExecutor

  @poll_timeout_ms 8_000
  @claim_lost_event [:foreman_server, :task_provider, :claim, :lost]
  # Kata's effective actor (`$.actor` of `kata status`). It is deliberately not the actor Foreman is
  # configured with, so an argv that carries it can only have read it from `status`.
  @kata_actor "kata-daemon-actor"
  @foreman_actor "foreman-runner"
  # `fail_retry_loop/5` waits a second before its first retry; a test that proves "no retry" waits
  # longer than that.
  @retry_window_ms 1_500

  defmodule LifecycleStore do
    @moduledoc false
    use Agent

    def start_link(opts \\ []) do
      Agent.start_link(fn -> %{} end, Keyword.put_new(opts, :name, __MODULE__))
    end

    def clear, do: Agent.update(__MODULE__, fn _ -> %{} end)

    def put(script_key, data), do: Agent.update(__MODULE__, &Map.put(&1, script_key, data))

    def test_pid(script_key), do: Agent.get(__MODULE__, &get_in(&1, [script_key, :test_pid]))

    def take(script_key, field, default) do
      Agent.get_and_update(__MODULE__, fn state ->
        script = Map.get(state, script_key, %{})

        {result, rest} =
          case Map.get(script, field, []) do
            [value | tail] -> {value, tail}
            [] -> {default, []}
          end

        {result, Map.put(state, script_key, Map.put(script, field, rest))}
      end)
    end

    # Overwatch relaunches a crashed worker, and a clean exit does not seal the Worker aggregate, so
    # only the first launch of a phase may drive its script.
    def claim_execution(script_key) do
      Agent.get_and_update(__MODULE__, fn state ->
        script = Map.get(state, script_key, %{})

        if Map.get(script, :claimed?, false) do
          {false, state}
        else
          {true, Map.put(state, script_key, Map.put(script, :claimed?, true))}
        end
      end)
    end
  end

  # The legacy synchronous backend `Overwatch` still resolves a provider through; the phases run on
  # `TestWorkerAdapter` below.
  defmodule TestAdapter do
    @moduledoc false
    @behaviour ForemanServer.AgentRuntime.BackendAdapter

    @impl true
    def name, do: :pi

    @impl true
    def capabilities do
      %{
        type: :cli,
        strengths: [:workflow_execution],
        weaknesses: [:none],
        supported_contexts: [:implement, :test]
      }
    end

    @impl true
    def available?, do: true

    @impl true
    def execute(_request, _opts), do: {:ok, "artifact body", %{}}
  end

  # The agent of a phase, on the Overwatch worker protocol (see
  # `ForemanServer.Overwatch.Adapters.JidoHarnessWorker`). It reports the prompt and the worktree it
  # was handed to the test, runs the phase's `after_execute` script inside that worktree (the
  # agent's own file writes and commits), and answers with the scripted `adapter_results`.
  defmodule TestWorkerAdapter do
    @moduledoc false
    use GenServer

    alias ForemanServer.Overwatch.WorkerProtocol

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_info({:overwatch_activate, _worker_id, _run_id, parent}, state) do
      send(parent, {:overwatch_activated, self()})
      send(self(), :run)
      {:noreply, state}
    end

    def handle_info(:run, state) do
      context = Map.get(Keyword.fetch!(state, :phase), :context, %{})
      script_key = Map.fetch!(context, "script_key")

      if Process.whereis(LifecycleStore) != nil and LifecycleStore.claim_execution(script_key) do
        result = run_phase(state, context, script_key)

        _ =
          WorkerProtocol.emit(:worker_exited, %{
            worker_id: Keyword.fetch!(state, :worker_id),
            run_id: Keyword.fetch!(state, :run_id)
          })

        case Keyword.get(state, :result_recipient) do
          pid when is_pid(pid) -> send(pid, {:worker_result, result})
          _ -> :ok
        end
      else
        _ =
          WorkerProtocol.emit(:worker_exited, %{
            worker_id: Keyword.fetch!(state, :worker_id),
            run_id: Keyword.fetch!(state, :run_id)
          })
      end

      {:stop, :normal, state}
    end

    def handle_info(_msg, state), do: {:noreply, state}

    defp run_phase(state, context, script_key) do
      env = Keyword.get(state, :env_map, %{})

      if pid = LifecycleStore.test_pid(script_key) do
        send(pid, {:adapter_execute, Keyword.fetch!(state, :prompt), context})
        send(pid, {:adapter_env, env})
      end

      result = LifecycleStore.take(script_key, :adapter_results, {:ok, "artifact body", %{}})

      case LifecycleStore.take(script_key, :after_execute, nil) do
        fun when is_function(fun, 1) -> fun.(Map.fetch!(env, "FOREMAN_WORKTREE_PATH"))
        _ -> :ok
      end

      case result do
        {:ok, content, _metadata} -> {:ok, content}
        other -> other
      end
    end
  end

  # What the `kata` CLI answers, per verb, and every call it received, in order. Each call to a verb
  # takes the next reply queued for that verb (a reply is a runner result, or a one-argument function
  # of the argv that returns one); a call with nothing queued is answered with a runner failure and
  # reported to the test as `{:kata_unscripted, argv}`, so a call the run was not supposed to make can
  # never pass unnoticed. Every call is also sent to the test as `{:kata_cmd, argv, cwd, opts}`.
  defmodule KataScript do
    @moduledoc false
    use Agent

    alias ForemanServer.TaskProviders.BeadsAdapter.CodeMap.ProviderErrorInput
    alias ForemanServer.TaskProviders.KataAdapter.BuildProviderError

    def start_link(_arg) do
      Agent.start_link(fn -> %{replies: %{}, calls: []} end, name: __MODULE__)
    end

    def script(replies) when is_map(replies) do
      Agent.update(__MODULE__, &%{&1 | replies: replies})
    end

    def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

    def verbs, do: Enum.map(calls(), &hd/1)

    # `KataAdapter.available?/0` probes this when a project is registered; it is not a run's call.
    def call(["--version"], _cwd, _opts, _test_pid), do: {:ok, "kata v0.23.0\n"}

    def call([verb | _arguments] = argv, cwd, opts, test_pid) do
      taken =
        Agent.get_and_update(__MODULE__, fn state ->
          state = %{state | calls: [argv | state.calls]}

          case Map.get(state.replies, verb, []) do
            [reply | rest] ->
              {{:ok, reply}, %{state | replies: Map.put(state.replies, verb, rest)}}

            [] ->
              {:unscripted, state}
          end
        end)

      send(test_pid, {:kata_cmd, argv, cwd, opts})

      case taken do
        {:ok, reply} when is_function(reply, 1) ->
          reply.(argv)

        {:ok, reply} ->
          reply

        :unscripted ->
          send(test_pid, {:kata_unscripted, argv})

          {:error,
           BuildProviderError.build_provider_error(
             ProviderErrorInput.from_local(
               "BR_ERROR_ENVELOPE",
               "Kata CLI exited with a non-zero status.",
               nil,
               false
             ),
             1,
             0
           )}
      end
    end
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:mox)
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = Application.ensure_all_started(:eventstore)

    ensure_started({Phoenix.PubSub, name: ForemanServer.PubSub}, ForemanServer.PubSub)
    ensure_started(ForemanServerWeb.Presence, ForemanServerWeb.Presence)
    ensure_started(ForemanServer.EventStore, ForemanServer.EventStore)
    ensure_started(ForemanServer.ProjectionStore, ForemanServer.ProjectionStore)
    ensure_started(ForemanServer.Aggregator, ForemanServer.Aggregator)

    ensure_started(
      {Registry, keys: :unique, name: ForemanServer.RunExecutorRegistry},
      ForemanServer.RunExecutorRegistry
    )

    ensure_started(ForemanServer.CommandRouter, ForemanServer.CommandRouter)
    ensure_started(AdapterCatalog, AdapterCatalog)

    ensure_started(
      ForemanServer.AgentRuntime.InvocationSupervisor,
      ForemanServer.AgentRuntime.InvocationSupervisor
    )

    ensure_started(TaskProviderRegistry, TaskProviderRegistry)

    ensure_started(
      ForemanServer.Agents.JidoShellRunner,
      ForemanServer.Agents.JidoShellRunner
    )

    # Phase execution always goes through `Overwatch.start_phase/2`; it is off by default in the
    # test config, and this file drives whole phases.
    ensure_started(ForemanServer.Overwatch, ForemanServer.Overwatch)

    previous_backend_adapter = previous_backend_adapter()
    ensure_test_adapter_registered(previous_backend_adapter)
    on_exit(fn -> restore_backend_adapter(previous_backend_adapter) end)

    :ok
  end

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    test_pid = self()
    RunSlotsReset.reset!()

    previous_worker_adapter = Application.get_env(:foreman_server, :worker_adapter)
    Application.put_env(:foreman_server, :worker_adapter, TestWorkerAdapter)

    previous_task_provider = Application.get_env(:foreman_server, :task_provider, [])

    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: @foreman_actor,
      accepted_contract_versions: ["br.capabilities.v1", "kata.capabilities.v1"],
      providers: [KataAdapter]
    )

    # `KataAdapter.available?/0` needs a `kata` on PATH before it asks the runner; the runner itself
    # is the mock, so this one never runs.
    temp_dir =
      Path.join(System.tmp_dir!(), "kata_lifecycle_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(temp_dir, "bin"))
    File.write!(Path.join([temp_dir, "bin", "kata"]), "#!/bin/sh\nexit 0\n")
    File.chmod!(Path.join([temp_dir, "bin", "kata"]), 0o755)
    original_path = System.get_env("PATH") || ""
    System.put_env("PATH", Path.join(temp_dir, "bin") <> ":" <> original_path)

    ForemanServer.TestSupport.TestApplication.reset_application_child!(TaskProviderRegistry)

    dispatcher = Process.whereis(ForemanServer.Workflow.Dispatcher)

    if dispatcher do
      :sys.suspend(dispatcher)
      on_exit(fn -> DispatcherRestart.restart!() end)
    end

    start_supervised!({LifecycleStore, name: LifecycleStore})
    LifecycleStore.clear()
    start_supervised!(KataScript)

    stub(KataRunnerMock, :cmd, fn argv, cwd, opts ->
      KataScript.call(argv, cwd, opts, test_pid)
    end)

    lost_ref = :telemetry_test.attach_event_handlers(test_pid, [@claim_lost_event])

    on_exit(fn ->
      :telemetry.detach(lost_ref)

      case previous_worker_adapter do
        nil -> Application.delete_env(:foreman_server, :worker_adapter)
        adapter -> Application.put_env(:foreman_server, :worker_adapter, adapter)
      end

      Application.put_env(:foreman_server, :task_provider, previous_task_provider)
      System.put_env("PATH", original_path)
      File.rm_rf!(temp_dir)
    end)

    {:ok, lost_ref: lost_ref}
  end

  describe "claim (TRD-KATA-T033: AC-011-1, AC-011-2, AC-011-3)" do
    test "a run claims its task in the project's workspace before any agent is dispatched" do
      run = new_run!([[agent: :nothing]])
      KataScript.script(%{"claim" => [claim_reply(run.ref)], "close" => [close_reply(run.ref)]})
      start_executor!(run)

      assert {:kata_cmd, ["claim", ref, "--if-unowned", "--json"], cwd, []} =
               receive_message(@poll_timeout_ms)

      assert ref == run.ref
      assert cwd == run.repo

      # AC-011-1: the agent starts only after Kata answered the claim.
      assert {:adapter_execute, "Run phase implement-1", _context} =
               receive_message(@poll_timeout_ms)

      assert %{status: "completed"} = await_run!(run.run_id, "completed")
      assert_kata_calls(["claim", "close"])
    end

    test "a claim another actor holds is refused with a typed error, and a task that is no longer ready is lost after one refresh",
         %{lost_ref: lost_ref} do
      project = seed_kata_project!()
      ref = new_ref()

      KataScript.script(%{
        "claim" => [runner_exit(5)],
        "ready" => [ok(%{"issues" => []})]
      })

      assert {:error, %ProviderError{code: "CLAIMED_BY_OTHER", retryable?: false} = error} =
               RunExecutor.claim(project.project_id, ref, @foreman_actor, unique_id("run"))

      # AC-013-2: the closed context key set carries no owner identity, not even a presence flag.
      assert Enum.sort(Map.keys(error.context)) == Enum.sort(BuildProviderError.context_keys())

      # AC-011-2: the ready set is refreshed once. The task is not in it, so there is no retry.
      assert KataScript.calls() == [
               ["claim", ref, "--if-unowned", "--json"],
               ["ready", "--unowned", "--json"]
             ]

      # AC-011-3: the loss is recorded on the provider-scoped event.
      assert_received {@claim_lost_event, ^lost_ref, %{count: 1}, %{}}
      assert_kata_calls(["claim", "ready"])
    end

    test "a task that is ready again after the refresh is claimed once more, and is not lost",
         %{lost_ref: lost_ref} do
      project = seed_kata_project!()
      ref = new_ref()

      KataScript.script(%{
        "claim" => [runner_exit(5), claim_reply(ref)],
        "ready" => [ok(%{"issues" => [ready_record(ref)]})]
      })

      assert {:ok, %Issue{id: ^ref, assignee: @kata_actor}} =
               RunExecutor.claim(project.project_id, ref, @foreman_actor, unique_id("run"))

      assert_kata_calls(["claim", "ready", "claim"])
      refute_received {@claim_lost_event, ^lost_ref, _measurements, _metadata}
    end

    test "a claim refused again after the refresh is lost, and is never attempted a third time",
         %{lost_ref: lost_ref} do
      project = seed_kata_project!()
      ref = new_ref()

      KataScript.script(%{
        "claim" => [runner_exit(5), runner_exit(5)],
        "ready" => [ok(%{"issues" => [ready_record(ref)]})]
      })

      assert {:error, %ProviderError{code: "CLAIMED_BY_OTHER", retryable?: false}} =
               RunExecutor.claim(project.project_id, ref, @foreman_actor, unique_id("run"))

      # One refresh, one retry. A third claim (or a second refresh) would be an unscripted call.
      assert_kata_calls(["claim", "ready", "claim"])
      assert_received {@claim_lost_event, ^lost_ref, %{count: 1}, %{}}
      refute_received {@claim_lost_event, ^lost_ref, _measurements, _metadata}
    end

    test "a claim that fails for another reason is returned as it came: no refresh, no loss",
         %{lost_ref: lost_ref} do
      project = seed_kata_project!()
      ref = new_ref()
      KataScript.script(%{"claim" => [runner_timeout()]})

      assert {:error, %ProviderError{code: "BR_TIMEOUT_SUBPROCESS", retryable?: true}} =
               RunExecutor.claim(project.project_id, ref, @foreman_actor, unique_id("run"))

      assert_kata_calls(["claim"])
      refute_received {@claim_lost_event, ^lost_ref, _measurements, _metadata}
    end

    test "a refresh that fails proves nothing about the claim: the refusal comes back and no loss is recorded",
         %{lost_ref: lost_ref} do
      project = seed_kata_project!()
      ref = new_ref()

      KataScript.script(%{
        "claim" => [runner_exit(5)],
        "ready" => [runner_exit(1)]
      })

      assert {:error, %ProviderError{code: "CLAIMED_BY_OTHER"}} =
               RunExecutor.claim(project.project_id, ref, @foreman_actor, unique_id("run"))

      assert_kata_calls(["claim", "ready"])
      refute_received {@claim_lost_event, ^lost_ref, _measurements, _metadata}
    end

    test "a lost claim fails the run before any agent is dispatched, and the run never touches the task",
         %{lost_ref: lost_ref} do
      run = new_run!([[agent: :nothing]])

      KataScript.script(%{
        "claim" => [runner_exit(5)],
        "ready" => [ok(%{"issues" => []})]
      })

      start_executor!(run)

      assert %{failure_reason: reason} = await_task!(run.task_id, "failed")
      assert reason =~ ":claim_failure"
      assert reason =~ "CLAIMED_BY_OTHER"
      assert %{status: "failed"} = await_run!(run.run_id, "failed")

      assert_receive {@claim_lost_event, ^lost_ref, %{count: 1}, %{}}, @poll_timeout_ms
      refute_received {:adapter_execute, _prompt, _context}

      # The task was never claimed, so there is nothing to reopen, comment on or release: writing to
      # it would touch another actor's task.
      assert_kata_calls(["claim", "ready"])
    end
  end

  describe "complete (TRD-KATA-T034: AC-012-1, AC-012-3, AC-012-4, AC-013-1)" do
    test "a phase commit by Foreman closes the task with that commit, issued after the commit exists" do
      run = new_run!([[agent: :dirty]])
      test_pid = self()

      KataScript.script(%{
        "claim" => [claim_reply(run.ref)],
        "close" => [
          fn _argv ->
            # Evaluated while the close is being issued.
            send(test_pid, {:tip_at_close, git!(run.repo, ["rev-parse", "--verify", run.branch])})
            close_reply(run.ref)
          end
        ]
      })

      start_executor!(run)

      assert %{status: "completed"} = await_run!(run.run_id, "completed")

      assert [_claim, ["close", ref, "--done", "--message", message, "--commit", sha, "--json"]] =
               KataScript.calls()

      assert ref == run.ref

      # The commit Foreman's `:commit` step made for the phase, and the only commit of the run.
      assert git!(run.repo, ["log", "-1", "--format=%s", run.branch]) ==
               "Foreman run #{run.run_id} phase 1"

      assert git!(run.repo, ["rev-list", "--count", "#{run.base}..#{run.branch}"]) == "1"
      assert sha == git!(run.repo, ["rev-parse", "--verify", run.branch])

      # Ordering: when the close was issued, the commit it names was already the branch tip.
      assert_received {:tip_at_close, tip_at_close}
      assert tip_at_close == sha

      # The commit is the evidence: no artifact fallback rides along.
      close = List.last(KataScript.calls())
      refute "--evidence" in close

      # AC-012-3: the default message names the run and the artifact, and is at least 40 characters.
      assert String.starts_with?(message, "foreman-run:#{run.run_id}:#{artifact_path(run, 1)}")
      assert String.length(message) >= 40

      assert %{status: "closed"} = await_task!(run.task_id, "closed")
      assert count_task_events(run.task_id, "TaskExecutionCompleted") == 1
      assert_kata_calls(["claim", "close"])
    end

    test "commits the agent made itself count: a clean tree at the commit step still closes with the agent's commit" do
      run = new_run!([[agent: :agent_commit]])
      script_claim_and_close!(run)
      start_executor!(run)

      assert %{status: "completed"} = await_run!(run.run_id, "completed")

      # Foreman's commit step found nothing to commit: the only commit is the agent's.
      assert git!(run.repo, ["rev-list", "--count", "#{run.base}..#{run.branch}"]) == "1"
      assert git!(run.repo, ["log", "-1", "--format=%s", run.branch]) == "agent work"

      assert [_claim, ["close" | _] = close] = KataScript.calls()
      assert flag_values(close, "--commit") == [git!(run.repo, ["rev-parse", run.branch])]
      refute "--evidence" in close
      assert_kata_calls(["claim", "close"])
    end

    test "with several commits the close names the newest, the tip of the run's branch" do
      run = new_run!([[agent: :dirty], [agent: :agent_commit]])
      script_claim_and_close!(run)
      start_executor!(run)

      assert %{status: "completed"} = await_run!(run.run_id, "completed")

      # Phase 1: Foreman's commit. Phase 2: the agent's own, leaving a clean tree.
      assert git!(run.repo, ["rev-list", "--count", "#{run.base}..#{run.branch}"]) == "2"
      tip = git!(run.repo, ["rev-parse", run.branch])
      older = git!(run.repo, ["rev-parse", "#{run.branch}~1"])
      assert tip != older

      assert [_claim, close] = KataScript.calls()
      assert flag_values(close, "--commit") == [tip]
      refute older in close
    end

    test "a run whose only phase declares commit: false made no commit, so the close names none and falls back to the artifact" do
      run = new_run!([[agent: :dirty, commit: false]])
      script_claim_and_close!(run)
      start_executor!(run)

      assert %{status: "completed"} = await_run!(run.run_id, "completed")

      # The deferred work was never committed: the branch tip is still the commit the run was cut
      # from, which predates the run. Naming it would claim a commit the run never made.
      assert git!(run.repo, ["rev-list", "--count", "#{run.base}..#{run.branch}"]) == "0"
      assert git!(run.repo, ["rev-parse", run.branch]) == run.base

      assert [_claim, close] = KataScript.calls()
      refute "--commit" in close
      refute run.base in close
      assert flag_values(close, "--evidence") == ["reviewed-paths:#{artifact_path(run, 1)}"]
      assert File.regular?(artifact_path(run, 1))
    end

    test "a phase with nothing to commit and no commits of the agent's own closes with the artifact, not a sha" do
      run = new_run!([[agent: :nothing]])
      script_claim_and_close!(run)
      start_executor!(run)

      assert %{status: "completed"} = await_run!(run.run_id, "completed")

      assert git!(run.repo, ["rev-parse", run.branch]) == run.base

      assert [_claim, close] = KataScript.calls()
      refute "--commit" in close
      refute run.base in close
      assert flag_values(close, "--evidence") == ["reviewed-paths:#{artifact_path(run, 1)}"]
    end

    test "Kata refusing the close is a typed provider error; the run fails and does not report the task closed" do
      run = new_run!([[agent: :dirty]])

      KataScript.script(%{
        "claim" => [claim_reply(run.ref)],
        "close" => [runner_exit(3)]
      })

      start_executor!(run)

      assert %{status: "failed", failure_reason: reason} = await_run!(run.run_id, "failed")
      assert reason =~ "VALIDATION_FAILED"
      assert reason =~ "ProviderError"

      assert count_task_events(run.task_id, "TaskExecutionCompleted") == 0
      assert %{status: task_status} = ProjectionStore.task_projection(run.task_id)
      refute task_status == "closed"

      # Foreman stops: no retry of the close, and no release of a claim it still holds.
      assert_kata_calls(["claim", "close"])
    end

    test "RunExecutor.complete returns what Kata answered: a typed error, a close, or an explicit already-terminal success" do
      project = seed_kata_project!()
      ref = new_ref()
      run_id = unique_id("run")
      artifact = write_artifact!()

      KataScript.script(%{
        "close" => [
          runner_exit(3),
          close_reply(ref),
          ok(%{
            "kata_api_version" => 1,
            "changed" => false,
            "issue" => kata_issue(%{"status" => "closed"})
          })
        ]
      })

      # AC-012-4: refused, and typed.
      assert {:error, %ProviderError{code: "VALIDATION_FAILED", retryable?: false}} =
               RunExecutor.complete(project.project_id, ref, run_id, artifact)

      assert {:ok, :terminal} = RunExecutor.complete(project.project_id, ref, run_id, artifact)

      # AC-013-1: closing what is already closed is a success, not a failure.
      assert {:ok, :already_terminal} =
               RunExecutor.complete(project.project_id, ref, run_id, artifact)

      assert_kata_calls(["close", "close", "close"])
    end

    test "closing a task Kata already closed is a success: a second finalize completes, and the task is reported closed once" do
      run = new_run!([[agent: :dirty]])

      KataScript.script(%{
        "claim" => [claim_reply(run.ref)],
        "close" => [
          close_reply(run.ref),
          ok(%{
            "kata_api_version" => 1,
            "changed" => false,
            "issue" => kata_issue(%{"short_id" => run.ref, "status" => "closed"})
          })
        ]
      })

      start_executor!(run)

      assert %{status: "closed"} = await_task!(run.task_id, "closed")
      assert count_task_events(run.task_id, "TaskExecutionCompleted") == 1
      assert %{status: "completed"} = await_run!(run.run_id, "completed")

      # A resumed executor with every phase complete finalizes again. Kata answers the repeated close
      # `changed: false`, which is a success (AC-013-1), not a failed finalize.
      state = :sys.get_state(RunExecutor.pid_for(run.run_id))
      assert {:noreply, _finalized} = RunExecutor.__finish_phases_for_test__(state)

      assert_kata_calls(["claim", "close", "close"])

      assert [_claim, first, second] = KataScript.calls()
      assert first == second
      assert count_task_events(run.task_id, "TaskExecutionCompleted") == 1
    end

    test "the completion token carries commit_sha only when one is given, and never an empty one" do
      project_id = unique_id("token-project")
      cwd = tmp_dir!()

      stub =
        CapabilityStubProvider.define!(
          name: :kata_token_stub,
          capabilities: %{
            provider_id: :kata_token_stub,
            contract_version: "kata.capabilities.v1",
            supports: [:close],
            storage_scheme: :cli_process
          }
        )

      assert :ok = TaskProviderRegistry.register_for_project(project_id, stub, %{cwd: cwd})
      seed_project!(project_id, %{provider: "kata", config: %{"cwd" => cwd}}, cwd)
      run_id = unique_id("run")
      sha = String.duplicate("a1", 20)

      assert :ok = RunExecutor.complete(project_id, "t1", run_id, "/artifacts/a.md")
      assert_received {:complete, "t1", token, _project_config}
      # Exactly these keys: an absent sha is an absent key, not nil and not "".
      assert token == %{run_id: run_id, artifact_path: "/artifacts/a.md"}

      assert :ok = RunExecutor.complete(project_id, "t1", run_id, "/artifacts/a.md", sha)
      assert_received {:complete, "t1", token, _project_config}
      assert token == %{run_id: run_id, artifact_path: "/artifacts/a.md", commit_sha: sha}

      assert {:error, :invalid_completion} =
               RunExecutor.complete(project_id, "t1", run_id, "/artifacts/a.md", "")

      assert {:error, :invalid_completion} =
               RunExecutor.complete(project_id, "t1", run_id, "/artifacts/a.md", :not_a_sha)

      refute_received {:complete, _id, _token, _project_config}
    end
  end

  describe "fail (TRD-KATA-T035: AC-012-2, AC-014-1)" do
    test "a failed run is reopened, commented on and released, in that order, as the actor Kata reports; it is never closed" do
      run = new_run!([[agent: :fail]])
      script_failure!(run, status: ok(status(@kata_actor, @kata_actor)))
      start_executor!(run)

      assert %{failure_reason: reason} = await_task!(run.task_id, "failed")
      assert_kata_calls(["claim", "status", "reopen", "comment", "unassign"])

      assert [_claim, status, reopen, comment, unassign] = KataScript.calls()
      assert status == ["status", run.ref, "--json"]
      assert reopen == ["reopen", run.ref, "--json"]

      # The failure reason is the comment; the key moves with the body, so a retry replays it.
      assert ["comment", ref, "--body", body, "--idempotency-key", key, "--json"] = comment
      assert ref == run.ref
      assert body == reason
      assert key == failure_key(run.run_id, body)

      # `<actor>` comes from `$.actor` of `kata status`: never Foreman's own, never the owner's.
      assert unassign == ["unassign", run.ref, "--expect-owner", @kata_actor, "--json"]
      refute @foreman_actor in unassign
      assert count_task_events(run.task_id, "TaskExecutionCompleted") == 0
    end

    test "a task another actor owns is left untouched: only the status is read, and the refusal is not repeated" do
      run = new_run!([[agent: :fail]])
      script_failure!(run, status: ok(status(@kata_actor, "someone-else")))
      start_executor!(run)

      assert %{status: "failed"} = await_run!(run.run_id, "failed")

      # `CLAIMED_BY_OTHER` is not retryable, so `fail_retry_loop/5` classifies it permanent. A retry
      # would read the status again after a second; wait that out and see that none came.
      Process.sleep(@retry_window_ms)

      assert_kata_calls(["claim", "status"])
    end

    test "a task Kata shows already unowned is reopened and commented on, with nothing to release" do
      run = new_run!([[agent: :fail]])
      script_failure!(run, status: ok(status(@kata_actor, nil)))
      start_executor!(run)

      assert %{status: "failed"} = await_task!(run.task_id, "failed")
      assert_kata_calls(["claim", "status", "reopen", "comment"])
    end

    test "ownership changing between the status read and the release is a non-retryable CLAIMED_BY_OTHER that is not repeated" do
      run = new_run!([[agent: :fail]])

      script_failure!(run,
        status: ok(status(@kata_actor, @kata_actor)),
        unassign: runner_exit(5)
      )

      start_executor!(run)

      assert %{status: "failed"} = await_run!(run.run_id, "failed")
      Process.sleep(@retry_window_ms)

      assert_kata_calls(["claim", "status", "reopen", "comment", "unassign"])
    end

    test "RunExecutor.fail returns the typed, non-retryable CLAIMED_BY_OTHER of both refusals" do
      project = seed_kata_project!()
      ref = new_ref()
      run_id = unique_id("run")

      KataScript.script(%{
        "status" => [
          ok(status(@kata_actor, "someone-else")),
          ok(status(@kata_actor, @kata_actor))
        ],
        "reopen" => [ok(mutation(kata_issue(%{"short_id" => ref}), "issue.reopened", false))],
        "comment" => [ok(mutation(kata_issue(%{"short_id" => ref}), "issue.commented"))],
        "unassign" => [runner_exit(5)]
      })

      # Another actor owns the task: nothing is written.
      assert {:error, %ProviderError{code: "CLAIMED_BY_OTHER", retryable?: false}} =
               RunExecutor.fail(project.project_id, ref, run_id, %{reason: "boom"})

      assert_kata_calls(["status"])

      # Ownership changed after the read: the release is refused.
      assert {:error, %ProviderError{code: "CLAIMED_BY_OTHER", retryable?: false} = error} =
               RunExecutor.fail(project.project_id, ref, run_id, %{reason: "boom"})

      assert Enum.sort(Map.keys(error.context)) == Enum.sort(BuildProviderError.context_keys())
      assert_kata_calls(["status", "status", "reopen", "comment", "unassign"])
    end

    test "a retried fail after the comment succeeded replays the comment instead of adding a second one" do
      run = new_run!([[agent: :fail]])

      replay =
        ok(
          mutation(
            kata_issue(%{"short_id" => run.ref, "owner" => @kata_actor}),
            "issue.commented",
            false
          )
        )

      KataScript.script(%{
        "claim" => [claim_reply(run.ref)],
        "status" => [ok(status(@kata_actor, @kata_actor)), ok(status(@kata_actor, @kata_actor))],
        "reopen" => [reopen_reply(run.ref), reopen_reply(run.ref)],
        "comment" => [comment_reply(run.ref), replay],
        # The release times out the first time: retryable, so `fail_retry_loop/5` runs it again.
        "unassign" => [runner_timeout(), unassign_reply(run.ref)]
      })

      start_executor!(run)

      assert %{failure_reason: reason} = await_task!(run.task_id, "failed")

      assert_kata_calls([
        "claim",
        "status",
        "reopen",
        "comment",
        "unassign",
        "status",
        "reopen",
        "comment",
        "unassign"
      ])

      calls = KataScript.calls()
      [first_comment, second_comment] = Enum.filter(calls, &(hd(&1) == "comment"))

      # The same body under the same key: Kata answers the second as `changed: false`.
      assert first_comment == second_comment
      assert flag_values(first_comment, "--body") == [reason]
      assert flag_values(first_comment, "--idempotency-key") == [failure_key(run.run_id, reason)]
    end
  end

  # ---------------------------------------------------------------------------
  # Runs
  # ---------------------------------------------------------------------------

  # A project bound to a Kata workspace, a task linked to its Kata issue, and a run admitted for it,
  # seeded the way the server seeds one. `phases` is a list of `[agent: kind, commit: boolean]` where
  # `kind` is what the phase's agent does in its worktree: `:nothing`, `:dirty` (writes a file and
  # leaves it for Foreman to commit), `:agent_commit` (writes a file and commits it itself) or
  # `:fail`. The executor is started by `start_executor!/1`, after the test scripted `kata`.
  defp new_run!(phases) do
    test_pid = self()
    project_id = unique_id("project")
    task_id = unique_id("task")
    run_id = unique_id("run")
    ref = new_ref()
    repo = make_repo!()
    artifact_dir = Path.join(System.tmp_dir!(), unique_id("artifacts"))
    File.mkdir_p!(artifact_dir)

    specs =
      phases
      |> Enum.with_index(1)
      |> Enum.map(fn {opts, index} ->
        script_key = unique_id("script")

        LifecycleStore.put(
          script_key,
          agent_script(test_pid, index, Keyword.fetch!(opts, :agent))
        )

        phase_spec(index, script_key, artifact_dir, opts)
      end)

    on_exit(fn ->
      File.rm_rf(repo)
      File.rm_rf(artifact_dir)
      File.rm_rf(Path.join([System.user_home!(), ".foreman/worktrees", project_id]))
    end)

    register_kata_project!(project_id, repo)
    seed_task_and_run!(project_id, task_id, run_id, %{phases: specs}, ref, repo)

    %{
      project_id: project_id,
      task_id: task_id,
      run_id: run_id,
      ref: ref,
      repo: repo,
      branch: "foreman/#{ref}/#{run_id}",
      base: git!(repo, ["rev-parse", "HEAD"]),
      artifact_dir: artifact_dir
    }
  end

  defp phase_spec(index, script_key, artifact_dir, opts) do
    spec = %{
      name: "implement-#{index}",
      artifact_template: %{path: Path.join([artifact_dir, "{run_id}-implement-#{index}.md"])},
      context: %{"script_key" => script_key}
    }

    case Keyword.fetch(opts, :commit) do
      {:ok, commit} -> Map.put(spec, :commit, commit)
      :error -> spec
    end
  end

  defp agent_script(test_pid, _index, :nothing), do: %{test_pid: test_pid}

  defp agent_script(test_pid, _index, :fail),
    do: %{test_pid: test_pid, adapter_results: [{:error, :boom}]}

  defp agent_script(test_pid, index, :dirty) do
    %{
      test_pid: test_pid,
      after_execute: [
        fn worktree ->
          File.write!(Path.join(worktree, "phase-#{index}.txt"), "work of phase #{index}")
          :ok
        end
      ]
    }
  end

  defp agent_script(test_pid, index, :agent_commit) do
    %{
      test_pid: test_pid,
      after_execute: [
        fn worktree ->
          File.write!(Path.join(worktree, "agent-#{index}.txt"), "work of the agent in #{index}")
          git!(worktree, ["add", "-A"])
          git!(worktree, ["commit", "--no-gpg-sign", "--quiet", "-m", "agent work"])
          :ok
        end
      ]
    }
  end

  defp artifact_path(run, index),
    do: Path.join(run.artifact_dir, "#{run.run_id}-implement-#{index}.md")

  defp start_executor!(run) do
    task = ProjectionStore.task_projection(run.task_id)

    start_supervised!(%{
      id: {RunExecutor, run.run_id},
      start: {RunExecutor, :start_link, [run.run_id, task]},
      restart: :transient,
      shutdown: 5_000,
      type: :worker
    })
  end

  defp script_claim_and_close!(run) do
    KataScript.script(%{"claim" => [claim_reply(run.ref)], "close" => [close_reply(run.ref)]})
  end

  # The four calls of a failed run, in the order `KataAdapter.fail/3` makes them. Each verb may be
  # overridden by a runner result.
  defp script_failure!(run, overrides) do
    defaults = %{
      "claim" => [claim_reply(run.ref)],
      "status" => [ok(status(@kata_actor, @kata_actor))],
      "reopen" => [reopen_reply(run.ref)],
      "comment" => [comment_reply(run.ref)],
      "unassign" => [unassign_reply(run.ref)]
    }

    replies =
      Enum.reduce(overrides, defaults, fn {verb, reply}, acc ->
        Map.put(acc, Atom.to_string(verb), [reply])
      end)

    KataScript.script(replies)
  end

  defp assert_kata_calls(verbs) do
    assert KataScript.verbs() == verbs
    refute_received {:kata_unscripted, _argv}
  end

  # A project registered with the registry and the projection, with no run: for the calls
  # `RunExecutor` makes on its own.
  defp seed_kata_project! do
    project_id = unique_id("project")
    cwd = tmp_dir!()
    register_kata_project!(project_id, cwd)
    seed_project!(project_id, kata_task_provider(cwd), cwd)
    %{project_id: project_id, cwd: cwd}
  end

  defp tmp_dir! do
    dir = Path.join(System.tmp_dir!(), unique_id("kata-workspace"))
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp write_artifact! do
    path = Path.join(tmp_dir!(), "artifact.md")
    File.write!(path, "artifact body")
    path
  end

  # The config reaches the projection as JSON ingress sends it: the string key `"cwd"`.
  defp kata_task_provider(cwd), do: %{provider: "kata", config: %{"cwd" => cwd}}

  defp register_kata_project!(project_id, cwd) do
    assert :ok = TaskProviderRegistry.register_for_project(project_id, KataAdapter, %{cwd: cwd})
  end

  defp seed_task_and_run!(project_id, task_id, run_id, workflow_snapshot, ref, repo) do
    seed_project!(project_id, kata_task_provider(repo), repo)
    approval_id = unique_id("approval")

    dispatch_system!("task.create", "task:#{task_id}", %{
      task_id: task_id,
      project_id: project_id,
      task_type: "implement",
      title: "Kata lifecycle #{task_id}",
      external_id: ref
    })

    dispatch_system!("task.approve", "task:#{task_id}", %{
      task_id: task_id,
      approval_id: approval_id,
      approved_by: "kata-lifecycle-test",
      approved_at: "2026-11-19T00:00:00Z",
      run_id: run_id,
      workflow_snapshot: workflow_snapshot
    })

    dispatch_system!("task.dispatch", "task:#{task_id}", %{task_id: task_id})

    assert {:ok, result} =
             RunAdmission.start(project_id, %{
               run_id: run_id,
               task_id: task_id,
               project_id: project_id,
               approval_id: approval_id,
               workflow_snapshot: workflow_snapshot,
               phase_specs: Map.get(workflow_snapshot, :phases, [])
             })

    refute result in [:slot_queued, :queued, nil],
           "RunAdmission.start returned #{inspect(result)}: the seeded run did not start"
  end

  defp seed_project!(project_id, task_provider, path) do
    dispatch_system!("project.register", "project:#{project_id}", %{
      project_id: project_id,
      name: "Kata lifecycle #{project_id}",
      path: path,
      task_provider: task_provider
    })
  end

  defp dispatch_system!(type, aggregate_id, payload) do
    command_id = "#{type}:#{aggregate_id}:#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             CommandGateway.dispatch_system(%{
               command_id: command_id,
               aggregate_id: aggregate_id,
               type: type,
               payload: payload
             })
  end

  # ---------------------------------------------------------------------------
  # Kata's answers (shapes observed on `kata` v0.23.0)
  # ---------------------------------------------------------------------------

  defp ok(payload), do: {:ok, Jason.encode!(payload)}

  defp kata_issue(overrides) do
    Map.merge(
      %{
        "source_actor" => "alice",
        "verification" => "legacy",
        "id" => 3,
        "uid" => "01M7SJBGQSWGVAJKVM2F82ZQ27",
        "project_id" => 2,
        "project_uid" => "01M7SJAKPPH5JV4W15VR8J71VE",
        "short_id" => "zq27",
        "title" => "Third task",
        "body" => "third body",
        "status" => "open",
        "author" => "alice",
        "metadata" => %{},
        "revision" => 1,
        "created_at" => "2026-11-19T09:31:40.665Z",
        "updated_at" => "2026-11-19T09:31:40.665Z"
      },
      overrides
    )
  end

  defp ready_record(ref) do
    kata_issue(%{
      "short_id" => ref,
      "qualified_id" => "ws##{ref}",
      "web_url" => "http://127.0.0.1:65448/kata?issue=01M7SJBGQSWGVAJKVM2F82ZQ27#direct=1"
    })
  end

  defp mutation(issue, event_type, changed \\ true) do
    %{
      "kata_api_version" => 1,
      "changed" => changed,
      "issue" => issue,
      "event" => %{"type" => event_type, "actor" => @kata_actor}
    }
  end

  defp claim_reply(ref) do
    ok(mutation(kata_issue(%{"short_id" => ref, "owner" => @kata_actor}), "issue.assigned"))
  end

  defp close_reply(ref) do
    ok(mutation(kata_issue(%{"short_id" => ref, "status" => "closed"}), "issue.closed"))
  end

  defp reopen_reply(ref) do
    ok(
      mutation(kata_issue(%{"short_id" => ref, "owner" => @kata_actor}), "issue.reopened", false)
    )
  end

  defp comment_reply(ref) do
    ok(mutation(kata_issue(%{"short_id" => ref, "owner" => @kata_actor}), "issue.commented"))
  end

  defp unassign_reply(ref) do
    ok(mutation(kata_issue(%{"short_id" => ref}), "issue.unassigned"))
  end

  defp status(actor, owner) do
    base = %{
      "kata_api_version" => 1,
      "issue" => "j04d",
      "issue_status" => "open",
      "actor" => actor,
      "actor_source" => "user",
      "hold" => if(owner, do: "assigned", else: "unassigned")
    }

    if owner, do: Map.put(base, "owner", owner), else: base
  end

  # What `SystemKataRunner` returns for a non-zero exit: the adapter maps it by verb and status.
  defp runner_exit(exit_code) do
    {:error,
     BuildProviderError.build_provider_error(
       ProviderErrorInput.from_local(
         "BR_ERROR_ENVELOPE",
         "Kata CLI exited with a non-zero status.",
         nil,
         false
       ),
       exit_code,
       0
     )}
  end

  defp runner_timeout do
    {:error,
     BuildProviderError.build_provider_error(
       ProviderErrorInput.from_local(
         "BR_TIMEOUT_SUBPROCESS",
         "Kata command timed out while the subprocess was running.",
         "Retry the command after checking Kata responsiveness.",
         false
       ),
       nil,
       0
     )}
  end

  defp failure_key(run_id, body) do
    hash = :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    "foreman-fail:#{run_id}:#{hash}"
  end

  # The values that follow every occurrence of `flag` in an argv.
  defp flag_values(argv, flag) do
    for [^flag, value] <- Enum.chunk_every(argv, 2, 1, :discard), do: value
  end

  # ---------------------------------------------------------------------------
  # Waiting
  # ---------------------------------------------------------------------------

  defp await_run!(run_id, status) do
    poll_until(
      fn ->
        case ProjectionStore.run(run_id) do
          %{status: ^status} = run -> {:ok, run}
          other -> {:error, other}
        end
      end,
      "run #{status}"
    )
  end

  defp await_task!(task_id, status) do
    poll_until(
      fn ->
        case ProjectionStore.task_projection(task_id) do
          %{status: ^status} = task -> {:ok, task}
          other -> {:error, other}
        end
      end,
      "task #{status}"
    )
  end

  defp poll_until(fun, label) do
    deadline = System.monotonic_time(:millisecond) + @poll_timeout_ms
    do_poll(fun, deadline, label)
  end

  defp do_poll(fun, deadline, label) do
    case fun.() do
      {:ok, value} ->
        value

      other ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("timed out waiting for #{label} (last: #{inspect(other)})")
        else
          Process.sleep(25)
          do_poll(fun, deadline, label)
        end
    end
  end

  defp receive_message(timeout) do
    receive do
      message -> message
    after
      timeout -> flunk("expected a message within #{timeout}ms")
    end
  end

  defp count_task_events(task_id, event_type) do
    case EventStore.read_stream_forward("task:#{task_id}", 0, 99_999_999) do
      {:ok, events} -> Enum.count(events, &(&1.event_type == event_type))
      {:error, :stream_not_found} -> 0
    end
  end

  # ---------------------------------------------------------------------------
  # Git and ids
  # ---------------------------------------------------------------------------

  defp make_repo! do
    repo = Path.join(System.tmp_dir!(), unique_id("kata-lifecycle-repo"))
    File.rm_rf!(repo)
    File.mkdir_p!(repo)
    git!(repo, ["init", "--initial-branch=main", "--quiet"])
    git!(repo, ["config", "user.email", "t@x"])
    git!(repo, ["config", "user.name", "T"])
    File.write!(Path.join(repo, "README.md"), "x")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "--no-gpg-sign", "--quiet", "-m", "init"])
    repo
  end

  defp git!(repo, args) do
    {output, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
    String.trim(output)
  end

  defp unique_id(prefix) do
    "#{prefix}-kata-lifecycle-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
  end

  # A Kata short id: lowercase alphanumerics, which is all `KataAdapter` lets reach a command line.
  defp new_ref, do: "k" <> Integer.to_string(System.unique_integer([:positive]))

  # ---------------------------------------------------------------------------
  # Process and adapter fixtures
  # ---------------------------------------------------------------------------

  defp ensure_started(child_spec, name) do
    if Process.whereis(name) do
      :ok
    else
      start_supervised!(child_spec)
      :ok
    end
  end

  defp ensure_test_adapter_registered(previous_backend_adapter) do
    case previous_backend_adapter do
      TestAdapter ->
        :ok

      module when is_atom(module) and not is_nil(module) ->
        unregister_adapter(module)
        {:ok, _} = AgentRuntime.register_adapter(TestAdapter)
        :ok

      nil ->
        {:ok, _} = AgentRuntime.register_adapter(TestAdapter)
        :ok
    end
  end

  defp restore_backend_adapter(previous_backend_adapter) do
    case previous_backend_adapter do
      TestAdapter ->
        :ok

      module when is_atom(module) and not is_nil(module) ->
        unregister_adapter(TestAdapter)
        {:ok, _} = AgentRuntime.register_adapter(module)
        :ok

      nil ->
        unregister_adapter(TestAdapter)
        :ok
    end
  end

  defp unregister_adapter(module) do
    if Process.whereis(AdapterCatalog) do
      case AdapterCatalog.unregister(module) do
        :ok -> :ok
        {:error, :not_found} -> :ok
      end
    else
      :ok
    end
  end

  defp previous_backend_adapter do
    configured =
      Application.get_env(:foreman_server, :agent_runtime, [])
      |> Keyword.get(:adapters, [])
      |> Enum.find_value(fn
        adapter when is_atom(adapter) ->
          case AdapterCatalog.lookup(adapter.name()) do
            {:ok, module} -> module
            {:error, :not_found} -> nil
          end

        _ ->
          nil
      end)

    configured ||
      case AdapterCatalog.routing_snapshot() do
        [%{adapter: module} | _] -> module
        _ -> nil
      end
  end
end
