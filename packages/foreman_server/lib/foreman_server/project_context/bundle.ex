defmodule ForemanServer.ProjectContext.Bundle do
  @moduledoc "The rendered standing context for one project at one moment."

  alias ForemanServer.ProjectContext.Section

  @type truncation :: %{
          section: Section.id(),
          omitted_bytes: non_neg_integer(),
          omitted_lines: non_neg_integer()
        }

  @type t :: %__MODULE__{
          system_text: String.t() | nil,
          sections: [Section.t()],
          truncated: [truncation()],
          bytes: non_neg_integer(),
          sha256: String.t() | nil,
          redactions: non_neg_integer()
        }

  @enforce_keys [:system_text, :sections, :truncated, :bytes, :sha256]
  defstruct [:system_text, :sections, :truncated, :bytes, :sha256, redactions: 0]
end
