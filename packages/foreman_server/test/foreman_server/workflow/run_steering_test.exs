defmodule ForemanServer.Workflow.RunSteeringTest do
  @moduledoc """
  E6-S4 operator steering, end to end through the wired Dispatcher.

  This is the executable evidence for spike E6-SP1: `run.steer` pauses the
  run (reason `steer`), the Dispatcher auto-resumes it, and the rebuilt
  phase prompt carries the operator text exactly once. `RunControl` is wiped
  between pause and resume (as `RunExecutor.terminate/2` and
  `Dispatcher.handle_run_resumed/3` do), so the injection can only come from
  the durable projection.

  No sleeps: every wait is a `{:projection_event, _}` receive on this
  process's own `ProjectionStore` subscription.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.{CommandGateway, CommandRouter, ProjectionStore, RunAdmission, RunControl}
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.TestSupport.RunSlotsReset
  alias ForemanServer.Workflow.{Dispatcher, RunExecutor}

  @heading "## Operator message(s) received while you were paused"

  setup_all do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = Application.ensure_all_started(:eventstore)

    ensure_started({Phoenix.PubSub, name: ForemanServer.PubSub}, ForemanServer.PubSub)
    ensure_started(ForemanServerWeb.Presence, ForemanServerWeb.Presence)
    ensure_started(ForemanServer.EventStore, ForemanServer.EventStore)
    ensure_started(ForemanServer.ProjectionStore, ForemanServer.ProjectionStore)
    ensure_started(ForemanServer.Aggregator, ForemanServer.Aggregator)
    ensure_started(ForemanServer.CommandRouter, ForemanServer.CommandRouter)
    ensure_started(ForemanServer.TaskProvider.Registry, ForemanServer.TaskProvider.Registry)

    ensure_started(
      {Registry, keys: :unique, name: ForemanServer.RunExecutorRegistry},
      ForemanServer.RunExecutorRegistry
    )

    ensure_started(
      ForemanServer.AgentRuntime.AdapterCatalog,
      ForemanServer.AgentRuntime.AdapterCatalog
    )

    ensure_started(ForemanServer.Workflow.Catalog, ForemanServer.Workflow.Catalog)
    ensure_started(ForemanServer.Workflow.RunSupervisor, ForemanServer.Workflow.RunSupervisor)
    ensure_started(ForemanServer.RunControl, ForemanServer.RunControl)
    ensure_started(ForemanServer.Workflow.Dispatcher, ForemanServer.Workflow.Dispatcher)
    :ok
  end

  setup do
    RunSlotsReset.reset!()
    ensure_dispatcher_subscribed()
    :ok = ProjectionStore.subscribe()

    run_id = "run-steer-#{Elixir.EventStore.UUID.uuid4()}"
    project_id = "project-#{run_id}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        aggregate_id: "project:#{project_id}",
        command_id: "register:#{project_id}",
        type: "project.register",
        payload: %{project_id: project_id, name: "steer #{run_id}", path: System.tmp_dir!()}
      })

    {:ok, _} =
      RunAdmission.start(project_id, %{
        run_id: run_id,
        task_id: "task-#{run_id}",
        project_id: project_id,
        workflow_snapshot: %{}
      })

    on_exit(fn -> RunControl.clear(run_id) end)
    {:ok, run_id: run_id, project_id: project_id}
  end

  test "steering a running run pauses with reason steer, resumes, and injects the text exactly once",
       %{run_id: run_id, project_id: project_id} do
    steer!(run_id, "m1", "please use tabs, not spaces")

    assert_event("RunSteerQueued", run_id)
    assert_event("RunPaused", run_id)
    assert_event("RunResumed", run_id)

    assert ["RunStarted", "RunSteerQueued", "RunPaused", "RunResumed"] = event_types(run_id)
    assert [%{reason: "steer"}] = paused_payloads(run_id)

    # Pause/resume wiped RunControl; the durable queue is the projection.
    RunControl.clear(run_id)
    assert RunControl.peek_messages(run_id) == []

    assert [%{message_id: "m1", text: "please use tabs, not spaces"}] =
             ProjectionStore.pending_steering(run_id)

    first = launch_prompt(run_id, project_id)
    assert occurrences(first, "please use tabs, not spaces") == 1
    assert occurrences(first, @heading) == 1

    assert_event("RunSteerConsumed", run_id)
    assert ProjectionStore.pending_steering(run_id) == []
    assert List.last(event_types(run_id)) == "RunSteerConsumed"

    # A further pause/resume (any later phase prompt) must not repeat it.
    second = launch_prompt(run_id, project_id)
    refute second =~ "please use tabs"
    refute second =~ @heading
  end

  test "resume: false leaves the run paused until an operator resumes; text is injected then",
       %{run_id: run_id, project_id: project_id} do
    steer!(run_id, "m1", "hold on", %{resume: false})

    assert_event("RunPaused", run_id)
    refute_event("RunResumed", run_id)
    assert ProjectionStore.run(run_id).status == "paused"
    assert [%{text: "hold on", resume: false}] = ProjectionStore.pending_steering(run_id)

    {:ok, _} =
      CommandGateway.dispatch_operator(%{
        type: "run.resume",
        command_id: "operator-resume-#{run_id}",
        aggregate_id: "run:#{run_id}",
        payload: %{run_id: run_id}
      })

    assert_event("RunResumed", run_id)
    assert launch_prompt(run_id, project_id) =~ "hold on"
  end

  test "a pause nobody steered is never auto-resumed, even with reason steer",
       %{run_id: run_id} do
    {:ok, _} =
      CommandGateway.dispatch_operator(%{
        type: "run.pause",
        command_id: "operator-pause-#{run_id}",
        aggregate_id: "run:#{run_id}",
        payload: %{run_id: run_id, reason: "operator"}
      })

    assert_event("RunPaused", run_id)
    refute_event("RunResumed", run_id)

    # Even a pause that merely carries reason "steer" resumes nothing when
    # no steering is pending.
    {:ok, _} =
      CommandGateway.dispatch_operator(%{
        type: "run.pause",
        command_id: "operator-pause-steer-#{run_id}",
        aggregate_id: "run:#{run_id}",
        payload: %{run_id: run_id, reason: "steer"}
      })

    assert_event("RunPaused", run_id)
    refute_event("RunResumed", run_id)
    assert ProjectionStore.run(run_id).status == "paused"
  end

  test "steering an operator-paused run only queues the message (no resume)",
       %{run_id: run_id} do
    {:ok, _} =
      CommandGateway.dispatch_operator(%{
        type: "run.pause",
        command_id: "operator-pause2-#{run_id}",
        aggregate_id: "run:#{run_id}",
        payload: %{run_id: run_id, reason: "operator"}
      })

    assert_event("RunPaused", run_id)
    steer!(run_id, "m1", "queued while paused")
    assert_event("RunSteerQueued", run_id)
    refute_event("RunResumed", run_id)
    assert [%{message_id: "m1"}] = ProjectionStore.pending_steering(run_id)
  end

  test "the mailbox cache is rebuilt from the projection for non-terminal runs",
       %{run_id: run_id} do
    steer!(run_id, "m1", "survives restart", %{resume: false})
    assert_event("RunPaused", run_id)

    # What a server restart does to the ETS cache.
    RunControl.clear(run_id)
    assert RunControl.peek_messages(run_id) == []

    assert :ok = Dispatcher.rebuild_steering_mailbox()
    assert [%{message_id: "m1", text: "survives restart"}] = RunControl.peek_messages(run_id)
  end

  # E8 resume-with-override: an approval's one-phase `approval_mode`.
  test "an approval override applies to the launch that consumes the message and to no later one",
       %{run_id: run_id, project_id: project_id} do
    steer!(run_id, "approval:c1", "approved Write", %{
      resume: false,
      approval_mode_override: "auto_edit"
    })

    assert_event("RunPaused", run_id)
    RunControl.clear(run_id)

    assert [%{message_id: "approval:c1", approval_mode_override: "auto_edit"}] =
             ProjectionStore.pending_steering(run_id)

    first = launch(run_id, project_id)
    assert Keyword.fetch!(first.driver_opts.(60_000), :approval_mode) == :auto_edit

    assert_event("RunSteerConsumed", run_id)
    second = launch(run_id, project_id)
    refute Keyword.has_key?(second.driver_opts.(60_000), :approval_mode)
  end

  test "a command phase applies and consumes an approval override without injecting any text",
       %{run_id: run_id, project_id: project_id} do
    steer!(run_id, "approval:c2", "approved Bash", %{
      resume: false,
      approval_mode_override: "auto_approve"
    })

    steer!(run_id, "plain", "just text", %{resume: false})
    assert_event("RunPaused", run_id)
    RunControl.clear(run_id)

    launch = launch(run_id, project_id, %{name: "cmd", action: :command, command: "echo hi"})
    assert Keyword.fetch!(launch.driver_opts.(60_000), :approval_mode) == :auto_approve
    refute launch.phase.prompt =~ "approved Bash"
    refute launch.phase.prompt =~ @heading

    assert_event("RunSteerConsumed", run_id)
    # only the override message was consumed; the text-only one still waits for a prompt phase
    assert [%{message_id: "plain"}] = ProjectionStore.pending_steering(run_id)
  end

  test "an unknown override name is rejected, never queued", %{run_id: run_id} do
    assert {:error, {:invalid_approval_mode_override, "yolo"}} =
             CommandGateway.dispatch_operator(%{
               type: "run.steer",
               command_id: "steer-bad-#{run_id}",
               aggregate_id: "run:#{run_id}",
               payload: %{
                 run_id: run_id,
                 message_id: "m",
                 text: "x",
                 approval_mode_override: "yolo"
               }
             })

    assert ProjectionStore.pending_steering(run_id) == []
  end

  # -- helpers ---------------------------------------------------------------

  defp steer!(run_id, message_id, text, extra \\ %{}) do
    {:ok, _} =
      CommandGateway.dispatch_operator(%{
        type: "run.steer",
        command_id: "steer-#{run_id}-#{message_id}",
        aggregate_id: "run:#{run_id}",
        payload: Map.merge(%{run_id: run_id, message_id: message_id, text: text}, extra)
      })
  end

  defp launch_prompt(run_id, project_id) do
    %{phase: %{prompt: prompt}} = launch(run_id, project_id)
    prompt
  end

  # Builds the phase launch exactly as a (re)started executor would.
  defp launch(run_id, project_id, phase_spec \\ %{name: "code-generation"}) do
    projection = %{
      task_id: "task-#{run_id}",
      project_id: project_id,
      working_directory: System.tmp_dir!(),
      workflow_type: "implement",
      workflow_snapshot: %{
        "workflow_name" => "implement",
        "workflow_digest" => "digest-steer",
        "worktree" => %{"enabled" => false},
        "phases" => [%{"name" => "code-generation"}]
      }
    }

    {:ok, state} = RunExecutor.init({run_id, projection, []})

    assert {:ok, %{phase: %{prompt: prompt}, launch_opts: opts} = launch} =
             RunExecutor.phase_launch(state, phase_spec, 0, nil)

    if Map.get(phase_spec, :action) != :command,
      do: assert(Keyword.fetch!(opts, :prompt) == prompt)

    launch
  end

  defp occurrences(haystack, needle),
    do: haystack |> String.split(needle) |> length() |> Kernel.-(1)

  defp stream_events(run_id) do
    {:ok, events} = Store.read_stream_forward("run:#{run_id}", 0, 1_000)
    events
  end

  defp event_types(run_id), do: Enum.map(stream_events(run_id), & &1.event_type)

  defp paused_payloads(run_id) do
    for %{event_type: "RunPaused", data: data} <- stream_events(run_id),
        do: %{reason: Map.get(data, :reason) || Map.get(data, "reason")}
  end

  defp assert_event(type, run_id) do
    receive do
      {:projection_event, event} ->
        if event_matches?(event, type, run_id), do: :ok, else: assert_event(type, run_id)
    after
      5_000 -> flunk("timed out waiting for #{type} on #{run_id}")
    end
  end

  defp refute_event(type, run_id) do
    receive do
      {:projection_event, event} ->
        if event_matches?(event, type, run_id),
          do: flunk("unexpected #{type} for #{run_id}"),
          else: refute_event(type, run_id)
    after
      300 -> :ok
    end
  end

  defp event_matches?(event, type, run_id) do
    ev_type = Map.get(event, :event_type) || Map.get(event, "event_type")
    data = Map.get(event, :data) || Map.get(event, "data") || Map.get(event, :payload) || %{}
    ev_run = Map.get(data, :run_id) || Map.get(data, "run_id")
    ev_type == type and ev_run == run_id
  end

  defp ensure_started(child_spec, name) do
    case Process.whereis(name) do
      nil -> start_supervised!(child_spec)
      _pid -> :ok
    end
  end

  defp ensure_dispatcher_subscribed do
    case Process.whereis(ForemanServer.Workflow.Dispatcher) do
      pid when is_pid(pid) ->
        :sys.replace_state(ForemanServer.ProjectionStore, fn state ->
          %{state | subscribers: Map.put(state.subscribers, pid, true)}
        end)

      nil ->
        flunk("ForemanServer.Workflow.Dispatcher is not running")
    end
  end
end
