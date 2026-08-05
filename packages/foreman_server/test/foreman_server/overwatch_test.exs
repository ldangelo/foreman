defmodule ForemanServer.OverwatchTest do
  @moduledoc """
  TRD-011 / Overwatch top-level entrypoint tests.

  Pins the contract of `ForemanServer.Overwatch.start_phase/2`:

    * Returns `{:ok, %{worker_id, worker_pid, launched_at}}` plus launch
      metadata.
    * Spawns a supervised `LaunchWorker`, which:
      - spawns the adapter's worker pid,
      - registers it with `Tracker`,
      - appends a `WorkerStarted` event with the full launch context
        (codec-compliant: `session_id`, `adapter`, `prompt_path`),
      - sends the `{:overwatch_activate, ...}` handshake to the worker,
      - waits for the adapter to confirm activation.
    * After activation, `WorkerProtocol.emit(:heartbeat, ...)` returns
      `{:ok, seq}` and the worker stream contains a `WorkerHeartbeat`.

  The test adapter responds to the activation handshake by sending
  `{:overwatch_activated, ref}` straight back to the launcher, simulating
  a compliant `start_link/1` runtime.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.Overwatch
  alias ForemanServer.Overwatch.Tracker
  alias ForemanServer.Overwatch.WorkerProtocol

  defmodule FakeAdapter do
    @moduledoc """
    Test adapter that completes the activation handshake and then
    sleeps forever. Satisfies the contract that `start_link/1` returns
    a pid that has NOT yet emitted any `WorkerProtocol.emit/2` event —
    the pid only acknowledges activation on demand.
    """
    use GenServer

    def start_link(args) do
      worker_id = Keyword.fetch!(args, :worker_id)
      run_id = Keyword.fetch!(args, :run_id)
      name = :"fake-#{run_id}-#{worker_id}"
      capture_args(worker_id, run_id, args)
      GenServer.start_link(__MODULE__, args, name: name)
    end

    @impl true
    def init(args) do
      worker_id = Keyword.fetch!(args, :worker_id)
      run_id = Keyword.fetch!(args, :run_id)
      {:ok, %{worker_id: worker_id, run_id: run_id}}
    end

    @impl true
    def handle_info({:overwatch_activate, _worker_id, _run_id, launcher_pid}, state) do
      send(launcher_pid, {:overwatch_activated, self()})
      {:noreply, state}
    end

    def handle_info(_, state), do: {:noreply, state}

    defp capture_args(worker_id, run_id, args) do
      Agent.start_link(fn -> %{} end, name: :fake_adapter_capture)
      Agent.update(:fake_adapter_capture, &Map.put(&1, {run_id, worker_id}, args))
    end
  end

  defp captured_args(worker_id, run_id) do
    Agent.get(:fake_adapter_capture, &Map.get(&1, {run_id, worker_id}))
  end

  defp uuid, do: Elixir.EventStore.UUID.uuid4()

  defp start_overwatch do
    start_supervised!({Overwatch, []}, id: :overwatch)
  end

  defp read_worker_events(worker_id, run_id) do
    Store.read_stream_forward(Tracker.stream_id(worker_id, run_id), 0, 99_999_999)
    |> case do
      {:ok, events} -> events
      {:error, _} -> []
    end
  end

  defp count(events, type), do: Enum.count(events, &(&1.event_type == type))

  describe "start_phase/2" do
    test "returns {:ok, ...} with launch metadata, appends WorkerStarted, accepts heartbeat" do
      start_overwatch()
      run_id = uuid()
      session_id = uuid()
      worker_id = "wkr-test-#{:erlang.unique_integer([:positive])}"

      opts = [
        run_id: run_id,
        worker_id: worker_id,
        adapter: FakeAdapter,
        session_id: session_id,
        prompt_path: "/tmp/prompt-#{run_id}.md",
        tool_names: ["read", "write"],
        artifact_paths: ["/tmp/artifacts/#{run_id}"]
      ]

      assert {:ok, launch} = Overwatch.start_phase("phase-#{run_id}", opts)

      assert launch.worker_id == worker_id
      assert launch.launch_pid == launch.worker_pid
      assert is_integer(launch.launched_at)

      worker_pid = launch.worker_pid
      metadata = launch.metadata

      assert metadata.session_id == session_id
      assert metadata.adapter =~ "FakeAdapter"
      assert metadata.prompt_path == "/tmp/prompt-#{run_id}.md"
      assert metadata.phase == "phase-#{run_id}"

      # WorkerStarted must be persisted with the full launch context —
      # this proves the codec-validation gate accepts a clean payload.
      events = read_worker_events(worker_id, run_id)
      assert count(events, "WorkerStarted") == 1
      [started | _] = events

      assert started.data["worker_id"] == worker_id
      assert started.data["run_id"] == run_id
      assert started.data["session_id"] == session_id
      assert started.data["adapter"] =~ "FakeAdapter"
      assert started.data["prompt_path"] == "/tmp/prompt-#{run_id}.md"
      assert started.data["tool_names"] == ["read", "write"]
      assert started.data["artifact_paths"] == ["/tmp/artifacts/#{run_id}"]
      assert started.data["sequence"] == 0

      # Worker is registered with Tracker (registers the spawned adapter pid).
      adapter_pid = Tracker.pid_for(worker_id, run_id)
      assert is_pid(adapter_pid)
      assert Process.alive?(adapter_pid)
      assert adapter_pid != worker_pid

      assert {:ok, 1} =
               WorkerProtocol.emit(:heartbeat, %{worker_id: worker_id, run_id: run_id})

      events = read_worker_events(worker_id, run_id)
      assert count(events, "WorkerHeartbeat") == 1
    end

    test "rejects a launch with missing required opts" do
      start_overwatch()

      # Missing :session_id
      assert_raise KeyError, fn ->
        Overwatch.start_phase("phase", run_id: uuid(), adapter: FakeAdapter, prompt_path: "/p")
      end
    end

    test "threads the project's env map into the adapter's start_link args" do
      alias ForemanServer.{CommandRouter, WorkerEnvironment}

      start_overwatch()
      project_id = "project-env-thread-#{uuid()}"
      run_id = uuid()
      worker_id = "wkr-env-thread-#{:erlang.unique_integer([:positive])}"
      env_map = %{"API_KEY" => "secret-1", "REGION" => "us-east-1"}

      {:ok, _} =
        CommandRouter.dispatch(%{
          type: "project.register",
          payload: %{
            project_id: project_id,
            path: "/tmp/#{project_id}",
            config: %{env: env_map}
          },
          aggregate_id: "project:#{project_id}"
        })

      assert {:ok, launch} =
               Overwatch.start_phase("phase-#{run_id}",
                 run_id: run_id,
                 worker_id: worker_id,
                 adapter: FakeAdapter,
                 session_id: uuid(),
                 prompt_path: "/tmp/prompt-#{run_id}.md",
                 project_id: project_id
               )

      adapter_args = captured_args(worker_id, run_id)
      assert is_list(adapter_args)
      assert Keyword.get(adapter_args, :env_map) == env_map
      assert Keyword.get(adapter_args, :project_id) == project_id
      assert launch.metadata.env_map == env_map
      assert launch.metadata.project_id == project_id
    end

    test "config changes take effect only on a fresh worker launch (AC-003-2)" do
      alias ForemanServer.CommandRouter

      start_overwatch()
      project_id = "project-env-relaunch-#{uuid()}"
      run_id = uuid()
      first_worker_id = "wkr-env-relaunch-first-#{:erlang.unique_integer([:positive])}"
      second_worker_id = "wkr-env-relaunch-second-#{:erlang.unique_integer([:positive])}"
      initial_env = %{"TOKEN" => "old"}
      updated_env = %{"TOKEN" => "new", "EXTRA" => "x"}

      {:ok, _} =
        CommandRouter.dispatch(%{
          type: "project.register",
          payload: %{
            project_id: project_id,
            path: "/tmp/#{project_id}",
            config: %{env: initial_env}
          },
          aggregate_id: "project:#{project_id}"
        })

      assert {:ok, first_launch} =
               Overwatch.start_phase("phase-#{run_id}",
                 run_id: run_id,
                 worker_id: first_worker_id,
                 adapter: FakeAdapter,
                 prompt_path: "/tmp/prompt-#{run_id}.md",
                 session_id: uuid(),
                 project_id: project_id
               )

      first_args = captured_args(first_worker_id, run_id)
      assert Keyword.get(first_args, :env_map) == initial_env

      {:ok, _} =
        CommandRouter.dispatch(%{
          type: "project.update",
          payload: %{project_id: project_id, config: %{env: updated_env}},
          aggregate_id: "project:#{project_id}"
        })

      assert first_launch.metadata.env_map == initial_env

      assert {:ok, _second_launch} =
               Overwatch.start_phase("phase-#{run_id}-2",
                 run_id: run_id,
                 worker_id: second_worker_id,
                 adapter: FakeAdapter,
                 session_id: uuid(),
                 prompt_path: "/tmp/prompt-#{run_id}.md",
                 project_id: project_id
               )

      second_args = captured_args(second_worker_id, run_id)
      assert Keyword.get(second_args, :env_map) == updated_env
    end
  end
end
