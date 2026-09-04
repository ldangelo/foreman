defmodule ForemanServer.Aggregates.BoardItemStateMachine do
  @moduledoc """
  TRD-010: BoardItemStateMachine aggregate.

  Models the lifecycle of a kanban-style board item with a fixed state
  machine:

      backlog → in_progress → in_review → done
      backlog → blocked     → backlog
      done    → terminal

  Invalid transitions are rejected with `:invalid_transition`. State is
  stored in the event log via `BoardItemCreated` and `BoardItemTransitioned`
  events.

  ## Stream id

      board_item:<board_item_id>

  ## Commands

      * `board_item.create`     — emits `BoardItemCreated` with initial status
      * `board_item.transition` — emits `BoardItemTransitioned` if the new
        status is a valid successor of the current status
  """

  alias ForemanServer.Aggregate

  @behaviour ForemanServer.Aggregate

  @statuses ~w(backlog in_progress in_review done blocked)

  @transitions %{
    "backlog" => ~w(in_progress blocked),
    "in_progress" => ~w(in_review backlog blocked),
    "in_review" => ~w(done in_progress blocked),
    "blocked" => ~w(backlog in_progress in_review),
    "done" => []
  }

  defmodule State do
    @moduledoc "Per-board-item state."
    @enforce_keys [:exists?, :board_item_id]
    defstruct [
      :exists?,
      :board_item_id,
      :status,
      :terminal?,
      :created_at_ms,
      :last_transition_at_ms,
      :history
    ]
  end

  @impl true
  def initial_state do
    %State{
      exists?: false,
      board_item_id: nil,
      status: nil,
      terminal?: false,
      created_at_ms: nil,
      last_transition_at_ms: nil,
      history: []
    }
  end

  @impl true
  def handle_command(state, %{type: "board_item.create", payload: payload}) do
    with {:ok, board_item_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :board_item_id), :board_item_id),
         {:ok, status} <- required_status(Aggregate.get(payload, :status, "backlog")),
         :ok <- require_absent(state, board_item_id) do
      {:ok,
       %{
         stream_id: stream_id(board_item_id),
         event_type: "BoardItemCreated",
         payload:
           payload
           |> Map.put(:board_item_id, board_item_id)
           |> Map.put(:status, status)
           |> Map.put(:created_at_ms, Aggregate.get(payload, :created_at_ms, now_ms()))
       }}
    end
  end

  def handle_command(state, %{type: "board_item.transition", payload: payload}) do
    with {:ok, board_item_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :board_item_id), :board_item_id),
         {:ok, new_status} <- required_status(Aggregate.get(payload, :to_status)),
         :ok <- require_exists(state, board_item_id),
         :ok <- reject_terminal(state),
         :ok <- require_valid_transition(state.status, new_status) do
      {:ok,
       %{
         stream_id: stream_id(board_item_id),
         event_type: "BoardItemTransitioned",
         payload:
           payload
           |> Map.put(:board_item_id, board_item_id)
           |> Map.put(:from_status, state.status)
           |> Map.put(:to_status, new_status)
           |> Map.put(:transitioned_at_ms, Aggregate.get(payload, :transitioned_at_ms, now_ms()))
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  @impl true
  def apply_event(%State{} = state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "BoardItemCreated" ->
        status = Aggregate.get(payload, :status, "backlog")

        %State{
          state
          | exists?: true,
            board_item_id: Aggregate.get(payload, :board_item_id) || state.board_item_id,
            status: status,
            terminal?: status == "done",
            created_at_ms: Aggregate.get(payload, :created_at_ms) || now_ms(),
            history:
              state.history ++
                [{:created, status, Aggregate.get(payload, :created_at_ms, now_ms())}]
        }

      "BoardItemTransitioned" ->
        from_status = Aggregate.get(payload, :from_status) || state.status
        to_status = Aggregate.get(payload, :to_status) || state.status
        at = Aggregate.get(payload, :transitioned_at_ms) || now_ms()

        %State{
          state
          | status: to_status,
            terminal?: to_status == "done",
            last_transition_at_ms: at,
            history: state.history ++ [{:transition, from_status, to_status, at}]
        }

      _ ->
        state
    end
  end

  @doc "Build the stream id for a board_item_id."
  @spec stream_id(String.t()) :: String.t()
  def stream_id(board_item_id) when is_binary(board_item_id), do: "board_item:#{board_item_id}"

  @doc "Valid successors for a given status."
  @spec valid_transitions(String.t()) :: [String.t()]
  def valid_transitions(status) when is_binary(status), do: Map.get(@transitions, status, [])

  @doc "List the supported statuses."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Is the supplied status one of the canonical ones?"
  @spec valid_status?(term()) :: boolean()
  def valid_status?(status) when status in @statuses, do: true
  def valid_status?(_), do: false

  defp required_status(status) when status in @statuses, do: {:ok, status}
  defp required_status(other), do: {:error, {:invalid_status, other}}

  defp require_absent(%State{exists?: false}, _id), do: :ok
  defp require_absent(_state, id), do: {:error, {:already_exists, id}}

  defp require_exists(%State{exists?: true, board_item_id: id}, id), do: :ok
  defp require_exists(%State{exists?: false}, _id), do: {:error, :not_found}
  defp require_exists(_state, _id), do: {:error, :not_found}

  defp require_valid_transition(current, next) do
    if next in Map.get(@transitions, current, []) do
      :ok
    else
      {:error, :invalid_transition}
    end
  end

  defp reject_terminal(%State{terminal?: true}), do: {:error, :already_terminal}
  defp reject_terminal(_state), do: :ok

  defp now_ms, do: System.system_time(:millisecond)
end
