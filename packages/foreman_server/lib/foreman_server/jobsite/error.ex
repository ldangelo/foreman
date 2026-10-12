defmodule ForemanServer.Jobsite.Error do
  @moduledoc """
  Typed error payload for every Jobsite failure. Per AGENTS.md §5.1, a
  failure is always this struct, never a bare map.

  `code` vocabulary (each used once, at its origin):

    * `:prompt_source_missing` / `:prompt_source_conflict` / `:prompt_arg_missing` /
      `:prompt_arg_reserved` / `:prompt_expansion_failed` — `Jobsite.Prompt`
    * `:worktree_create_failed` / `:worktree_vanished` / `:branch_strategy_unsupported` /
      `:merge_conflict` / `:merge_failed` — `Jobsite.Worktree`
    * `:commit_failed` / `:git_failed` — `Jobsite.Git`
    * `:sandbox_create_failed` / `:sandbox_exec_failed` / `:copy_failed` / `:image_missing` —
      sandbox providers
    * `:hook_failed` — `Jobsite.Hooks`
    * `:agent_start_failed` / `:agent_failed` / `:agent_idle_timeout` — `Jobsite.AgentRunner`
    * `:resume_with_iterations` / `:output_tag_missing` / `:output_invalid` /
      `:output_with_iterations` — `Jobsite.Output` / `Jobsite.Options`
    * `:jobsite_not_found` / `:not_resumable` — `Jobsite.resume/1`
    * `:dispatch_rejected` — `Jobsite.Executor`
    * `:runner_capability` / `:unsupported_phase_action` — `Workflow.Lowering`
  """
  @enforce_keys [:code, :message]
  @type t :: %__MODULE__{code: atom(), message: String.t(), details: map()}
  defstruct [:code, :message, details: %{}]

  @spec new(atom(), String.t(), map()) :: t()
  def new(code, message, details \\ %{})
      when is_atom(code) and is_binary(message) and is_map(details) do
    %__MODULE__{code: code, message: message, details: details}
  end
end
