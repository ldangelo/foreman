defmodule ForemanServer.Jobsite.Step do
  @moduledoc """
  One step of a `ForemanServer.Jobsite.Program`. `kind` selects the
  `ForemanServer.Jobsite.Engine` handler; `opts` is kind-specific (see
  `Engine` moduledoc for the table of kinds and their keys).
  """

  @enforce_keys [:kind, :id]
  @type kind :: :worktree | :sandbox | :hook | :agent | :exec | :commit | :push | :gate | :release
  @type t :: %__MODULE__{kind: kind(), id: String.t(), label: String.t() | nil, opts: map()}
  defstruct [:kind, :id, label: nil, opts: %{}]
end
