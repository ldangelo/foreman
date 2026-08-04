defmodule ForemanServer.AgentRuntime.Invocation do
  @moduledoc """
  GenServer representing a single agent invocation.

  Each invocation:
  1. Executes the backend adapter synchronously via handle_continue
  2. Normalizes the result to the facade's `attempt_result` type
  3. Sends `{:agent_runtime_invocation_complete, ref, result}` to the caller
  4. Emits telemetry
  5. Returns `{:stop, :normal, state}` — never restarts

  Uses `restart: :temporary` so crashes are not retried.
  """

  use GenServer

  alias ForemanServer.Telemetry

  @type state :: %{
          adapter: module(),
          request: map(),
          caller: pid(),
          ref: reference(),
          start_time: integer()
        }

  # ------------------------------------------------------------------
  # Client API
  # ------------------------------------------------------------------

  @spec start_link({module(), map(), pid(), reference()}) :: GenServer.on_start()
  def start_link({adapter_module, request, caller, ref}) do
    GenServer.start_link(__MODULE__, {adapter_module, request, caller, ref})
  end

  def child_spec({adapter_module, request, caller, ref}) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [{adapter_module, request, caller, ref}]},
      restart: :temporary
    }
  end

  # ------------------------------------------------------------------
  # Server Implementation
  # ------------------------------------------------------------------

  @impl true
  def init({adapter_module, request, caller, ref}) do
    start_time = System.monotonic_time(:microsecond)

    state = %{
      adapter: adapter_module,
      request: request,
      caller: caller,
      ref: ref,
      start_time: start_time
    }

    # Continue to execute the adapter
    {:ok, state, {:continue, :execute}}
  end

  @impl true
  def handle_continue(:execute, state = %{adapter: adapter_module, caller: caller, ref: ref, start_time: start_time, request: request}) do
    # Get backend name safely - only call after we know adapter is valid
    backend_name = adapter_module.name()

    # Emit start telemetry
    Telemetry.execute(
      [:foreman, :agent_runtime, :invocation, :start],
      %{system_time: System.system_time()},
      %{backend: backend_name}
    )

    result = execute_adapter(adapter_module, request)

    # Calculate duration
    stop_time = System.monotonic_time(:microsecond)
    duration_us = stop_time - start_time

    # Determine status for telemetry
    status = case result do
      {:ok, _, _, _} -> :ok
      {:error, _} -> :error
    end

    # Emit stop telemetry (no prompt content per REQ-006)
    Telemetry.execute(
      [:foreman, :agent_runtime, :invocation, :stop],
      %{duration_us: duration_us, status: status},
      %{backend: backend_name}
    )

    # Send result to caller
    send(caller, {:agent_runtime_invocation_complete, ref, result})

    # Stop normally — do not restart
    {:stop, :normal, state}
  end

  # Execute adapter with proper error handling
  defp execute_adapter(adapter_module, request) do
    try do
      case adapter_module.execute(request, []) do
        {:ok, content, metadata} ->
          # Success - add backend name to result
          {:ok, adapter_module.name(), content, metadata}

        {:error, _reason} = error_tuple ->
          # Adapter returned error - preserve the exact tuple unchanged
          error_tuple
      end
    rescue
      exception ->
        # Crashed during execution - format as {module, reason}
        {:error, {adapter_module, Exception.message(exception)}}
    catch
      kind, value ->
        # Caught throw or exit
        reason = case kind do
          :throw -> {:thrown, value}
          :exit -> {:exited, value}
        end
        {:error, {adapter_module, reason}}
    end
  end
end
