defmodule ForemanServer.Aggregates.BoardItemStateMachine do
  @moduledoc "Board item lifecycle aggregate: enforces valid status transitions."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate
  alias ForemanServer.Events.BoardItemStatusChanged

  # ─── State ─────────────────────────────────────────────────────────────────

  defmodule State do
    @enforce_keys []
    defstruct [:exists?, :board_item_id, :status, :terminal?]

    @type t :: %__MODULE__{
            exists?: boolean,
            board_item_id: String.t() | nil,
            status: String.t() | nil,
            terminal?: boolean
          }
  end

  @impl true
  def initial_state,
    do: %State{
      exists?: false,
      board_item_id: nil,
      status: nil,
      terminal?: false
    }

  # ─── apply_event — typed struct clauses ────────────────────────────────────

  # Unwrap %ForemanServer.Event{payload: %BoardItemStatusChanged{}} from decode_for_fold
  @impl true
  def apply_event(state, %ForemanServer.Event{payload: %BoardItemStatusChanged{} = e}) do
    apply_event(state, e)
  end

  # Direct typed struct (used in tests that fold with the struct directly)
  @impl true
  def apply_event(state, %BoardItemStatusChanged{} = event) do
    %State{
      state
      | exists?: true,
        board_item_id: event.board_item_id,
        status: event.to_status,
        terminal?: event.to_status == "done"
    }
  end

  # ─── apply_event — fallback for legacy map events ───────────────────────────

  @impl true
  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "BoardItemStatusChanged" ->
        %State{
          state
          | exists?: true,
            board_item_id: Aggregate.get(payload, :board_item_id),
            status: Aggregate.get(payload, :to_status),
            terminal?: Aggregate.get(payload, :to_status) == "done"
        }

      _ ->
        state
    end
  end

  # ─── handle_command ─────────────────────────────────────────────────────────

  @impl true
  def handle_command(state, %{type: "board_item.create", payload: payload}) do
    with {:ok, board_item_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :board_item_id), :board_item_id),
         :ok <- require_absent(state, board_item_id) do
      {:ok,
       %{
         stream_id: "board_item:#{board_item_id}",
         event_type: "BoardItemStatusChanged",
         payload: %{board_item_id: board_item_id, from_status: nil, to_status: "backlog"}
       }}
    end
  end

  def handle_command(state, %{type: "board_item.transition", payload: payload}) do
    with {:ok, board_item_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :board_item_id), :board_item_id),
         {:ok, to_status} <-
           Aggregate.required_binary(Aggregate.get(payload, :to_status), :to_status),
         :ok <- require_exists(state, board_item_id) do
      case valid_transition(state.status, to_status) do
        true ->
          {:ok,
           %{
             stream_id: "board_item:#{board_item_id}",
             event_type: "BoardItemStatusChanged",
             payload: %{
               board_item_id: board_item_id,
               from_status: state.status,
               to_status: to_status
             }
           }}

        false ->
          {:error, :invalid_transition}
      end
    end
  end

  def handle_command(_state, _command), do: :unhandled

  # ─── private ───────────────────────────────────────────────────────────────

  # Valid transitions (TRD: backlog → in_progress → in_review → done;
  # backlog → blocked → backlog; done is terminal):
  #   nil → backlog
  #   backlog → in_progress
  #   backlog → blocked
  #   blocked → backlog
  #   in_progress → in_review
  #   in_review → done
  defp valid_transition(nil, "backlog"), do: true
  defp valid_transition("backlog", "in_progress"), do: true
  defp valid_transition("backlog", "blocked"), do: true
  defp valid_transition("blocked", "backlog"), do: true
  defp valid_transition("in_progress", "in_review"), do: true
  defp valid_transition("in_review", "done"), do: true
  defp valid_transition(_from, _to), do: false

  defp require_absent(%State{exists?: false}, _id), do: :ok
  defp require_absent(%State{exists?: true}, id), do: {:error, {:already_exists, :board_item, id}}

  defp require_exists(%State{exists?: true}, _id), do: :ok
  defp require_exists(%State{exists?: false}, id), do: {:error, {:not_found, :board_item, id}}
end
