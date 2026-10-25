defmodule ForemanServer.Events.CoordinatorUsageRecorded do
  @moduledoc """
  Typed event: the provider usage of one coordinator turn, recorded after the
  agent ran and before the turn completes or fails (a failed turn spent its
  tokens too).

  It feeds the same usage ledger as `UsageRecorded` (`ForemanServer.Usage`;
  `foreman usage --by role` lists it as role `coordinator`) but it is NOT a run
  event: a coordinator turn is not a run, so folding it never creates or touches
  a run projection. The ledger key is the turn, so folding the same event twice
  (live, then replayed) replaces instead of double counting.

  Token fields and `cost_usd` are `nil` when the provider did not report them
  (never `0`); at least one of them is set, because an all-nil event would read
  as "recorded, unknown". `model` is `nil` when the project pins none.
  """
  @enforce_keys [:project_id, :turn_id, :provider, :at]
  @type t :: %__MODULE__{
          project_id: String.t(),
          turn_id: String.t(),
          provider: String.t(),
          model: String.t() | nil,
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          cache_read_tokens: non_neg_integer() | nil,
          cache_write_tokens: non_neg_integer() | nil,
          total_tokens: non_neg_integer() | nil,
          cost_usd: float() | nil,
          at: String.t()
        }
  @derive Jason.Encoder
  defstruct [
    :project_id,
    :turn_id,
    :provider,
    :model,
    :input_tokens,
    :output_tokens,
    :cache_read_tokens,
    :cache_write_tokens,
    :total_tokens,
    :cost_usd,
    :at
  ]
end
