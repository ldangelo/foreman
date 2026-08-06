defmodule ForemanServer.ConfigTest do
  use ExUnit.Case, async: false

  @config_path Path.expand("../../config/config.exs", __DIR__)
  @expected_task_provider [
    actor: nil,
    accepted_contract_versions: ["br.capabilities.v1"],
    providers: [ForemanServer.TaskProviders.BeadsAdapter]
  ]

  defp load_base_foreman_config! do
    @config_path
    |> Config.Reader.read!(env: :prod)
    |> Keyword.fetch!(:foreman_server)
  end

  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env(app, key, :error), do: Application.delete_env(app, key)

  setup do
    foreman_config = load_base_foreman_config!()
    original_br_runner = Application.fetch_env(:foreman_server, :br_runner)
    original_task_provider = Application.fetch_env(:foreman_server, :task_provider)

    Application.put_env(
      :foreman_server,
      :br_runner,
      Keyword.fetch!(foreman_config, :br_runner)
    )

    Application.put_env(
      :foreman_server,
      :task_provider,
      Keyword.fetch!(foreman_config, :task_provider)
    )

    on_exit(fn ->
      restore_env(:foreman_server, :br_runner, original_br_runner)
      restore_env(:foreman_server, :task_provider, original_task_provider)
    end)

    :ok
  end

  test ":br_runner resolves to SystemBrunner in default (config.exs) env" do
    assert Application.get_env(:foreman_server, :br_runner) ==
             ForemanServer.TaskProviders.SystemBrRunner
  end

  test ":task_provider resolves to the expected map" do
    assert Application.get_env(:foreman_server, :task_provider) == @expected_task_provider
  end

  test ":accepted_contract_versions contains 'br.capabilities.v1'" do
    assert "br.capabilities.v1" in Application.get_env(:foreman_server, :task_provider)[
             :accepted_contract_versions
           ]
  end

  test "providers list contains BeadsAdapter" do
    assert ForemanServer.TaskProviders.BeadsAdapter in Application.get_env(
             :foreman_server,
             :task_provider
           )[:providers]
  end
end
