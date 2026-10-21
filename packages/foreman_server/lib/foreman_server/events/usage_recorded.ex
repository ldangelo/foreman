defmodule ForemanServer.Events.UsageRecorded do
  @moduledoc """
  Typed event emitted once per worker run, before `WorkerExited`, when the
  provider reported any token usage or cost. Failed runs record it too: their
  tokens were spent.

  Token fields and `cost_usd` are `nil` when the provider did not report them
  (never `0`); see `ForemanServer.Usage`. `role` is `"thread"` for a workflow
  phase agent. This event carries the facts only; rollups by project, day or
  model are a later read model.
  """
  @enforce_keys [:run_id, :worker_id, :provider]
  @type t :: %__MODULE__{
          run_id: String.t(),
          worker_id: String.t(),
          provider: String.t(),
          project_id: String.t() | nil,
          task_id: String.t() | nil,
          model: String.t() | nil,
          role: String.t() | nil,
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          cache_read_tokens: non_neg_integer() | nil,
          cache_write_tokens: non_neg_integer() | nil,
          total_tokens: non_neg_integer() | nil,
          cost_usd: float() | nil,
          run_status: String.t() | nil,
          at: String.t() | nil,
          sequence: non_neg_integer() | nil
        }
  @derive Jason.Encoder
  defstruct [
    :run_id,
    :worker_id,
    :provider,
    :project_id,
    :task_id,
    :model,
    :role,
    :input_tokens,
    :output_tokens,
    :cache_read_tokens,
    :cache_write_tokens,
    :total_tokens,
    :cost_usd,
    :run_status,
    :at,
    :sequence
  ]
end
