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
               workflow_config: %{notifications: %{enabled: true, event_classes: [:failure]}}
             )

    refute ConfigResolver.enabled_for?(config, :run_update)
    assert ConfigResolver.enabled_for?(config, :failure)
  end

  test "malformed selected destination returns typed error and does not fall back" do
    assert {:error, {:invalid_field, :slack_destination, :webhook_url, ""}} =
             ConfigResolver.resolve(
               workflow_config: %{
                 notifications: %{enabled: true, provider: :slack, slack: %{webhook_url: ""}}
               }
             )
  end

  test "absent destination field is reported distinctly from a malformed one" do
    assert {:error, {:missing_field, :slack_destination, :webhook_url}} =
             ConfigResolver.resolve(
               workflow_config: %{
                 notifications: %{enabled: true, provider: :slack, slack: %{}}
               }
             )
  end

  describe "a literal Slack webhook URL is held to the generic webhook's rules" do
    defp resolve_slack(url) do
      ConfigResolver.resolve(
        workflow_config: %{
          notifications: %{enabled: true, provider: :slack, slack: %{webhook_url: url}}
        }
      )
    end

    test "an https public URL and a {:system, env} reference resolve" do
      assert {:ok, %{destination: %{webhook_url: "https://hooks.slack.com/services/T/B/C"}}} =
               resolve_slack("https://hooks.slack.com/services/T/B/C")

      assert {:ok, %{destination: %{webhook_url: {:system, "SLACK_URL"}}}} =
               resolve_slack({:system, "SLACK_URL"})
    end

    test "http, userinfo, a private host and a non-URL are refused without echoing the URL" do
      assert {:error, {:unsafe_url, :slack_destination, :insecure_http}} =
               resolve_slack("http://hooks.slack.com/services/T/B/SECRET")

      assert {:error, {:unsafe_url, :slack_destination, :userinfo}} =
               resolve_slack("https://u:p@hooks.slack.com/services/T/B/SECRET")

      assert {:error, {:unsafe_url, :slack_destination, :private_host}} =
               resolve_slack("https://127.0.0.1/services/T/B/SECRET")

      assert {:error, {:invalid_field, :slack_destination, :webhook_url} = error} =
               resolve_slack("hooks.slack.com/services/T/B/SECRET")

      refute inspect(error) =~ "SECRET"
    end
  end

  test "string-keyed project overrides are not silently discarded by defaults" do
    assert {:ok, config} =
             ConfigResolver.resolve(
               project_config: %{
                 "notifications" => %{
                   "enabled" => true,
                   "provider" => "slack",
                   "slack" => %{"webhook_url" => {:system, "PROJECT_WEBHOOK"}}
                 }
               }
             )

    assert config.enabled? == true
    assert config.provider == :slack
  end

  test "malformed enabled value fails loudly instead of silently disabling" do
    assert {:error, {:missing_or_invalid, :enabled, "yes"}} =
             ConfigResolver.resolve(workflow_config: %{notifications: %{enabled: "yes"}})
  end

  test "a non-map, non-keyword-list provider value is a typed invalid-field error, not an empty config" do
    assert {:error, {:invalid_field, :slack_destination, :slack, "not-a-config"}} =
             ConfigResolver.resolve(
               workflow_config: %{
                 notifications: %{enabled: true, provider: :slack, slack: "not-a-config"}
               }
             )
  end

  test "a non-keyword list provider value is a typed invalid-field error, not a crash" do
    assert {:error, {:invalid_field, :slack_destination, :slack, ["not-a-config"]}} =
             ConfigResolver.resolve(
               workflow_config: %{
                 notifications: %{enabled: true, provider: :slack, slack: ["not-a-config"]}
               }
             )
  end

  test "conflicting atom/string destination field keys raise instead of silently preferring one" do
    assert_raise ArgumentError, ~r/conflicting atom\/string keys for :webhook_url/, fn ->
      ConfigResolver.resolve(
        workflow_config: %{
          notifications: %{
            enabled: true,
            provider: :slack,
            slack: %{
              :webhook_url => {:system, "ATOM_WEBHOOK"},
              "webhook_url" => {:system, "STRING_WEBHOOK"}
            }
          }
        }
      )
    end
  end
end
