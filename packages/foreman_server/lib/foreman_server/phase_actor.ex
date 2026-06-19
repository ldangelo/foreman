defmodule ForemanServer.PhaseActor do
  @moduledoc "OTP actor tracking one workflow phase within a run."

  use GenServer

  @type status :: :pending | :in_progress | :completed | :failed | :timed_out

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(%{run_id: run_id, phase_id: phase_id} = state) do
    GenServer.start_link(__MODULE__, state, name: via(run_id, phase_id))
  end

  @spec child_spec(map()) :: Supervisor.child_spec()
  def child_spec(%{run_id: run_id, phase_id: phase_id} = state) do
    %{
      id: {__MODULE__, run_id, phase_id},
      start: {__MODULE__, :start_link, [state]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }
  end

  @spec status(String.t(), String.t()) :: map() | nil
  def status(run_id, phase_id) do
    case GenServer.whereis(via(run_id, phase_id)) do
      nil -> nil
      pid -> GenServer.call(pid, :status)
    end
  end

  @spec transition(String.t(), String.t(), status(), map()) :: :ok | {:error, term()}
  def transition(run_id, phase_id, status, details \\ %{}) do
    case GenServer.whereis(via(run_id, phase_id)) do
      nil -> {:error, :phase_not_found}
      pid -> GenServer.call(pid, {:transition, status, details})
    end
  end

  @impl true
  def init(%{run_id: run_id, phase_id: phase_id} = state) do
    {:ok,
     %{
       run_id: run_id,
       phase_id: phase_id,
       status: Map.get(state, :status, :pending),
       attempts: Map.get(state, :attempts, 0),
       details: %{}
     }}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state, state}

  def handle_call({:transition, status, details}, _from, state) do
    next =
      state
      |> Map.put(:status, status)
      |> Map.put(:details, details)
      |> maybe_increment_attempt(status)

    {:reply, :ok, next}
  end

  defp maybe_increment_attempt(state, :in_progress), do: Map.update!(state, :attempts, &(&1 + 1))
  defp maybe_increment_attempt(state, _status), do: state

  defp via(run_id, phase_id), do: {:global, {__MODULE__, run_id, phase_id}}
end
