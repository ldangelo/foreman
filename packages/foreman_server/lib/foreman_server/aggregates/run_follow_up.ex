defmodule ForemanServer.Aggregates.RunFollowUp do
  @moduledoc """
  One stream per follow-up run, `run_followup:<run_id>` (`stream_id/1`), routed by
  `CommandRouter.aggregate_module_for/1` (the prefix does not start with `"run:"`).

  Command `run.followup.request` is SYSTEM-ONLY (dispatched through
  `CommandGateway.dispatch_system/2` by the PR fix path, never in an operator allowlist) and
  emits `RunFollowUpRequested`. It is refused while `ForemanServer.FollowUpRuns` is off, and a
  second request for the same run id is refused (`{:already_exists, :run_followup, run_id}`): the
  stream is the durable request the Dispatcher admits, once.

  This aggregate only records the request. The run itself starts through
  `RunAdmission.start/2`, so slots, project limits and pause/archive refusals apply unchanged.
  """

  @behaviour ForemanServer.Aggregate

  alias ForemanServer.{Aggregate, FollowUpRuns}
  alias ForemanServer.Events.RunFollowUpRequested

  @kinds ~w(pr_fix)

  @doc "The stream id of one follow-up run."
  @spec stream_id(String.t()) :: String.t()
  def stream_id(run_id) when is_binary(run_id), do: "run_followup:" <> run_id

  defmodule State do
    @moduledoc "Whether the follow-up request of one run was recorded."
    defstruct requested?: false
  end

  @impl true
  def initial_state, do: %State{}

  @impl true
  def apply_event(%State{} = state, event) do
    case Aggregate.event_type(event) do
      "RunFollowUpRequested" -> %State{state | requested?: true}
      _ -> state
    end
  end

  @impl true
  def handle_command(state, %{type: "run.followup.request", payload: payload}) do
    with :ok <- require_enabled(),
         {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_new(state, run_id),
         {:ok, project_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id),
         {:ok, kind} <- validate_kind(Aggregate.get(payload, :kind)),
         {:ok, requested_by} <-
           Aggregate.required_binary(Aggregate.get(payload, :requested_by), :requested_by),
         {:ok, attach_branch} <- optional(payload, :attach_branch),
         {:ok, parent_run_id} <- optional(payload, :parent_run_id),
         {:ok, pr_url} <- optional(payload, :pr_url),
         {:ok, fix_kind} <- optional(payload, :fix_kind),
         {:ok, prompt} <- optional(payload, :prompt),
         {:ok, note} <- optional(payload, :note),
         {:ok, provider} <- optional(payload, :provider),
         {:ok, model} <- optional(payload, :model),
         {:ok, effort} <- optional(payload, :effort),
         {:ok, approval_mode} <- optional(payload, :approval_mode),
         {:ok, sandbox} <- optional(payload, :sandbox),
         {:ok, repo_path} <- optional(payload, :repo_path),
         {:ok, worktree_path} <- optional(payload, :worktree_path),
         {:ok, {resume_provider, session_id}} <- validate_session(payload),
         {:ok, push} <- validate_push(Aggregate.get(payload, :push), attach_branch) do
      {:ok,
       %{
         stream_id: stream_id(run_id),
         event_type: "RunFollowUpRequested",
         payload: %RunFollowUpRequested{
           run_id: run_id,
           project_id: project_id,
           kind: kind,
           requested_by: requested_by,
           at: Aggregate.get(payload, :at) || DateTime.to_iso8601(DateTime.utc_now()),
           parent_run_id: parent_run_id,
           pr_url: pr_url,
           fix_kind: fix_kind,
           attach_branch: attach_branch,
           push: push,
           resume_session_provider: resume_provider,
           resume_session_id: session_id,
           prompt: prompt,
           provider: provider,
           model: model,
           effort: effort,
           approval_mode: approval_mode,
           sandbox: sandbox,
           repo_path: repo_path,
           worktree_path: worktree_path,
           note: note
         }
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  defp require_enabled do
    if FollowUpRuns.enabled?(), do: :ok, else: {:error, :followup_runs_disabled}
  end

  defp require_new(%State{requested?: true}, run_id),
    do: {:error, {:already_exists, :run_followup, run_id}}

  defp require_new(%State{}, _run_id), do: :ok

  defp validate_kind(kind) when kind in @kinds, do: {:ok, kind}

  defp validate_kind(kind) when is_binary(kind) and kind != "",
    do: {:error, {:invalid_kind, kind}}

  defp validate_kind(_), do: {:error, {:missing_or_invalid, :kind}}

  defp optional(payload, key) do
    case Aggregate.get(payload, key) do
      nil -> {:ok, nil}
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_or_invalid, key}}
    end
  end

  # A session is both halves or neither: a provider with no id (or the reverse) cannot be resumed.
  defp validate_session(payload) do
    with {:ok, provider} <- optional(payload, :resume_session_provider),
         {:ok, session_id} <- optional(payload, :resume_session_id) do
      case {provider, session_id} do
        {nil, nil} -> {:ok, {nil, nil}}
        {p, s} when is_binary(p) and is_binary(s) -> {:ok, {p, s}}
        _ -> {:error, {:missing_or_invalid, :resume_session}}
      end
    end
  end

  # A run may only push the branch it is attached to: `push: true` without one has nowhere to go.
  defp validate_push(nil, _attach_branch), do: {:ok, nil}
  defp validate_push(false, _attach_branch), do: {:ok, false}
  defp validate_push(true, attach_branch) when is_binary(attach_branch), do: {:ok, true}
  defp validate_push(true, nil), do: {:error, {:missing_or_invalid, :attach_branch}}
  defp validate_push(_other, _attach_branch), do: {:error, {:missing_or_invalid, :push}}
end
