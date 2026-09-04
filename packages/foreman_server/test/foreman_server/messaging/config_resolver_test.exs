defmodule ForemanServer.Messaging.ConfigResolverTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Messaging.ConfigResolver

  setup do
    original = Application.get_env(:foreman_server, :messaging)

    Application.put_env(:foreman_server, :messaging,
      enabled: false,
      provider: :telegram,
      telegram: [token: {:system, "APP_TOKEN"}, chat_id: "app-chat"],
      slack: [webhook_url: {:system, "APP_WEBHOOK"}]
    )

    on_exit(fn ->
      if is_nil(original),
        do: Application.delete_env(:foreman_server, :messaging),
        else: Application.put_env(:foreman_server, :messaging, original)
    end)
  end

  test "workflow settings override project and app defaults" do
    assert {:ok, config} =
             ConfigResolver.resolve(
               project_config: %{
                 notifications: %{
                   enabled: true,
                   provider: :slack,
                   slack: %{webhook_url: {:system, "PROJECT_WEBHOOK"}}
                 }
               },
               workflow_config: %{
                 notifications: %{
                   provider: :telegram,
                   telegram: %{token: {:system, "WORKFLOW_TOKEN"}, chat_id: "workflow-chat"}
                 }
               }
             )

    assert config.enabled? == true
    assert config.provider == :telegram
    assert config.destination.chat_id == "workflow-chat"
  end

  test "disabled event classes suppress provider delivery" do
    assert {:ok, config} =
             ConfigResolver.resolve(
               workflow_config: %{notifications: %{event_classes: [:failure]}}
             )

    refute ConfigResolver.enabled_for?(config, :run_update)
    assert ConfigResolver.enabled_for?(config, :failure)
  end

  test "malformed selected destination returns typed error and does not fall back" do
    assert {:error, {:missing_or_invalid, :slack_destination}} =
             ConfigResolver.resolve(
               workflow_config: %{notifications: %{provider: :slack, slack: %{webhook_url: ""}}}
             )
  end
end
