defmodule ForemanServer.Events.JobsiteRequestAudited do
  @moduledoc """
  Typed event appended to the fixed `jobsite_audit:global` stream for every
  remote-jobsite HTTP request, accepted or rejected. A rejected request
  creates no jobsite; this event is the only trace.
  """
  @enforce_keys [:route, :method, :outcome, :remote_address, :at]
  @type t :: %__MODULE__{
          route: String.t(),
          method: String.t(),
          outcome: String.t(),
          error_code: String.t() | nil,
          jobsite_id: String.t() | nil,
          remote_address: String.t(),
          at: String.t()
        }
  @derive Jason.Encoder
  defstruct [:route, :method, :outcome, :error_code, :jobsite_id, :remote_address, :at]
end
