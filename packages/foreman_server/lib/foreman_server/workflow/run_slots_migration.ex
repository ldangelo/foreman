defmodule ForemanServer.Workflow.RunSlotsMigration do
  @moduledoc """
  One-shot, idempotent carry-over of the legacy `run_slots:global` stream into the
  per-project `run_slots:<project_id>` streams (TRD-009, REQ-009).

  `BootReconciliation` calls `run/0` after it scanned the project streams; the
  legacy stream is no longer swept, so this is the only reader it has left. It
  reads it with `Aggregate.load/2` (no actor, no append) and never dispatches to
  it: the stream stays on disk for replay, byte for byte.

    * **Holders** (run live) are adopted by their run's project with
      `run_slots.acquire` `force: true`, command id `run-slots:adopt:<run_id>`. They
      count against the project's limit even when that exceeds the limit: nothing
      running is ever stopped, new runs simply wait.
    * **Waiters** (run live or queued) are queued in the order the legacy stream
      holds them, `enqueue_only: true`, command id `run-slots:migrate-waiter:<run_id>`;
      then `run_slots.promote` fills free capacity of every project touched, which
      starts the run through the normal promotion path (`Workflow.Dispatcher`).
    * Whether an entry is live is `BootReconciliation.slot_entry_orphan?/1`, the one
      predicate (TRD-018): a queued run has no run projection yet, so a run with an
      `in_progress` task is carried over, not dropped. Orphans are skipped, as the
      old backstop would have released them.

  A run's project is read from its run projection, else its task (the legacy events
  carry no `project_id`); a run with neither is warned about and skipped, never
  guessed onto a stream. Deterministic command ids make a second pass a no-op, also
  for a run whose slot was since released (a paused run) -- it is not re-adopted.
  """

  require Logger

  alias ForemanServer.{Aggregate, CommandGateway, ProjectionStore, RunAdmission}
  alias ForemanServer.Aggregates.RunSlots
  alias ForemanServer.Workflow.BootReconciliation

  @legacy_stream "run_slots:global"

  @type summary :: %{
          adopted: non_neg_integer(),
          queued: non_neg_integer(),
          promoted: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer()
        }

  @doc "Carries the legacy global slot stream over to the project streams."
  @spec run() :: {:ok, summary()} | {:error, term()}
  def run do
    {legacy, _version} = Aggregate.load(RunSlots, @legacy_stream)

    holders =
      legacy.holders
      |> Enum.sort_by(fn {run_id, holder} -> {holder_acquired_at(holder), run_id} end)
      |> Enum.map(&elem(&1, 0))

    waiters = Enum.map(legacy.waiters, & &1.run_id)

    if holders == [] and waiters == [] do
      {:ok, summary()}
    else
      {:ok, migrate(holders, waiters)}
    end
  catch
    kind, reason when kind in [:exit, :error] -> {:error, {kind, reason}}
  end

  defp migrate(holders, waiters) do
    # Holders first, so a project's count is complete before any promotion.
    {acc, failed_projects} =
      Enum.reduce(holders, {%{summary: summary(), capacities: %{}}, MapSet.new()}, fn run_id,
                                                                                      {acc, bad} ->
        carry(run_id, :holder, acc, bad)
      end)

    {acc, failed_projects} =
      Enum.reduce(waiters, {acc, failed_projects}, fn run_id, {acc, bad} ->
        carry(run_id, :waiter, acc, bad)
      end)

    queued_projects =
      waiters
      |> Enum.map(&resolve_project/1)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(failed_projects, &1))

    promoted =
      Enum.reduce(queued_projects, 0, fn project_id, total ->
        total + promote(project_id, capacity(acc.capacities, project_id))
      end)

    %{acc.summary | promoted: promoted}
  end

  defp carry(run_id, kind, acc, bad) do
    cond do
      # After a failed carry-over for a project, its later waiters wait for the next pass, so a
      # retry keeps the legacy order (AC-009-2) instead of queueing the failed one last.
      kind == :waiter and skip_for_failed_project?(run_id, bad) ->
        {bump(acc, :skipped), bad}

      BootReconciliation.slot_entry_orphan?(run_id) ->
        {bump(acc, :skipped), bad}

      project_id = resolve_project(run_id) ->
        capacity = capacity(acc.capacities, project_id)
        acc = %{acc | capacities: Map.put(acc.capacities, project_id, capacity)}

        case dispatch(command(kind, run_id, project_id, capacity)) do
          :ok ->
            {bump(acc, if(kind == :holder, do: :adopted, else: :queued)), bad}

          :error ->
            {bump(acc, :failed), MapSet.put(bad, project_id)}
        end

      true ->
        Logger.warning(
          "RunSlotsMigration: cannot resolve the project of legacy slot #{kind} #{run_id}; skipped"
        )

        {bump(acc, :skipped), bad}
    end
  end

  defp skip_for_failed_project?(run_id, bad) do
    MapSet.size(bad) > 0 and MapSet.member?(bad, resolve_project(run_id))
  end

  defp command(:holder, run_id, project_id, capacity) do
    acquire(run_id, project_id, capacity, "run-slots:adopt:#{run_id}", force: true)
  end

  defp command(:waiter, run_id, project_id, capacity) do
    acquire(run_id, project_id, capacity, "run-slots:migrate-waiter:#{run_id}",
      enqueue_only: true
    )
  end

  defp acquire(run_id, project_id, capacity, command_id, flags) do
    %{
      type: "run_slots.acquire",
      command_id: command_id,
      aggregate_id: RunSlots.stream_id(project_id),
      payload:
        Map.merge(%{run_id: run_id, project_id: project_id, capacity: capacity}, Map.new(flags))
    }
  end

  # Fills the free capacity of one project, head first; `promote` is state-based, so a repeat is
  # a no-op. Bounded by the capacity: a project can never need more promotions than that.
  defp promote(_project_id, capacity) when capacity <= 0, do: 0
  defp promote(project_id, capacity), do: promote(project_id, capacity, capacity, 0)

  defp promote(_project_id, _capacity, 0, count), do: count

  defp promote(project_id, capacity, remaining, count) do
    command = %{
      type: "run_slots.promote",
      command_id:
        "run-slots:migrate-promote:#{project_id}:#{System.system_time(:millisecond)}:" <>
          Integer.to_string(System.unique_integer([:positive, :monotonic])),
      aggregate_id: RunSlots.stream_id(project_id),
      payload: %{project_id: project_id, capacity: capacity}
    }

    case safe_dispatch(command) do
      {:ok, nil} -> count
      {:ok, _promoted} -> promote(project_id, capacity, remaining - 1, count + 1)
      {:error, _} -> count
    end
  end

  defp dispatch(command) do
    case safe_dispatch(command) do
      {:ok, _event_or_nil} -> :ok
      {:error, _} -> :error
    end
  end

  defp safe_dispatch(command) do
    case CommandGateway.dispatch_system(command) do
      {:ok, _} = ok ->
        ok

      {:error, reason} = error ->
        Logger.warning("RunSlotsMigration: #{command.type} failed: #{inspect(reason)}")
        error
    end
  catch
    :exit, reason ->
      Logger.warning("RunSlotsMigration: #{command.type} exited: #{inspect(reason)}")
      {:error, {:exit, reason}}
  end

  defp capacity(capacities, project_id) do
    Map.get_lazy(capacities, project_id, fn -> RunAdmission.project_capacity(project_id) end)
  end

  # The run's project: its run projection, else the task that owns the run (same order as
  # `Workflow.Dispatcher`). `nil` when neither says.
  @doc false
  @spec resolve_project(String.t()) :: String.t() | nil
  def resolve_project(run_id) do
    run_project(run_id) || task_project(run_id)
  end

  defp run_project(run_id) do
    case ProjectionStore.run(run_id) do
      %{} = run -> present(Map.get(run, :project_id) || Map.get(run, "project_id"))
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  defp task_project(run_id) do
    run_id
    |> ProjectionStore.tasks_by_run_id()
    |> Enum.find_value(&present(Map.get(&1, :project_id) || Map.get(&1, "project_id")))
  catch
    :exit, _ -> nil
  end

  defp present(id) when is_binary(id) and id != "", do: id
  defp present(_), do: nil

  defp holder_acquired_at(%{acquired_at_ms: ms}) when is_integer(ms), do: ms
  defp holder_acquired_at(_), do: 0

  defp summary, do: %{adopted: 0, queued: 0, promoted: 0, skipped: 0, failed: 0}

  defp bump(acc, key), do: %{acc | summary: Map.update!(acc.summary, key, &(&1 + 1))}
end
