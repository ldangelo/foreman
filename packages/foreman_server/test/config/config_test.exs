defmodule ForemanServer.BaseConfigTest do
  use ExUnit.Case, async: false

  @config_path Path.expand("../../config/config.exs", __DIR__)
  @expected_task_provider [
    actor: nil,
    accepted_contract_versions: ["br.capabilities.v1", "kata.capabilities.v1"],
    accepted_kata_versions: [">= 0.19.0"],
    providers: [
      ForemanServer.TaskProviders.BeadsAdapter,
      ForemanServer.TaskProviders.KataAdapter
    ]
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

  test ":accepted_contract_versions contains 'kata.capabilities.v1' next to the br contract" do
    versions = Application.get_env(:foreman_server, :task_provider)[:accepted_contract_versions]

    assert "kata.capabilities.v1" in versions
    assert "br.capabilities.v1" in versions
  end

  test "providers list contains KataAdapter" do
    assert ForemanServer.TaskProviders.KataAdapter in Application.get_env(
             :foreman_server,
             :task_provider
           )[:providers]
  end

  test ":accepted_kata_versions entries are Version requirements, apart from the contract list" do
    task_provider = Application.get_env(:foreman_server, :task_provider)
    requirements = task_provider[:accepted_kata_versions]

    assert [_ | _] = requirements
    assert Enum.all?(requirements, &is_binary/1)
    assert Enum.all?(requirements, &match?({:ok, _}, Version.parse_requirement(&1)))
    refute Enum.any?(requirements, &(&1 in task_provider[:accepted_contract_versions]))
  end
end
