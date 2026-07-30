defmodule ForemanServer.ProjectStoreTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{CommandRouter, ProjectStore}
  alias ForemanServer.Project

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "foreman-project-store-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)
      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    assert :ok = Application.start(:foreman_server)
    :ok
  end

  describe "save/2: registers a new project" do
    test "appends ProjectRegistered via CommandRouter and projects via ProjectionStore" do
      project_id = "proj-#{:rand.uniform(999_999)}"

      project = %Project{
        id: project_id,
        path: "/tmp/test-proj-#{project_id}",
        status: :active,
        default_branch: "main",
        config: %{},
        health: %{ok: true}
      }

      assert {:ok, %{event: event}} = ProjectStore.save(project)
      assert event.event_type == "ProjectRegistered"
      assert event.payload.project_id == project_id
      assert event.payload.path == project.path

      result = ProjectStore.get(project_id)
      assert result.project_id == project_id
      assert result.path == project.path
      assert result.status == "active"
      assert result.default_branch == "main"
      assert result.config == %{}
      assert result.updated_at != nil
    end
  end

  describe "save/2: updates an existing project" do
    test "appends ProjectUpdated via CommandRouter when project already exists" do
      project_id = "proj-update-#{:rand.uniform(999_999)}"

      # First: register
      {:ok, _} =
        CommandRouter.handle(%{
          command_id: "init-#{project_id}",
          command_type: "project.register",
          payload: %{
            project_id: project_id,
            path: "/tmp/original",
            status: "active",
            default_branch: "main",
            config: %{},
            health: %{ok: true}
          },
          metadata: %{}
        })

      # Verify initial state
      assert ProjectStore.get(project_id).default_branch == "main"

      # Second: update via ProjectStore.save — default_branch is updatable, path is not
      updated_project = %Project{
        id: project_id,
        path: "/tmp/updated",  # path change won't persist (not in ProjectUpdated handler)
        status: :active,
        default_branch: "develop",
        config: %{key: "value"},
        health: %{ok: true}
      }

      assert {:ok, %{event: event}} = ProjectStore.save(updated_project)
      assert event.event_type == "ProjectUpdated"
      assert event.payload.project_id == project_id

      # default_branch IS updated; path stays original
      assert ProjectStore.get(project_id).default_branch == "develop"
      assert ProjectStore.get(project_id).config == %{key: "value"}
    end
  end

  describe "get/1" do
    test "returns nil for unknown project" do
      assert ProjectStore.get("nonexistent-#{:rand.uniform(999_999)}") == nil
    end

    test "returns atom-key project map after registration" do
      project_id = "proj-get-#{:rand.uniform(999_999)}"

      {:ok, _} =
        CommandRouter.handle(%{
          command_id: "init-#{project_id}",
          command_type: "project.register",
          payload: %{
            project_id: project_id,
            path: "/tmp/test",
            status: "active",
            default_branch: "main"
          },
          metadata: %{}
        })

      result = ProjectStore.get(project_id)
      assert is_map(result)
      assert result.project_id == project_id
      assert result.path == "/tmp/test"
    end
  end

  describe "list/0" do
    test "returns all registered projects sorted by project_id" do
      id1 = "proj-list-a-#{:rand.uniform(999_999)}"
      id2 = "proj-list-b-#{:rand.uniform(999_999)}"

      for id <- [id1, id2] do
        CommandRouter.handle(%{
          command_id: "init-#{id}",
          command_type: "project.register",
          payload: %{
            project_id: id,
            path: "/tmp/#{id}",
            status: "active",
            default_branch: "main"
          },
          metadata: %{}
        })
      end

      listed = ProjectStore.list()
      ids = Enum.map(listed, & &1.project_id)

      assert id1 in ids
      assert id2 in ids
      # Sorted
      assert ids == Enum.sort(ids)
    end
  end
end
