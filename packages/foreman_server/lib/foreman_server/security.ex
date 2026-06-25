defmodule ForemanServer.Security do
  @moduledoc "Security helpers for remote access controls and destructive-command audit events."

  alias ForemanServer.EventStore

  @destructive_command_types MapSet.new(~w(
    task.block task.close task.update task.add_dependency task.remove_dependency
    run.fail run.reset run.interrupt run.resume worker.interrupt worker.stop
    project.delete task.delete run.cancel reset retry stop merge pr.merge attach.interrupt
  ))

  @spec destructive_command?(String.t()) :: boolean()
  def destructive_command?(command_type) when is_binary(command_type),
    do: MapSet.member?(@destructive_command_types, command_type)

  def destructive_command?(_), do: false

  @spec auth_token() :: String.t() | nil
  def auth_token do
    Application.get_env(:foreman_server, :auth_token) ||
      System.get_env("FOREMAN_SERVER_AUTH_TOKEN")
  end

  @spec remote_auth_required?() :: boolean()
  def remote_auth_required? do
    Application.get_env(:foreman_server, :remote_access_enabled, false) ||
      System.get_env("FOREMAN_SERVER_REMOTE_ACCESS") == "true"
  end

  @spec remote_access_ready?() :: boolean()
  def remote_access_ready?, do: not remote_auth_required?() or token_configured?()

  @spec token_configured?() :: boolean()
  def token_configured? do
    case auth_token() do
      token when is_binary(token) and token != "" -> true
      _ -> false
    end
  end

  @spec append_destructive_audit(map(), String.t(), map()) :: {:ok, [map()]} | {:error, term()}
  def append_destructive_audit(command, event_type, payload) when is_map(command) do
    command_id = Map.fetch!(command, :command_id)
    command_type = Map.fetch!(command, :command_type)
    metadata = Map.get(command, :metadata, %{})
    actor = Map.get(metadata, :actor, Map.get(metadata, :source, "unknown"))
    correlation_id = Map.get(metadata, :correlation_id, command_id)
    target = target_for(payload)

    with {:ok, authorization} <-
           EventStore.append(%{
             stream_id: "audit:#{command_id}",
             event_type: "AuthorizationChecked",
             payload: %{
               command_id: command_id,
               command_type: command_type,
               actor: actor,
               decision: "allowed",
               target: target,
               checked_at: DateTime.utc_now()
             },
             metadata: %{
               correlation_id: correlation_id,
               idempotency_key: "AuthorizationChecked:#{command_id}"
             }
           }),
         {:ok, audit} <-
           EventStore.append(%{
             stream_id: "audit:#{command_id}",
             event_type: "AuditRecorded",
             payload: %{
               command_id: command_id,
               command_type: command_type,
               actor: actor,
               decision: "allowed",
               target: target,
               resulting_event_type: event_type,
               recorded_at: DateTime.utc_now()
             },
             metadata: %{
               correlation_id: correlation_id,
               idempotency_key: "AuditRecorded:#{command_id}"
             }
           }) do
      {:ok, [authorization, audit]}
    end
  end

  defp target_for(payload) do
    Enum.find_value([:task_id, :run_id, :project_id, :worker_id], fn key ->
      value = Map.get(payload, key)
      if is_binary(value) and value != "", do: %{type: key, id: value}
    end) || %{}
  end
end
