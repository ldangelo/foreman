defmodule ForemanServer.ProjectEnvironmentTest do
  use ExUnit.Case, async: true

  alias ForemanServer.ProjectEnvironment

  defp project(config), do: %{config: config}

  test "legacy config.env resolves with atom and string keys; values are stringified" do
    assert %{env: %{"A" => "1", "B" => "x"}} =
             ProjectEnvironment.resolve("p", project: project(%{env: %{"A" => 1, :B => "x"}}))

    assert %{env: %{"A" => "1"}} =
             ProjectEnvironment.resolve("p", project: project(%{"env" => %{"A" => 1}}))
  end

  test "legacy flat config.environment resolves; a record with a vars key is not mistaken for flat env" do
    assert %{env: %{"FLAT" => "1"}} =
             ProjectEnvironment.resolve("p", project: project(%{environment: %{"FLAT" => "1"}}))

    record = %{"vars" => %{"IN_RECORD" => "yes"}, "network" => %{"mode" => "none", "hosts" => []}}

    assert %{env: env} =
             ProjectEnvironment.resolve("p", project: project(%{"environment" => record}))

    assert env == %{"IN_RECORD" => "yes"}
  end

  test "FOREMAN_* names are dropped, nil values skipped, unknown project is empty" do
    assert %{env: %{"KEEP" => "1"}} =
             ProjectEnvironment.resolve("p",
               project:
                 project(%{env: %{"FOREMAN_RUN_ID" => "evil", "KEEP" => "1", "NIL" => nil}})
             )

    assert %{env: %{}, secrets: []} = ProjectEnvironment.resolve("unknown-project-id-zzz")
  end

  test "secrets list: values of secret-named vars, deduplicated, no empty strings" do
    config = %{
      env: %{"API_TOKEN" => "tok", "OTHER_TOKEN" => "tok", "PASSWORD" => "", "PLAIN" => "x"}
    }

    assert %{secrets: ["tok"]} = ProjectEnvironment.resolve("p", project: project(config))
  end

  test "environment/2 exposes the record with defaults for legacy projects" do
    assert %{
             "vars" => %{"A" => "1"},
             "setup_script" => nil,
             "network" => %{"mode" => "default", "hosts" => []}
           } = ProjectEnvironment.environment("p", project: project(%{env: %{"A" => "1"}}))
  end
end
