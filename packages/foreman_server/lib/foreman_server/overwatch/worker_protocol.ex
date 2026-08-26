defmodule ForemanServer.Overwatch.WorkerProtocol do
  @moduledoc """
  Production boundary for the worker runtime. Real workers — and
  `ForemanServer.Overwatch.LaunchWorker` — call `emit/2` to publish
  lifecycle events. The protocol is the only API workers should call.

  ## Routing

    * `:heartbeat` → `Tracker.heartbeat/3` (sole producer of
      `WorkerHeartbeat`; resets liveness timer).
    * `:worker_started`, `:worker_exited`, `:tool_call_finished`,
      `:assistant_message`, `:worker_stdout`, `:worker_stderr`
      → `Tracker.dispatch_lifecycle/3` (atomically allocates the next
      sequence, dispatches via `CommandRouter`, advances the mirror
      on success).
    * `:worker_unresponsive` is NOT emitted by workers; Tracker
      emits this on timeout.

  ## Sequence atomicity

  `Tracker` is the sole owner of sequence allocation. No external code
  reads the current sequence, computes a candidate, and dispatches.
  `emit/2` calls into Tracker, which atomically allocates, dispatches,
  and advances only on success. Two consecutive `emit/2` calls always
  yield distinct sequences or one is rejected.

  ## Launcher

  `start_worker/3` spawns the actual worker runtime via an adapter
  module. **No default adapter is provided** — production callers MUST
  supply `:adapter` opt pointing at the real worker runtime. A test
  adapter may be configured under `test/support` for acceptance tests;
  it is never the production default.

  Adapter contract: `start_link/1` returning `{:ok, pid}` or
  `{:error, reason}`. The adapter receives `worker_id:`, `run_id:`,
  and any additional opts forwarded.
  """

  alias ForemanServer.Overwatch.Tracker

  # ------------------------------------------------------------------
  # Launcher
  # ------------------------------------------------------------------

  @doc """
  Start a worker runtime. Returns `{:ok, pid}` on success.

  Requires `:adapter` opt naming a module that exports `start_link/1`.
  `start_worker/3` does NOT provide a default adapter — production
  callers must configure the real worker runtime; tests must configure
  a test adapter. Calling without `:adapter` returns
  `{:error, :adapter_required}` so the misconfiguration is loud.
  """
  @spec start_worker(String.t(), String.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_worker(worker_id, run_id, opts \\ []) do
    case Keyword.fetch(opts, :adapter) do
      {:ok, adapter} ->
        base_opts = [worker_id: worker_id, run_id: run_id]

        try do
          adapter.start_link(base_opts ++ opts)
        rescue
          exception -> {:error, {:adapter_raised, Exception.message(exception)}}
        catch
          kind, reason -> {:error, {:adapter_exit, kind, reason}}
        end

      :error ->
        {:error, :adapter_required}
    end
  end

  # ------------------------------------------------------------------
  # Emit boundary
  # ------------------------------------------------------------------

  @doc """
  Emit a worker lifecycle event. `type` is one of the atoms below.

  Required payload keys per type:

    * `:heartbeat` — `:worker_id`, `:run_id`
    * `:worker_started` — `:worker_id`, `:run_id`, `:session_id`,
      `:adapter`, `:prompt_path` (optional `:tool_names`,
      `:artifact_paths`; default `[]`)
    * `:worker_exited`, `:tool_call_finished`, `:assistant_message`,
      `:worker_stdout`, `:worker_stderr` — `:worker_id`, `:run_id`,
      plus type-specific fields

  The high-level entry point `ForemanServer.Overwatch.start_phase/2`
  supplies the launch-context payload for `:worker_started` from its
  opts.
  """
  @spec emit(
          :heartbeat
          | :worker_started
          | :worker_exited
          | :tool_call_finished
          | :assistant_message
          | :worker_stdout
          | :worker_stderr,
          map()
        ) ::
          {:ok, non_neg_integer()} | :ok | {:error, term()}
  def emit(:heartbeat, %{worker_id: worker_id, run_id: run_id}) do
    Tracker.heartbeat(worker_id, run_id)
  end

  def emit(:worker_started, payload) do
    Tracker.dispatch_lifecycle("WorkerStarted", payload)
  end

  def emit(:worker_exited, payload) do
    Tracker.dispatch_lifecycle("WorkerExited", payload)
  end

  def emit(:tool_call_finished, payload) do
    Tracker.dispatch_lifecycle("ToolCallFinished", payload)
  end

  def emit(:assistant_message, payload) do
    Tracker.dispatch_lifecycle("AssistantMessage", payload)
  end

  def emit(:worker_stdout, payload) do
    Tracker.dispatch_lifecycle("WorkerStdout", payload)
  end

  def emit(:worker_stderr, payload) do
    Tracker.dispatch_lifecycle("WorkerStderr", payload)
  end
end
