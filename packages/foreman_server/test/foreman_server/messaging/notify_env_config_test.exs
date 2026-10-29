defmodule ForemanServer.Messaging.NotifyEnvConfigTest do
  # `config/runtime.exs`: the FOREMAN_NOTIFY_* variables that select the one outbound
  # notification provider. `runtime.exs` leaves the test env alone, so it is evaluated as
  # `:prod`, reading the variables at call time (same pattern as `TickerEnvConfigTest`).
  use ExUnit.Case, async: false

  alias ForemanServer.Messaging.ConfigResolver

  @runtime Path.expand("../../../config/runtime.exs", __DIR__)

  @vars ~w(
    FOREMAN_NOTIFY_WEBHOOK_URL
    FOREMAN_NOTIFY_WEBHOOK_ALLOW_INSECURE_HTTP
    FOREMAN_NOTIFY_WEBHOOK_ALLOW_PRIVATE_HOSTS
    FOREMAN_NOTIFY_TELEGRAM_BOT_TOKEN
    FOREMAN_NOTIFY_TELEGRAM_CHAT_ID
    FOREMAN_NOTIFY_SLACK_WEBHOOK_URL
  )

  @token "123456:abcdefghijklmnopqrstuvwxyzABCDE"
  @slack_url "https://hooks.slack.com/services/T000/B000/ENVSECRET"

  setup do
    original = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)

    on_exit(fn ->
      for {name, value} <- original do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end)
  end

  defp messaging(env) do
    for {name, value} <- env, do: System.put_env(name, value)

    @runtime
    |> Config.Reader.read!(env: :prod)
    |> get_in([:foreman_server, :messaging])
  end

  test "none set changes nothing" do
    assert messaging([]) == nil
  end

  test "empty values count as unset" do
    assert messaging([
             {"FOREMAN_NOTIFY_WEBHOOK_URL", ""},
             {"FOREMAN_NOTIFY_TELEGRAM_BOT_TOKEN", ""},
             {"FOREMAN_NOTIFY_TELEGRAM_CHAT_ID", ""},
             {"FOREMAN_NOTIFY_SLACK_WEBHOOK_URL", ""}
           ]) == nil
  end

  test "telegram: both variables select the provider and enable every event class" do
    config =
      messaging([
        {"FOREMAN_NOTIFY_TELEGRAM_BOT_TOKEN", @token},
        {"FOREMAN_NOTIFY_TELEGRAM_CHAT_ID", "-1001234"}
      ])

    assert config[:enabled] == true
    assert config[:provider] == :telegram
    assert config[:run_update_rate_limit_ms] == 0
    assert :failure in config[:event_classes]
    assert config[:telegram] == %{token: @token, chat_id: "-1001234"}

    # What a node boots with is a config the resolver accepts.
    assert {:ok, %{provider: :telegram, destination: %{token: @token, chat_id: "-1001234"}}} =
             resolve(config)
  end

  test "telegram: one variable without the other aborts boot, naming variables not values" do
    for env <- [
          [{"FOREMAN_NOTIFY_TELEGRAM_BOT_TOKEN", @token}],
          [{"FOREMAN_NOTIFY_TELEGRAM_CHAT_ID", "-1001234"}]
        ] do
      Enum.each(@vars, &System.delete_env/1)
      error = assert_raise RuntimeError, fn -> messaging(env) end

      assert error.message =~ "FOREMAN_NOTIFY_TELEGRAM_BOT_TOKEN"
      assert error.message =~ "FOREMAN_NOTIFY_TELEGRAM_CHAT_ID"
      refute error.message =~ @token
      refute error.message =~ "-1001234"
    end
  end

  test "slack: the URL selects the provider" do
    config = messaging([{"FOREMAN_NOTIFY_SLACK_WEBHOOK_URL", @slack_url}])

    assert config[:enabled] == true
    assert config[:provider] == :slack
    assert config[:run_update_rate_limit_ms] == 0
    assert config[:slack] == %{webhook_url: @slack_url}

    assert {:ok, %{provider: :slack, destination: %{webhook_url: @slack_url}}} = resolve(config)
  end

  test "slack: an unsafe URL is accepted by the env but refused by the resolver, without echoing it" do
    for url <- [
          "http://hooks.slack.com/services/T/B/ENVSECRET",
          "https://127.0.0.1/services/T/B/ENVSECRET",
          "https://u:p@hooks.slack.com/services/T/B/ENVSECRET"
        ] do
      Enum.each(@vars, &System.delete_env/1)
      config = messaging([{"FOREMAN_NOTIFY_SLACK_WEBHOOK_URL", url}])

      assert {:error, {:unsafe_url, :slack_destination, _reason} = error} = resolve(config)
      refute inspect(error) =~ "ENVSECRET"
    end
  end

  test "webhook: the existing variables still configure it" do
    config =
      messaging([
        {"FOREMAN_NOTIFY_WEBHOOK_URL", "http://127.0.0.1:9/hook"},
        {"FOREMAN_NOTIFY_WEBHOOK_ALLOW_INSECURE_HTTP", "true"},
        {"FOREMAN_NOTIFY_WEBHOOK_ALLOW_PRIVATE_HOSTS", "yes"}
      ])

    assert config[:provider] == :webhook
    assert config[:enabled] == true
    assert config[:run_update_rate_limit_ms] == 0

    assert config[:webhook] == %{
             url: "http://127.0.0.1:9/hook",
             allow_insecure_http: true,
             allow_private_hosts: false
           }
  end

  test "variables for two providers abort boot instead of picking one, without echoing values" do
    pairs = [
      [
        {"FOREMAN_NOTIFY_WEBHOOK_URL", "https://example.com/ENVSECRET"},
        {"FOREMAN_NOTIFY_SLACK_WEBHOOK_URL", @slack_url}
      ],
      [
        {"FOREMAN_NOTIFY_TELEGRAM_BOT_TOKEN", @token},
        {"FOREMAN_NOTIFY_TELEGRAM_CHAT_ID", "-1001234"},
        {"FOREMAN_NOTIFY_SLACK_WEBHOOK_URL", @slack_url}
      ]
    ]

    for env <- pairs do
      Enum.each(@vars, &System.delete_env/1)
      error = assert_raise RuntimeError, fn -> messaging(env) end

      for {name, _value} <- env, do: assert(error.message =~ name)
      refute error.message =~ "ENVSECRET"
      refute error.message =~ @token
    end
  end

  # The resolver reads `config :foreman_server, :messaging`; hand it the runtime config.
  defp resolve(config) do
    original = Application.get_env(:foreman_server, :messaging)
    Application.put_env(:foreman_server, :messaging, config)

    try do
      ConfigResolver.resolve()
    after
      if original,
        do: Application.put_env(:foreman_server, :messaging, original),
        else: Application.delete_env(:foreman_server, :messaging)
    end
  end
end
