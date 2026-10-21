defmodule ForemanServer.ProjectEnvironmentTest do
  use ExUnit.Case, async: true

  alias ForemanServer.ProjectEnvironment

  defp project(config), do: %{config: config}

  test "legacy config.env resolves with atom and string keys; values are stringified" do
    assert {:ok, %{env: %{"A" => "1", "B" => "x"}}} =
             ProjectEnvironment.resolve("p", project: project(%{env: %{"A" => 1, :B => "x"}}))

    assert {:ok, %{env: %{"A" => "1"}}} =
             ProjectEnvironment.resolve("p", project: project(%{"env" => %{"A" => 1}}))
  end

  test "legacy flat config.environment resolves; a record with a vars key is not mistaken for flat env" do
    assert {:ok, %{env: %{"FLAT" => "1"}}} =
             ProjectEnvironment.resolve("p", project: project(%{environment: %{"FLAT" => "1"}}))

    record = %{"vars" => %{"IN_RECORD" => "yes"}, "network" => %{"mode" => "none", "hosts" => []}}

    assert {:ok, %{env: env}} =
             ProjectEnvironment.resolve("p", project: project(%{"environment" => record}))

    assert env == %{"IN_RECORD" => "yes"}
  end

  test "a stored FOREMAN_* name is a loud, typed error naming every offending key" do
    for config <- [
          %{env: %{"FOREMAN_RUN_ID" => "evil", "KEEP" => "1", "FOREMAN_BASE_BRANCH" => "x"}},
          %{"environment" => %{"FOREMAN_RUN_ID" => "evil", "FOREMAN_BASE_BRANCH" => "x"}},
          %{
            "environment" => %{
              "vars" => %{"FOREMAN_RUN_ID" => "evil", "FOREMAN_BASE_BRANCH" => "x"}
            }
          }
        ] do
      assert {:error, {:reserved_project_env_keys, ["FOREMAN_BASE_BRANCH", "FOREMAN_RUN_ID"]}} =
               ProjectEnvironment.resolve("p", project: project(config))
    end
  end

  test "nil values are skipped and an unknown project resolves empty" do
    assert {:ok, %{env: %{"KEEP" => "1"}}} =
             ProjectEnvironment.resolve("p",
               project: project(%{env: %{"KEEP" => "1", "NIL" => nil}})
             )

    assert {:ok, %{env: %{}, secrets: []}} = ProjectEnvironment.resolve("unknown-project-id-zzz")
  end

  test "secrets list: values of secret-named vars, deduplicated, no empty strings" do
    config = %{
      env: %{"API_TOKEN" => "tok", "OTHER_TOKEN" => "tok", "PASSWORD" => "", "PLAIN" => "x"}
    }

    assert {:ok, %{secrets: ["tok"]}} = ProjectEnvironment.resolve("p", project: project(config))
  end

  test "environment/2 exposes the record with defaults for legacy projects" do
    assert %{
             "vars" => %{"A" => "1"},
             "setup_script" => nil,
             "network" => %{"mode" => "default", "hosts" => []}
           } = ProjectEnvironment.environment("p", project: project(%{env: %{"A" => "1"}}))
  end
end
