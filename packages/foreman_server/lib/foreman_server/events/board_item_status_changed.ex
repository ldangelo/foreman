defmodule ForemanServer.Events.BoardItemStatusChanged do
  @enforce_keys [:board_item_id, :from_status, :to_status]
  @type t :: %__MODULE__{
          board_item_id: String.t(),
          from_status: String.t() | nil,
          to_status: String.t()
        }
  @derive Jason.Encoder
  defstruct [:board_item_id, :from_status, :to_status]

  alias ForemanServer.Aggregate

  @spec from_payload(map()) :: t()
  def from_payload(payload) when is_map(payload) do
    board_item_id = payload["board_item_id"] || payload[:board_item_id]
    to_status = payload["to_status"] || payload[:to_status]

    with {:ok, _} <- Aggregate.required_binary(board_item_id, :board_item_id),
         {:ok, _} <- Aggregate.required_binary(to_status, :to_status) do
      %__MODULE__{
        board_item_id: board_item_id,
        from_status: payload["from_status"] || payload[:from_status],
        to_status: to_status
      }
    else
      {:error, reason} ->
        raise ArgumentError, "invalid BoardItemStatusChanged payload: #{inspect(reason)}"
    end
  end
end
