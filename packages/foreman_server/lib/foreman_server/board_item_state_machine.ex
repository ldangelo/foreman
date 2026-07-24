defmodule ForemanServer.BoardItemStateMachine do
  @moduledoc """
  Pure functions for the board item lifecycle vocabulary. Used by
  `ForemanServer.ProjectionStore.normalize_board_output/1` and the
  `build_board*` helpers to derive a consistent board view from the
  task and run projections. Not a reducer; not a projection; just a
  mapping/guard.

  ## Vocabulary

  The user-directed lifecycle statuses are: `backlog`, `ready`,
  `in-progress`, `blocked`, `done`. The API column key is the same
  with the hyphen replaced by an underscore (`in_progress`) so the
  payload can be indexed with atom keys (`board.in_progress`).

  ## What is NOT accepted

  Workflow phase names — `developer`, `qa`, `reviewer`, `explorer`,
  `finalize`, `merge`, `cooldown` — are NEVER treated as a lifecycle
  status. They belong to runs, not tasks. The previous board payload
  leaked `run.status` (which can be a phase name) into the visible
  `status` field; this module prevents that by re-deriving the
  lifecycle status from `task.status` only, and rendering the phase
  as a separate `current_phase` field.
  """

  @typedoc "One of the five lifecycle statuses."
  @type status :: String.t()

  @lifecycle_statuses ~w(backlog ready in-progress blocked done)

  @doc "The five lifecycle statuses in display order."
  @spec lifecycle_statuses() :: [String.t()]
  def lifecycle_statuses, do: @lifecycle_statuses

  @doc "True iff `value` is one of the five lifecycle statuses."
  @spec lifecycle?(any()) :: boolean()
  def lifecycle?(value) when is_binary(value) do
    Enum.member?(@lifecycle_statuses, String.trim(value))
  end

  def lifecycle?(_), do: false

  @doc """
  Map a task-projection status string to its lifecycle equivalent.

  Returns `nil` for phase names, run statuses, or anything not in the
  vocabulary — the derivation must fall back to a default (typically
  `in-progress` if there's an active run, otherwise `backlog`) rather
  than guess.
  """
  @spec task_status_to_board_status(String.t() | nil) :: status() | nil
  def task_status_to_board_status(nil), do: nil

  def task_status_to_board_status(status) when is_binary(status) do
    case String.trim(status) |> String.downcase() do
      s when s in ["backlog", "open", "todo"] -> "backlog"
      s when s in ["ready", "approved"] -> "ready"
      s when s in ["in_progress", "in-progress", "running", "cooldown", "review"] -> "in-progress"
      s when s in ["blocked", "conflict", "stuck", "failed", "fail", "test_failed"] -> "blocked"
      s when s in ["merged", "closed", "completed", "done", "reset", "pr_created"] -> "done"
      _ -> nil
    end
  end

  def task_status_to_board_status(_), do: nil

  @doc """
  Translate a board item's lifecycle status to the API column key. The
  board API exposes columns as `backlog | ready | in_progress | blocked
  | done` (underscored). The internal status uses `in-progress` (hyphen)
  to match the rest of the codebase's status vocabulary.
  """
  @spec board_column_key(status()) :: String.t()
  def board_column_key("in-progress"), do: "in_progress"
  def board_column_key(other) when is_binary(other), do: other
  @doc """
  Translate a run's `pr_state` to a board-level override. Used by the
  grouping logic to give PR terminal state precedence over a stale
  `task.status`. Returns `nil` for non-terminal PR states so the
  caller falls through to the task-based check.

  Precedence: PR `merged` → `done`; PR `closed`/`reset` → `blocked`;
  anything else (open, nil) → `nil` (caller falls through).
  """
  @spec pr_state_to_board_status(String.t() | nil) :: status() | nil
  def pr_state_to_board_status("merged"), do: "done"
  def pr_state_to_board_status("closed"), do: "blocked"
  def pr_state_to_board_status("reset"), do: "blocked"
  def pr_state_to_board_status(_), do: nil
end
