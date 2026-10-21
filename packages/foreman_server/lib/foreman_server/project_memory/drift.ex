defmodule ForemanServer.ProjectMemory.Drift do
  @moduledoc "Difference between on-disk topic files and the audit index (topic names)."
  @type t :: %__MODULE__{
          missing_on_disk: [String.t()],
          untracked_on_disk: [String.t()],
          sha_mismatch: [String.t()]
        }
  defstruct missing_on_disk: [], untracked_on_disk: [], sha_mismatch: []

  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{} = d),
    do: d.missing_on_disk == [] and d.untracked_on_disk == [] and d.sha_mismatch == []
end
