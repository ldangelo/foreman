defmodule ForemanServer.Aggregates.ProjectTaskProviderUpdateTest do
  @moduledoc """
  `foreman project update --task-provider <p>` sends `task_provider: {provider: <p>}` and, by design,
  no `config` (an update has no `--path`). Replacing the stored block with that would drop the
  stored binding (`cwd` or `database_path`) and leave the project unroutable with no CLI repair.

  Before this change `put_task_provider/2` replaced the stored block wholesale
  (`aggregates/project.ex`, `ProjectUpdated` fold) and `ProjectionStore` did the same
  (`projection_store.ex`, `maybe_put(:task_provider, ...)`). Now the aggregate resolves the block
  at command time, so the emitted `ProjectUpdated` is self-contained for every consumer:

    * the same provider and no `config`: the stored `config` is kept;
    * a different provider (or none stored) whose storage scheme needs a key the request lacks:
      `{:error, {:missing_or_invalid, key}}` names it; nothing is invented.

  Every rule is stated over `capabilities[:storage_scheme]`; the two real adapters are fixtures.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.Project
  alias ForemanServer.CommandGateway
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TaskProvider.ProjectProviderProjector
  alias ForemanServer.TaskProvider.Registry
  alias ForemanServer.TaskProviders.BeadsAdapter
  alias ForemanServer.TaskProviders.KataAdapter
  alias ForemanServer.Test.Support.CapabilityStubProvider

  @cwd "/work/kata-project"
  @database_path "/abs/beads/project.db"

  setup do
    previous = Application.get_env(:foreman_server, :task_provider, [])

    Application.put_env(
      :foreman_server,
      :task_provider,
      Keyword.put(previous, :providers, [BeadsAdapter, KataAdapter])
    )

    on_exit(fn -> Application.put_env(:foreman_server, :task_provider, previous) end)

    :ok
  end

  describe "an update that restates the provider keeps the stored binding" do
    test "a :cli_process project keeps its cwd in the event and in the folded state" do
      state = registered(%{provider: "kata", config: %{cwd: @cwd}})

      assert {:ok, event} = update(state, %{provider: "kata"})

      assert event.payload.task_provider == %{provider: "kata", config: %{cwd: @cwd}}
      assert event.payload.config.task_provider == event.payload.task_provider

      updated = Project.apply_event(state, event)
      assert updated.task_provider == %{provider: "kata", config: %{cwd: @cwd}}
      assert updated.config.task_provider == updated.task_provider
    end

    test "a :sqlite project keeps its database_path the same way" do
      state = registered(%{provider: "beads", config: %{database_path: @database_path}})

      assert {:ok, event} = update(state, %{provider: "beads"})

      assert event.payload.task_provider ==
               %{provider: "beads", config: %{database_path: @database_path}}
    end

    test "under the string keys JSON ingress produces, the stored block is kept under string keys" do
      state = registered(%{"provider" => "kata", "config" => %{"cwd" => @cwd}})

      assert {:ok, event} = update(state, %{"provider" => "kata"})

      assert event.payload.task_provider == %{"provider" => "kata", "config" => %{"cwd" => @cwd}}
    end

    test "however the request spells the provider" do
      state = registered(%{provider: "kata", config: %{cwd: @cwd}})

      for spelling <- [:kata, KataAdapter, "ForemanServer.TaskProviders.KataAdapter"] do
        assert {:ok, event} = update(state, %{provider: spelling})
        assert event.payload.task_provider.config == %{cwd: @cwd}
      end
    end

    test "an update that carries a config still replaces the block atomically" do
      state = registered(%{provider: "kata", config: %{cwd: @cwd, extra: 1}})

      assert {:ok, event} = update(state, %{provider: "kata", config: %{cwd: "/work/other"}})

      assert Project.apply_event(state, event).task_provider ==
               %{provider: "kata", config: %{cwd: "/work/other"}}
    end

    test "an update with no task_provider at all leaves the binding alone" do
      state = registered(%{provider: "kata", config: %{cwd: @cwd}})

      assert {:ok, event} =
               Project.handle_command(state, %{
                 type: "project.update",
                 payload: %{project_id: "project-1", name: "Renamed"}
               })

      assert Project.apply_event(state, event).task_provider ==
               %{provider: "kata", config: %{cwd: @cwd}}
    end
  end

  describe "a different provider must bring the key its storage scheme needs" do
    test "switching to a :cli_process provider without a cwd is refused, naming cwd" do
      state = registered(%{provider: "beads", config: %{database_path: @database_path}})

      assert {:error, {:missing_or_invalid, :cwd}} = update(state, %{provider: "kata"})

      assert {:error, {:missing_or_invalid, :cwd}} =
               update(state, %{provider: "kata", config: %{database_path: @database_path}})
    end

    test "switching to a :sqlite provider without a database_path is refused, naming database_path" do
      state = registered(%{provider: "kata", config: %{cwd: @cwd}})

      assert {:error, {:missing_or_invalid, :database_path}} =
               update(state, %{provider: "beads"})
    end

    test "a switch that brings its key is accepted as asked" do
      state = registered(%{provider: "beads", config: %{database_path: @database_path}})

      assert {:ok, event} = update(state, %{provider: "kata", config: %{cwd: @cwd}})

      assert Project.apply_event(state, event).task_provider ==
               %{provider: "kata", config: %{cwd: @cwd}}
    end

    test "a project with no provider yet is not 'unchanged'" do
      state = %{
        Project.initial_state()
        | exists?: true,
          project_id: "project-1",
          status: "active"
      }

      assert {:error, {:missing_or_invalid, :cwd}} = update(state, %{provider: "kata"})
      assert {:ok, _event} = update(state, %{provider: "kata", config: %{cwd: @cwd}})
    end

    test "a provider nobody can resolve is stored as asked: the projector reports it unroutable" do
      state = registered(%{provider: "kata", config: %{cwd: @cwd}})

      assert {:ok, event} = update(state, %{provider: "nonexistent"})
      assert event.payload.task_provider == %{provider: "nonexistent"}
    end
  end

  describe "the restated update keeps the project routable end to end" do
    test "aggregate -> ProjectUpdated -> projector -> registry still routes the project by its cwd" do
      cwd = Path.join(System.tmp_dir!(), "update_routable_#{System.unique_integer([:positive])}")
      File.mkdir_p!(cwd)
      on_exit(fn -> File.rm_rf!(cwd) end)

      cli =
        CapabilityStubProvider.define!(
          name: :cli_stub,
          capabilities: %{
            provider_id: :cli_stub,
            contract_version: "br.capabilities.v1",
            supports: [:claim],
            storage_scheme: :cli_process
          }
        )

      Application.put_env(:foreman_server, :task_provider,
        actor: nil,
        accepted_contract_versions: ["br.capabilities.v1"],
        providers: [cli]
      )

      ForemanServer.TestSupport.TestApplication.reset_application_child!(Registry)

      state = registered(%{provider: cli, config: %{cwd: cwd}})
      assert {:ok, event} = update(state, %{provider: cli})

      assert :ok =
               ProjectProviderProjector.process_event(%{
                 event_type: "ProjectUpdated",
                 payload: event.payload
               })

      assert {:ok, ^cli} = Registry.route(:claim, {"project-1", cwd})
    end
  end

  describe "through the command path an operator uses (string-keyed JSON body)" do
    test "restating a project's provider keeps its cwd in the projection; a switch without its key is a typed error" do
      project_id = "proj-update-#{Elixir.EventStore.UUID.uuid4()}"

      assert {:ok, _} =
               dispatch(project_id, "project.register", %{
                 "project_id" => project_id,
                 "path" => System.tmp_dir!(),
                 "task_provider" => %{"provider" => "kata", "config" => %{"cwd" => @cwd}}
               })

      assert {:ok, _} =
               dispatch(project_id, "project.update", %{
                 "project_id" => project_id,
                 "task_provider" => %{"provider" => "kata"}
               })

      assert %{task_provider: %{"provider" => "kata", "config" => %{"cwd" => @cwd}}} =
               ProjectionStore.project_projection(project_id)

      assert {:error, {:missing_or_invalid, :database_path}} =
               dispatch(project_id, "project.update", %{
                 "project_id" => project_id,
                 "task_provider" => %{"provider" => "beads"}
               })

      # The refused switch left the binding alone.
      assert %{task_provider: %{"provider" => "kata", "config" => %{"cwd" => @cwd}}} =
               ProjectionStore.project_projection(project_id)
    end
  end

  defp registered(task_provider) do
    assert {:ok, event} =
             Project.handle_command(Project.initial_state(), %{
               type: "project.register",
               payload: %{
                 project_id: "project-1",
                 path: "/tmp/project-1",
                 task_provider: task_provider
               }
             })

    Project.apply_event(Project.initial_state(), event)
  end

  defp update(state, task_provider) do
    Project.handle_command(state, %{
      type: "project.update",
      payload: %{project_id: "project-1", task_provider: task_provider}
    })
  end

  # The shape `ForemanServerWeb.CommandController` hands the gateway: atom envelope keys, the
  # JSON body's string-keyed payload.
  defp dispatch(project_id, type, payload) do
    CommandGateway.dispatch_operator(%{
      type: type,
      command_id: "#{type}:#{project_id}:#{System.unique_integer([:positive])}",
      aggregate_id: "project:#{project_id}",
      payload: payload
    })
  end
end
