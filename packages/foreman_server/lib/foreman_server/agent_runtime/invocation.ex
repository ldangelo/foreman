defmodule ForemanServer.AgentRuntime.Invocation do
  @moduledoc """
  GenServer representing a single agent execution orchestration.

  Per TRD-008 line 131: "Invocation process ... Own ranked candidate list,
  attempts, timeout budget, fallback progression, result normalization, and
  telemetry metadata."

  Each invocation:
  1. Receives ranked candidates and policy from the facade
  2. Iterates through candidates, skipping unavailable ones (AC-004-2)
  3. Executes each available adapter with the timeout from policy
  4. On success: returns immediately with normalized result
  5. On error: decides based on policy.fallback (continue or return error)
  6. Normalizes the internal 4-tuple result to public 2-tuple format
  7. Sends `{:agent_runtime_invocation_complete, ref, result}` to caller
  8. Emits telemetry
  9. Returns `{:stop, :normal, state}` — never restarts

  Uses `restart: :temporary` so crashes are not retried.
  """

  use GenServer

  alias ForemanServer.Telemetry

  @type candidate :: {module(), boolean()}

  @type state :: %{
          candidates: [candidate()],
          policy: map(),
          request: map(),
          caller: pid(),
          ref: reference(),
          start_time: integer(),
          task_type: atom() | nil
        }

  # ------------------------------------------------------------------
  # Client API
  # ------------------------------------------------------------------

  @spec start_link({[candidate()], map(), map(), pid(), reference(), atom() | nil}) ::
          GenServer.on_start()
  def start_link({candidates, policy, request, caller, ref, task_type}) do
    GenServer.start_link(__MODULE__, {candidates, policy, request, caller, ref, task_type})
  end

  def child_spec({candidates, policy, request, caller, ref, task_type}) do
    %{
      id: __MODULE__,
      start:
        {__MODULE__, :start_link,
         [{candidates, policy, request, caller, ref, task_type}]},
      restart: :temporary
    }
  end

  # ------------------------------------------------------------------
  # Server Implementation
  # ------------------------------------------------------------------

  @impl true
  def init({candidates, policy, request, caller, ref, task_type}) do
    start_time = System.monotonic_time(:microsecond)

    state = %{
      candidates: candidates,
      policy: policy,
      request: request,
      caller: caller,
      ref: ref,
      start_time: start_time,
      task_type: task_type
    }

    {:ok, state, {:continue, :orchestrate}}
  end

  @impl true
  def handle_continue(
        :orchestrate,
        state = %{
          candidates: candidates,
          policy: policy,
          request: _request,
          caller: caller,
          ref: ref,
          start_time: start_time,
          task_type: task_type
        }
      ) do
    {final, attempts} = run_attempts(candidates, _request, policy)

    stop_time = System.monotonic_time(:microsecond)
    duration_us = stop_time - start_time

    {status, final_backend, attempted_backends, successful_backend} =
      completion_fields(final, attempts)

    Telemetry.agent_runtime_execute(
      %{duration_us: duration_us, attempt_count: length(attempts)},
      %{
        status: status,
        task_type: task_type,
        attempted_backends: attempted_backends,
        successful_backend: successful_backend,
        final_backend: final_backend
      }
    )
    send(caller, {:agent_runtime_invocation_complete, ref, final})

    {:stop, :normal, state}
  end

  # ------------------------------------------------------------------
  # Attempt loop
  #
  # `run_attempts/5` walks the candidate list and applies the resolved policy.
  # It returns `{public_result, attempts_in_execution_order}`.
  #
  # The terminal clause (empty candidates) is reached in two situations:
  #   1. Routing returned no available backends at all (attempts == []).
  #      Public result: {:error, :no_available_backend}.
  #   2. All remaining candidates were unavailable after some attempts failed;
  #      we skipped past them to the empty tail without recording them as
  #      attempts (AC-004-2). The accumulated prior failures MUST surface as
  #      {:error, :all_backends_failed, %{attempts: ...}} so callers do not
  #      silently lose earlier failures.
  # ------------------------------------------------------------------

  defp run_attempts(candidates, request, policy) do
    run_attempts(candidates, request, policy, [], 0)
  end

  defp run_attempts([], _request, _policy, attempts, _attempted) do
    case attempts do
      [] ->
        {{:error, :no_available_backend}, []}

      _ ->
        reversed = Enum.reverse(attempts)
        {{:error, :all_backends_failed, %{attempts: reversed}}, reversed}
    end
  end

  # Skip unavailable candidate without recording it (AC-004-2).
  defp run_attempts([{_adapter, false} | rest], request, policy, attempts, attempted) do
    run_attempts(rest, request, policy, attempts, attempted)
  end

  defp run_attempts([{adapter, true} | rest], request, policy, attempts, attempted) do
    next_num = attempted + 1

    if next_num > policy.max_attempts do
      case attempts do
        [] ->
          {{:error, :no_available_backend}, []}

        _ ->
          reversed = Enum.reverse(attempts)
          {{:error, :all_backends_failed, %{attempts: reversed}}, reversed}
      end
    else
      backend_name = adapter.name()

      case run_one(adapter, request, policy.timeout_ms) do
        {:ok, content, meta} ->
          attempt = {:ok, backend_name, content, meta}
          # Internal accumulator is newest-prepended; reverse to restore
          # execution order: prior failures first, successful backend last.
          ordered = Enum.reverse([attempt | attempts])
          {{:ok, content}, ordered}

        {:error, reason} ->
          attempt = {:error, backend_name, reason}
          new_attempts = [attempt | attempts]

          more_available? = has_available?(rest)

          cond do
            policy.fallback and more_available? ->
              # Fallback enabled with more available candidates: continue.
              run_attempts(rest, request, policy, new_attempts, next_num)

            policy.fallback ->
              # Fallback enabled, no more available candidates: every attempted
              # backend has failed. Surface as :all_backends_failed regardless
              # of how many attempts were recorded (AC 3 holds even for a
              # single allowed attempt, including mixed available/unavailable
              # where only one backend was actually tried).
              ordered = Enum.reverse(new_attempts)

              {{:error, :all_backends_failed, %{attempts: ordered}}, ordered}

            true ->
              # Fallback disabled: return the first (and only) attempt's direct
              # error (AC 2). No other backend is consulted.
              {{:error, reason}, Enum.reverse(new_attempts)}
          end
      end
    end
  end

  defp has_available?(candidates) do
    Enum.any?(candidates, fn {_adapter, available} -> available end)
  end

  # ------------------------------------------------------------------
  # Adapter call with crash isolation
  # ------------------------------------------------------------------

  defp run_one(adapter, request, timeout_ms) do
    try do
      case adapter.execute(request, timeout_ms: timeout_ms) do
        {:ok, content, metadata} ->
          {:ok, content, metadata}

        {:error, _reason} = err ->
          err
      end
    rescue
      exception ->
        {:error, {adapter, Exception.message(exception)}}
    catch
      kind, value ->
        reason =
          case kind do
            :throw -> {:thrown, value}
            :exit -> {:exited, value}
          end

        {:error, {adapter, reason}}
    end
  end

  # ------------------------------------------------------------------
  # Completion telemetry fields
  #
  # Derives the privacy-safe event payload from the final public result and
  # the attempts list. No request, output, or adapter metadata is touched.
  #
  # `attempts` arrives in execution order from `run_attempts/5` for every
  # branch (success and failure alike). This is the only contract callers
  # may rely on.
  # ------------------------------------------------------------------

  defp completion_fields({:ok, _content}, attempts) do
    # run_attempts guarantees attempts are in execution order: prior failures
    # first, successful backend last.
    attempted_backends = Enum.map(attempts, fn attempt -> attempt_backend(attempt) end)
    successful_backend = attempted_backends |> List.last()
    final_backend = successful_backend
    {:ok, final_backend, attempted_backends, successful_backend}
  end

  # Specific failure clauses must precede the catch-all so they are not
  # shadowed by `{:error, _reason}`.
  defp completion_fields({:error, :no_available_backend}, _attempts) do
    {:no_available_backend, nil, [], nil}
  end

  defp completion_fields({:error, :all_backends_failed, _meta}, attempts) do
    attempted_backends = Enum.map(attempts, fn attempt -> attempt_backend(attempt) end)
    final_backend = attempted_backends |> List.last()
    {:all_backends_failed, final_backend, attempted_backends, nil}
  end

  defp completion_fields({:error, _reason}, attempts) do
    attempted_backends = Enum.map(attempts, fn attempt -> attempt_backend(attempt) end)
    final_backend = attempted_backends |> List.last()
    {:direct_error, final_backend, attempted_backends, nil}
  end

  defp attempt_backend({:ok, backend_name, _content, _meta}), do: backend_name
  defp attempt_backend({:error, backend_name, _reason}), do: backend_name
end
