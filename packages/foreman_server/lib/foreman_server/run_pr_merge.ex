defmodule ForemanServer.RunPrMerge do
  @moduledoc """
  Performs the real GitHub merge behind the operator `run.pr.merge` command.

  The `Run` aggregate's `run.pr.merge` handler only *records* a merge (`PrMerged`)
  once the merge gate is approved. It must stay pure — the actor re-runs
  `handle_command/2` on a version conflict, which would repeat a real merge — so
  the side effect lives here and `CommandGateway.dispatch_operator/2` runs it
  *before* dispatching the command.

  `execute/1` refuses unless every one of these holds:

    * the run's merge gate is `:approved`, read from the event-sourced aggregate
      (not the ETS-backed `MergeGate`, which does not survive a restart);
    * the PR is still open and unconflicted, or already merged;
    * the PR head is still the commit that was approved (`PrReady` carries it),
      so commits pushed after approval cannot be merged unreviewed. `gh` is also
      told `--match-head-commit`, so the pin holds against a push that lands
      between the check and the merge.

  An already-merged PR is not merged again: a retry after `gh` succeeded but the
  event append failed records the merge instead of failing.

  On success it returns the `run.pr.merge` payload, built entirely from the stored
  `PrReady` event. The caller's payload is discarded, so a client can neither
  retarget the merge nor skip the head pin.
  """

  alias ForemanServer.Aggregate
  alias ForemanServer.Aggregates.Run
  alias ForemanServer.EventStore
  alias ForemanServer.GitHub.PrMerge
  alias ForemanServer.GitHub.PrStatus

  @runner_key {__MODULE__, :command_runner}
  @payload_keys [:project_id, :task_id, :pr_url, :branch_name, :head_sha, :base_branch]

  @doc """
  Test seam: route the `gh` calls of this module through `fun`, a 3-arity
  `(cmd, args, opts)` returning `{output, exit_code}`. Without it the installed
  `gh` runs.
  """
  @spec set_command_runner((String.t(), [String.t()], keyword() -> {String.t(), integer()})) ::
          :ok
  def set_command_runner(fun) when is_function(fun, 3) do
    :persistent_term.put(@runner_key, fun)
  end

  @doc "Remove the runner installed by `set_command_runner/1`."
  @spec clear_command_runner() :: boolean()
  def clear_command_runner, do: :persistent_term.erase(@runner_key)

  @doc """
  Merge the PR of `run_id` on GitHub and return the `run.pr.merge` payload to
  record. Concurrent calls for one run are serialized, so the second observes the
  first's merge instead of racing it.
  """
  @spec execute(String.t()) :: {:ok, map()} | {:error, term()}
  def execute(run_id) when is_binary(run_id) and run_id != "" do
    :global.trans({{__MODULE__, run_id}, self()}, fn -> merge(run_id) end)
  end

  defp merge(run_id) do
    with :ok <- require_gate_approved(run_id),
         {:ok, ready} <- approved_ready_payload(run_id),
         {:ok, current} <- PrStatus.fetch(ready.pr_url, runner_opts()),
         :ok <- merge_unless_done(current, ready) do
      {:ok, Map.put(ready, :run_id, run_id)}
    end
  end

  defp require_gate_approved(run_id) do
    {state, _version} = Aggregate.load(Run, "run:#{run_id}")

    cond do
      not state.exists? -> {:error, {:run_not_found, run_id}}
      state.merge_gate == :approved -> :ok
      true -> {:error, :pr_not_acceptable}
    end
  end

  # The most recent `PrReady` is the one the gate was opened (and approved) for.
  defp approved_ready_payload(run_id) do
    case EventStore.read_stream_forward("run:#{run_id}", 0, 99_999_999) do
      {:ok, events} ->
        events
        |> Enum.filter(&(&1.event_type == "PrReady"))
        |> List.last()
        |> ready_payload(run_id)

      {:error, :stream_not_found} ->
        {:error, {:run_not_found, run_id}}
    end
  end

  defp ready_payload(nil, run_id), do: {:error, {:pr_ready_event_missing, run_id}}

  defp ready_payload(%{data: data}, _run_id) do
    Enum.reduce_while(@payload_keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case Aggregate.required_binary(Aggregate.get(data, key), key) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp merge_unless_done(%PrStatus{status: :merged}, _ready), do: :ok

  defp merge_unless_done(%PrStatus{status: :open, head_sha: head}, %{head_sha: approved} = ready) do
    if head == approved do
      PrMerge.merge(ready.pr_url, approved, runner_opts())
    else
      {:error, {:head_moved_since_approval, approved, head}}
    end
  end

  defp merge_unless_done(%PrStatus{status: :closed}, ready),
    do: {:error, {:pr_closed, ready.pr_url}}

  defp merge_unless_done(%PrStatus{status: :conflicted}, ready),
    do: {:error, {:pr_conflicted, ready.pr_url}}

  defp runner_opts do
    case :persistent_term.get(@runner_key, :unset) do
      :unset -> []
      fun -> [command_runner: fun]
    end
  end
end
