defmodule ForemanServer.Events.CoordinatorMessageAppended do
  @moduledoc """
  Typed event appended to `coordinator:<project_id>` for every message of the
  project's coordinator conversation: an operator message, a coordinator
  reply, a system notice or a thread report.

  `role` is who authored it (`operator | coordinator | system | agent`), `kind`
  what it is (`message | reply | report | notice | setup_proposal`) and `source`
  the surface it entered through (`cli | http | mcp | dashboard | system`).
  `report_key` de-duplicates reports; `turn_id` links a reply to its turn. Only
  conversation text is stored, never an agent transcript.
  """
  @enforce_keys [:project_id, :message_id, :role, :kind, :text, :at]
  @type t :: %__MODULE__{
          project_id: String.t(),
          message_id: String.t(),
          role: String.t(),
          kind: String.t(),
          text: String.t(),
          source: String.t() | nil,
          thread_ref: map() | nil,
          report_key: String.t() | nil,
          turn_id: String.t() | nil,
          suppressed: boolean(),
          at: String.t()
        }
  @derive Jason.Encoder
  defstruct [
    :project_id,
    :message_id,
    :role,
    :kind,
    :text,
    :source,
    :thread_ref,
    :report_key,
    :turn_id,
    :at,
    suppressed: false
  ]
end
