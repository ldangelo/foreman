defmodule ForemanServer.Workflow.WorktreeDiscard do
  @moduledoc """
  The record of a run worktree discarded on resume (`prior_worktree_discarded`
  on `PhaseStarted` / `PhaseRetried`): the worktree entry's `name`, and the
  `path` whose uncommitted changes were lost (nil when the run had no entry).

  The record arrives as an atom-keyed map from a live dispatch and as a
  string-keyed map from a replayed event. `from_event/1` is the one place that
  accepts both forms; everything after it reads the struct's fields.
  """

  @enforce_keys [:name]
  @type t :: %__MODULE__{name: String.t(), path: String.t() | nil}
  defstruct [:name, :path]

  @doc "Normalise a discard record from an event payload; raises when `name` is absent."
  @spec from_event(t() | map()) :: t()
  def from_event(%__MODULE__{} = discard), do: discard
  def from_event(%{name: name} = map), do: %__MODULE__{name: name, path: Map.get(map, :path)}

  def from_event(%{"name" => name} = map),
    do: %__MODULE__{name: name, path: Map.get(map, "path")}
end
