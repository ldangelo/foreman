defmodule ForemanServer.ProjectEnvironmentSetTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.Project.Environment
  alias ForemanServer.{CommandGateway, CommandRouter, ProjectEnvironment, ProjectionStore}

  describe "Environment.normalize/1" do
    test "defaults, string keys and stringified scalar values" do
      assert {:ok,
              %{
                "vars" => %{},
                "setup_script" => nil,
                "network" => %{"mode" => "default", "hosts" => []}
              }} =
               Environment.normalize(%{})

      assert {:ok, %{"vars" => %{"A" => "1", "B" => "true"}}} =
               Environment.normalize(%{vars: %{A: 1, B: true}})
    end

    test "each rejection is a distinct tuple" do
      assert {:error, {:invalid_env_name, "1bad"}} =
               Environment.normalize(%{vars: %{"1bad" => "x"}})

      assert {:error, {:invalid_env_name, "a-b"}} =
               Environment.normalize(%{vars: %{"a-b" => "x"}})

      assert {:error, {:reserved_env_name, "FOREMAN_RUN_ID"}} =
               Environment.normalize(%{vars: %{"FOREMAN_RUN_ID" => "x"}})

      assert {:error, {:secret_in_vars, "GITHUB_TOKEN"}} =
               Environment.normalize(%{vars: %{"GITHUB_TOKEN" => "x"}})

      assert {:error, {:secret_in_vars, "db_password"}} =
               Environment.normalize(%{vars: %{"db_password" => "x"}})

      assert {:error, {:env_value_invalid, "A"}} =
               Environment.normalize(%{vars: %{"A" => %{"n" => 1}}})

      assert {:error, {:env_value_too_long, "A"}} =
               Environment.normalize(%{vars: %{"A" => String.duplicate("x", 8193)}})

      assert {:ok, _} = Environment.normalize(%{vars: %{"A" => String.duplicate("x", 8192)}})

      too_many = Map.new(1..101, &{"V#{&1}", "x"})
      assert {:error, {:too_many_env_vars, 101}} = Environment.normalize(%{vars: too_many})

      assert {:error, {:setup_script_too_long, _}} =
               Environment.normalize(%{setup_script: String.duplicate("x", 16 * 1024 + 1)})

      assert {:error, {:setup_script_invalid, 5}} = Environment.normalize(%{setup_script: 5})

      assert {:error, {:invalid_network_mode, "open"}} =
               Environment.normalize(%{network: %{mode: "open"}})

      assert {:error, {:invalid_network_host, "Bad Host"}} =
               Environment.normalize(%{network: %{mode: "allowlist", hosts: ["Bad Host"]}})

      assert {:error, {:too_many_network_hosts, 101}} =
               Environment.normalize(%{network: %{hosts: Enum.map(1..101, &"h#{&1}.example")}})

      assert {:error, {:unknown_environment_key, "env"}} = Environment.normalize(%{"env" => %{}})
    end

    test "blank script clears, hosts are de-duplicated" do
      assert {:ok, %{"setup_script" => nil}} = Environment.normalize(%{setup_script: "  \n"})

      assert {:ok, %{"network" => %{"hosts" => ["a.example", "*.b.example"]}}} =
               Environment.normalize(%{
                 network: %{mode: "allowlist", hosts: ["a.example", "*.b.example", "a.example"]}
               })
    end
  end

  describe "project.environment.set" do
    setup do
      project_id = "project-#{Elixir.EventStore.UUID.uuid4()}"
      %{project_id: project_id}
    end

    defp register(id, config \\ %{}) do
      {:ok, _} =
        CommandRouter.dispatch(%{
          type: "project.register",
          payload: %{project_id: id, path: "/tmp/#{id}", config: config},
          aggregate_id: "project:#{id}"
        })
    end

    defp set_env(id, payload) do
      CommandRouter.dispatch(%{
        type: "project.environment.set",
        payload: Map.put(payload, :project_id, id),
        aggregate_id: "project:#{id}"
      })
    end

    test "stores the record in config and resolve reads it", %{project_id: id} do
      register(id)

      assert {:ok, _} =
               set_env(id, %{
                 vars: %{"NPM_REGISTRY" => "https://r.example"},
                 setup_script: "npm ci",
                 network: %{mode: "allowlist", hosts: ["api.example.com"]}
               })

      assert %{"environment" => %{"setup_script" => "npm ci"}} =
               ProjectionStore.project(id).config

      assert %{
               "vars" => %{"NPM_REGISTRY" => "https://r.example"},
               "setup_script" => "npm ci",
               "network" => %{"mode" => "allowlist", "hosts" => ["api.example.com"]}
             } = ProjectEnvironment.environment(id)
    end

    test "keys absent from the payload keep their value; nil clears the script", %{project_id: id} do
      register(id)
      {:ok, _} = set_env(id, %{vars: %{"A" => "1"}, setup_script: "make"})
      {:ok, _} = set_env(id, %{network: %{mode: "none"}})

      assert %{
               "vars" => %{"A" => "1"},
               "setup_script" => "make",
               "network" => %{"mode" => "none"}
             } =
               ProjectEnvironment.environment(id)

      {:ok, _} = set_env(id, %{setup_script: nil})

      assert %{"setup_script" => nil, "vars" => %{"A" => "1"}} =
               ProjectEnvironment.environment(id)
    end

    test "legacy flat config.env is ported into vars on first set", %{project_id: id} do
      register(id, %{env: %{"LEGACY" => "1"}})
      {:ok, _} = set_env(id, %{setup_script: "make"})

      assert %{"vars" => %{"LEGACY" => "1"}, "setup_script" => "make"} =
               ProjectEnvironment.environment(id)
    end

    test "a secret-looking var is rejected and nothing is stored", %{project_id: id} do
      register(id)

      assert {:error, {:secret_in_vars, "API_TOKEN"}} =
               set_env(id, %{vars: %{"API_TOKEN" => "x"}})

      refute Map.has_key?(ProjectionStore.project(id).config, "environment")
    end

    test "unknown project is not_found", %{project_id: id} do
      assert {:error, {:not_found, :project, ^id}} = set_env(id, %{vars: %{}})
    end

    test "project.update and project.register cannot write the environment key", %{project_id: id} do
      register(id)

      for config <- [
            %{environment: %{setup_script: "rm -rf /"}},
            %{"environment" => %{"setup_script" => "x"}}
          ] do
        assert {:error, {:setting_not_editable, :environment}} =
                 CommandRouter.dispatch(%{
                   type: "project.update",
                   payload: %{project_id: id, config: config},
                   aggregate_id: "project:#{id}"
                 })
      end

      assert {:error, {:setting_not_editable, :environment}} =
               CommandRouter.dispatch(%{
                 type: "project.register",
                 payload: %{
                   project_id: "other-#{id}",
                   path: "/tmp/x",
                   config: %{environment: %{setup_script: "x"}}
                 },
                 aggregate_id: "project:other-#{id}"
               })

      refute Map.has_key?(ProjectionStore.project(id).config, "environment")
    end

    test "the operator gateway accepts the command", %{project_id: id} do
      register(id)

      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 type: "project.environment.set",
                 command_id: "env-#{id}",
                 aggregate_id: "project:#{id}",
                 payload: %{project_id: id, vars: %{"A" => "1"}}
               })

      assert %{"vars" => %{"A" => "1"}} = ProjectEnvironment.environment(id)
    end
  end
end
