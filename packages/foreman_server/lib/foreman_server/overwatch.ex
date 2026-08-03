defmodule ForemanServer.Overwatch do
  @moduledoc """
  Top-level entrypoint for the worker runtime.

  ## High-level launch

    * `start_phase/2` — start a worker for the given phase/run context.
      Returns `{:ok, %{worker_id:, worker_pid:, launched_at:}}`. The
      worker is supervised, registered with `Tracker`, and a fully
      populated `WorkerStarted` event (with launch context) is appended
      through `CommandRouter`.

  ## Children

    * `ForemanServer.Overwatch.WorkerRegistry` — registry keyed by
      run_id/worker_id so LaunchWorker pids can be looked up.
    * `ForemanServer.Overwatch.Tracker` — liveness tracker and sole
      dispatcher of `WorkerHeartbeat`, `WorkerUnresponsive`, and
      `WorkerExited` events through `ForemanServer.CommandRouter`.
    * `ForemanServer.Overwatch.WorkerSupervisor` — `DynamicSupervisor`
      that hosts `ForemanServer.Overwatch.LaunchWorker` children with
      `restart: :permanent`, strategy `:one_for_one`.

  This is the TRD-011 implementation. It does NOT depend on TRD-012
  (WorkerCrashed); the implementation stays strictly localized to the
  liveness surface that TRD-011 requires.
  """

  use Supervisor

  alias ForemanServer.Overwatch.{Tracker, WorkerSupervisor}

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> Supervisor.start_link(__MODULE__, opts)
      name -> Supervisor.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    base = [
      {Registry, keys: :unique, name: ForemanServer.Overwatch.WorkerRegistry},
      Tracker,
      WorkerSupervisor
    ]

    children =
      case Keyword.get(opts, :crash_loop_detector_enabled, true) do
        true ->
          window_ms = Keyword.get(opts, :crash_loop_window_ms, 5 * 60 * 1000)
          threshold = Keyword.get(opts, :crash_loop_threshold, 3)

          base ++
            [
              {ForemanServer.Overwatch.CrashLoopDetector,
               [window_ms: window_ms, threshold: threshold]}
            ]

        _ ->
          base
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  # ------------------------------------------------------------------
  # High-level launch
  # ------------------------------------------------------------------

  @doc """
  Start a worker for the given phase/run context.

  ## Arguments

    * `phase` — opaque phase identifier (string; carries the phase id
      into `metadata`).
    * `opts` — keyword list of launch options:

      Required:
        * `:run_id` — run the worker belongs to.
        * `:worker_id` — explicit worker identifier; if absent a UUID
          is generated.
        * `:adapter` — module implementing `start_link/1` to spawn the
          actual worker process. REQUIRED (no production default).
        * `:session_id` — opaque session id for the worker runtime.
        * `:adapter_name` — string naming the adapter (used in
          `WorkerStarted.adapter`); defaults to `:adapter |> inspect()`.
        * `:prompt_path` — file path of the rendered prompt.

      Optional:
        * `:tool_names` — list of tool names exposed to the worker.
          Defaults to `[]`.
        * `:artifact_paths` — list of artifact paths the worker should
          write to. Defaults to `[]`.
        * `:activation_timeout_ms` — handshake timeout. Default 5_000.
        * `:metadata` — arbitrary map merged into the launch context
          (not currently appended to the event; reserved for future
          fields).

  ## Returns

  `{:ok, %{worker_id: String.t(), worker_pid: pid(), launch_pid: pid(),
  launched_at: integer()}}` on success.

  The `LaunchWorker` GenServer supervises the spawned runtime. It
  appends `WorkerStarted` through `CommandRouter` before activating the
  adapter, ensuring the adapter may call `WorkerProtocol.emit/2` only
  after the liveness surface is wired.
  """
  @spec start_phase(String.t() | map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def start_phase(phase, opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    worker_id = Keyword.get_lazy(opts, :worker_id, fn -> generate_worker_id() end)

    session_id = Keyword.fetch!(opts, :session_id)
    adapter = Keyword.fetch!(opts, :adapter)
    adapter_name = Keyword.get_lazy(opts, :adapter_name, fn -> inspect(adapter) end)
    prompt_path = Keyword.fetch!(opts, :prompt_path)

    launch_opts =
      [
        worker_id: worker_id,
        run_id: run_id,
        session_id: session_id,
        adapter: adapter,
        adapter_name: adapter_name,
        prompt_path: prompt_path,
        phase: phase
      ]
      |> Keyword.merge(Keyword.take(opts, [:tool_names, :artifact_paths, :activation_timeout_ms]))

    case WorkerSupervisor.start_worker(launch_opts) do
      {:ok, launch_pid} ->
        {:ok,
         %{
           worker_id: worker_id,
           worker_pid: launch_pid,
           launch_pid: launch_pid,
           launched_at: System.system_time(:millisecond),
           metadata: %{
             phase: phase,
             session_id: session_id,
             adapter: adapter_name,
             prompt_path: prompt_path
           }
         }}

      {:error, _reason} = err ->
        err

      other ->
        {:error, {:unexpected_start_child, other}}
    end
  end

  defp generate_worker_id do
    "wkr-" <>
      (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end