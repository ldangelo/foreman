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
    * `:hook_failed` — `Jobsite.Hooks`, `Jobsite.Engine` (also the project setup script)
    * `:project_env_invalid` — `Jobsite.Executor` (the project's stored environment uses
      reserved `FOREMAN_*` names; fails loudly, never silently dropped)
    * `:network_policy_unsupported` / `:network_policy_violation` / `:network_policy_failed` —
      `Jobsite.NetworkPolicy` (project `environment.network` on a non-docker sandbox; a
      wider sandbox network than the policy; docker refused to create the policy's network)
    * `:agent_start_failed` / `:agent_failed` / `:agent_idle_timeout` — `Jobsite.AgentRunner`
    * `:resume_with_iterations` / `:output_tag_missing` / `:output_invalid` /
      `:output_with_iterations` — `Jobsite.Output` / `Jobsite.Options`
    * `:jobsite_not_found` / `:not_resumable` — `Jobsite.resume/1`,
      `Jobsite.resume_async/2`, via `Jobsite.Executor.check_resumable/1`
      (`:not_resumable` covers a terminal jobsite and one that never
      provisioned a worktree)
    * `:dispatch_rejected` — `Jobsite.Executor`
    * `:thread_cap_reached` — `Jobsite.Executor.reserve_thread/2` (project daily thread cap)
    * `:runner_capability` / `:unsupported_phase_action` — `Workflow.Lowering`
    * `:executor_lost` / `:boot_recovery_failed` — `Jobsite.BootRecovery`
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
