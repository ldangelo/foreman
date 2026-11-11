defmodule ForemanServer.Events.PhaseContextRecorded do
  @moduledoc """
  Typed event recording the project context a phase launch delivered to its agent.

  Appended through the `phase.context` command on the Phase aggregate, once per
  launch whose project has standing context (a launch with none appends nothing).

    * `sha256` / `bytes` - the hash and size of the bundle's `system_text`, the text
      `ProjectContext.deliver/3` handed the agent. The identity covers the
      PROJECT-CONTEXT text only, not what else a launch adds around it: the operator
      progress addendum appended to the system prompt of a covered `command:` phase,
      the operator steering block appended to the prompt, and (for a provider without
      a system prompt) the `---` separator and the prompt the context is prefixed to.
    * `sections` - `[%{id, bytes}]`, `bytes` being `byte_size(section.body)`: the measure
      `GET /api/projects/:id/context` reports, not the size before any cap.
    * `truncated` - `[%{section, omitted_bytes, omitted_lines}]`, one per cut section.
    * `redactions` - how many secret spans were replaced.
    * `redaction_scope` - what the redaction count covers (`"project_context_sections"`:
      the sections of this bundle, not the agent's prompt, files or tool output).

  "Recorded" means the launch built and recorded the context, not that the agent
  started: the record is appended before the launch's steering messages are consumed,
  which can still fail the launch.
  """
  @enforce_keys [
    :phase_id,
    :run_id,
    :sections,
    :sha256,
    :bytes,
    :truncated,
    :redactions,
    :redaction_scope
  ]
  @type t :: %__MODULE__{
          phase_id: String.t(),
          sequence: non_neg_integer() | nil,
          run_id: String.t(),
          sections: [%{id: String.t(), bytes: non_neg_integer()}],
          sha256: String.t(),
          bytes: non_neg_integer(),
          truncated: [
            %{
              section: String.t(),
              omitted_bytes: non_neg_integer(),
              omitted_lines: non_neg_integer()
            }
          ],
          redactions: non_neg_integer(),
          redaction_scope: String.t()
        }
  @derive Jason.Encoder
  defstruct [
    :phase_id,
    :sequence,
    :run_id,
    :sections,
    :sha256,
    :bytes,
    :truncated,
    :redactions,
    :redaction_scope
  ]
end
