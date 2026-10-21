defmodule ForemanServer.Library.Plan do
  @moduledoc """
  A validated ingest plan: exactly which files will be copied into the library
  and which were skipped (with a reason). Produced by `ForemanServer.Library.Ingest`,
  consumed by `ForemanServer.Library.Store`. Planning never touches the library.
  """

  defmodule Item do
    @moduledoc "One file selected for copying."
    @enforce_keys [:relative_path, :source_path, :bytes]
    @type t :: %__MODULE__{
            relative_path: String.t(),
            source_path: String.t(),
            bytes: non_neg_integer()
          }
    defstruct [:relative_path, :source_path, :bytes]
  end

  defmodule Skip do
    @moduledoc "One file or directory left out, with the reason."
    @type reason ::
            :hidden
            | :node_modules
            | :symlink
            | :not_regular
            | :over_30mb
            | :folder_byte_budget
            | :folder_file_cap
    @enforce_keys [:path, :reason]
    @type t :: %__MODULE__{path: String.t(), reason: reason()}
    defstruct [:path, :reason]
  end

  @enforce_keys [:kind, :name, :files]
  @type t :: %__MODULE__{
          kind: :file | :folder | :produced,
          name: String.t(),
          files: [Item.t()],
          skipped: [Skip.t()],
          total_bytes: non_neg_integer()
        }
  defstruct [:kind, :name, :files, skipped: [], total_bytes: 0]

  @doc "Skipped-file counts keyed by reason string (the shape stored on events)."
  @spec skipped_summary([Skip.t()]) :: %{String.t() => pos_integer()}
  def skipped_summary(skipped) do
    Enum.frequencies_by(skipped, &Atom.to_string(&1.reason))
  end
end
