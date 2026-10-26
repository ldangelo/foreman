defmodule ForemanServer.Coordinator.Actions.ApplyRecommendation do
  @moduledoc """
  The `apply_recommendation` coordinator action: apply ONE setup recommendation's
  machine fix (`ForemanServer.Projects.Recommendations`).

  The model supplies an id and nothing else (`Coordinator.Action` drops every
  other key). The handler RECOMPUTES the project's recommendations at execution
  time and runs only the `fix` Foreman itself computed for that id, so a pasted
  text, a report or a hijacked model cannot make it run anything Foreman would
  not have proposed. Only `fix.kind :command` items are appliable; `:manual`
  ones are advice.

  Outcomes, as the `{status, reason, result_ref, started}` the `Executor` records:

    * `executed` - the fix command was dispatched through `Coordinator.Dispatch`
      (closed allowlist) with a command id derived from the action id, so a re-run
      of the same turn dispatches nothing twice;
    * `rejected` - the id is not a current recommendation
      (`recommendation_not_found`: already fixed, stale, or never one of
      Foreman's), the item is advice only (`not_appliable`), or its fix is not a
      command this project's coordinator may run;
    * `failed` - the recommendations could not be computed, or the command failed.

  Operator authority is decided before this module runs: `Coordinator.Policy`
  refuses the kind for a machine turn.
  """

  alias ForemanServer.Coordinator.{Action, Dispatch}
  alias ForemanServer.Projects.Recommendations

  @type outcome :: {String.t(), term(), map() | nil, non_neg_integer()}

  @doc "Run one `apply_recommendation` action for the turn's project."
  @spec handle(Action.t(), %{required(:project_id) => String.t(), required(:gateway) => module()}) ::
          outcome()
  def handle(%Action{id: action_id, params: %{"recommendation_id" => id}}, %{
        project_id: project_id,
        gateway: gateway
      }) do
    with {:ok, recommendations} <- recommend(project_id),
         {:ok, fix} <- appliable_fix(recommendations, id),
         {:ok, command} <- command(fix, project_id, action_id),
         {:ok, _event} <- dispatch(gateway, command) do
      {"executed", nil, %{"recommendation_id" => id, "command" => fix.type}, 0}
    else
      {:rejected, reason} -> {"rejected", reason, nil, 0}
      {:failed, reason} -> {"failed", reason, nil, 0}
    end
  end

  defp recommend(project_id) do
    case Recommendations.recommend_bounded(project_id) do
      {:ok, recommendations} ->
        {:ok, recommendations}

      {:error, :project_not_found} ->
        {:rejected, "project_not_found: #{project_id}"}

      {:error, :timeout} ->
        {:failed, "checking the project's setup timed out; ask again in a moment"}
    end
  rescue
    exception ->
      {:failed, "could not check the project's setup: " <> Exception.message(exception)}
  end

  defp appliable_fix(recommendations, id) do
    case Enum.find(recommendations, &(&1.id == id)) do
      nil ->
        {:rejected,
         "recommendation_not_found: #{id} is not a current recommendation for this project " <>
           "(already fixed, stale, or not an id Foreman listed)"}

      recommendation ->
        if Recommendations.applicable?(recommendation),
          do: {:ok, recommendation.fix},
          else:
            {:rejected,
             "not_appliable: #{id} is advice only; Foreman has no command that applies it"}
    end
  end

  # The fix was computed for this project; anything else (another project's id,
  # a command outside the project stream) is never dispatched from here.
  defp command(
         %{type: "project." <> _ = type, payload: %{project_id: project_id} = payload},
         project_id,
         action_id
       ) do
    {:ok,
     %{
       command_id: "coord:recommendation:" <> action_id,
       aggregate_id: "project:" <> project_id,
       type: type,
       payload: payload
     }}
  end

  defp command(%{type: type}, _project_id, _action_id),
    do: {:rejected, "not_appliable: the fix (#{type}) is not a command for this project"}

  defp dispatch(gateway, command) do
    case Dispatch.system(gateway, command) do
      {:ok, _event} = ok ->
        ok

      {:error, {:forbidden_command, type}} ->
        {:rejected, "forbidden_command: #{type} is not a command the coordinator may run"}

      {:error, reason} ->
        {:failed, "apply_failed: " <> inspect(reason, limit: 8)}

      {:error, reason, detail} ->
        {:failed, "apply_failed: " <> inspect({reason, detail}, limit: 8)}
    end
  end
end
