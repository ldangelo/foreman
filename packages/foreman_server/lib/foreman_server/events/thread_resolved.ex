defmodule ForemanServer.Events.ThreadResolved do
  @moduledoc """
  Typed event appended to `thread:<thread_id>` when an operator (or the idle
  auto-resolver) marks a thread resolved. `source` is `"operator"` or a system
  actor name such as `"idle"`; `reason` is optional free text (<= 500 chars).
  """
  @enforce_keys [:thread_id, :project_id, :at]
  @type t :: %__MODULE__{
          thread_id: String.t(),
          project_id: String.t(),
          reason: String.t() | nil,
          resolved_by: String.t() | nil,
          source: String.t() | nil,
          at: String.t()
        }
  @derive Jason.Encoder
  defstruct [:thread_id, :project_id, :reason, :resolved_by, :source, :at]
end
