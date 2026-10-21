defmodule ForemanServer.Aggregates.ProjectRepositoriesTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.Project
  alias ForemanServer.Events.{ProjectRepositoryAdded, ProjectRepositoryRemoved}

  defp state(events \\ []) do
    Enum.reduce(
      [%{event_type: "ProjectRegistered", payload: %{project_id: "p", path: "/srv/primary"}}] ++
        events,
      Project.initial_state(),
      &Project.apply_event(&2, &1)
    )
  end

  defp add(state, overrides \\ %{}) do
    payload =
      Map.merge(
        %{project_id: "p", repo_id: "api", path: "/srv/api", added_by: "operator:alice"},
        overrides
      )

    Project.handle_command(state, %{type: "project.repo.add", payload: payload})
  end

  defp added(repo_id, path),
    do: %{
      event_type: "ProjectRepositoryAdded",
      payload: %ProjectRepositoryAdded{
        project_id: "p",
        repo_id: repo_id,
        path: path,
        added_by: "operator:alice",
        at: "2026-01-01T00:00:00Z"
      }
    }

  defp remove(state, repo_id) do
    Project.handle_command(state, %{
      type: "project.repo.remove",
      payload: %{project_id: "p", repo_id: repo_id, removed_by: "operator:alice"}
    })
  end

  describe "project.repo.add" do
    test "emits ProjectRepositoryAdded with nil default_branch (never defaulted to main)" do
      assert {:ok, %{stream_id: "project:p", event_type: "ProjectRepositoryAdded"} = spec} =
               add(state())

      assert %ProjectRepositoryAdded{
               repo_id: "api",
               path: "/srv/api",
               default_branch: nil,
               task_provider: nil,
               vcs: %{adapter: "git"},
               added_by: "operator:alice"
             } = spec.payload

      assert is_binary(spec.payload.at)
    end

    test "keeps an explicit default_branch" do
      assert {:ok, %{payload: %{default_branch: "develop"}}} =
               add(state(), %{default_branch: "develop"})
    end

    test "rejects invalid ids" do
      for bad <- ["", "API", "-x", "a_b", String.duplicate("a", 33), nil, 5] do
        assert {:error, {:invalid_repo_id, ^bad}} = add(state(), %{repo_id: bad})
      end
    end

    test "rejects the reserved synthesised id and a taken id" do
      assert {:error, {:repo_id_taken, "main"}} = add(state(), %{repo_id: "main"})

      s = state([added("api", "/srv/api")])
      assert {:error, {:repo_id_taken, "api"}} = add(s, %{path: "/srv/other"})
    end

    test "rejects relative paths and paths equal to the primary or another repo" do
      assert {:error, {:repo_path_not_absolute, "rel/x"}} = add(state(), %{path: "rel/x"})

      assert {:error, {:repo_path_duplicate, "/srv/primary"}} =
               add(state(), %{path: "/srv/primary"})

      s = state([added("api", "/srv/api")])

      assert {:error, {:repo_path_duplicate, "/srv/api/"}} =
               add(s, %{repo_id: "b", path: "/srv/api/"})
    end

    test "rejects unknown keys, a non-nil task_provider, other vcs, bad default_branch" do
      assert {:error, {:unknown_repo_keys, ["pr"]}} = add(state(), %{pr: %{draft: true}})

      assert {:error, {:repo_task_provider_unsupported, "api"}} =
               add(state(), %{task_provider: %{provider: "x"}})

      assert {:error, {:unsupported_repo_vcs, %{adapter: "hg"}}} =
               add(state(), %{vcs: %{adapter: "hg"}})

      assert {:error, {:invalid_default_branch, ""}} = add(state(), %{default_branch: ""})
    end

    test "requires added_by, an existing and non-archived project" do
      assert {:error, {:missing_or_invalid, :added_by}} = add(state(), %{added_by: nil})
      assert {:error, {:not_found, :project, "p"}} = add(Project.initial_state())

      archived = state([%{event_type: "ProjectArchived", payload: %{}}])
      assert {:error, {:project_archived, "p"}} = add(archived)
    end
  end

  describe "project.repo.remove" do
    test "emits ProjectRepositoryRemoved and drops the entry from state" do
      s = state([added("api", "/srv/api")])

      assert {:ok, %{event_type: "ProjectRepositoryRemoved", payload: event}} = remove(s, "api")
      assert %ProjectRepositoryRemoved{repo_id: "api", removed_by: "operator:alice"} = event

      after_remove =
        Project.apply_event(s, %{event_type: "ProjectRepositoryRemoved", payload: event})

      assert after_remove.repositories == []
      assert {:ok, _} = add(after_remove)
    end

    test "unknown id, the synthesised primary, and active runs are refused" do
      s = state([added("api", "/srv/api")])
      assert {:error, {:repo_not_found, "zzz"}} = remove(s, "zzz")
      assert {:error, :primary_repo_not_removable} = remove(s, "main")

      reserved =
        Project.apply_event(s, %{
          event_type: "ProjectRunReserved",
          payload: %{project_id: "p", run_id: "r1", sequence: 1, command_id: "c"}
        })

      assert {:error, :project_has_active_runs} = remove(reserved, "api")
    end
  end

  describe "project.update path" do
    defp update(state, path),
      do:
        Project.handle_command(state, %{
          type: "project.update",
          payload: %{project_id: "p", path: path}
        })

    test "ProjectUpdated(path) moves State.path so later adds compare against the new primary" do
      moved =
        Project.apply_event(state(), %{
          event_type: "ProjectUpdated",
          payload: %{project_id: "p", path: "/srv/moved"}
        })

      assert moved.path == "/srv/moved"
      assert {:error, {:repo_path_duplicate, "/srv/moved"}} = add(moved, %{path: "/srv/moved"})
      assert {:ok, _} = add(moved, %{path: "/srv/primary"})
    end

    test "an update without a path leaves State.path alone" do
      s =
        Project.apply_event(state(), %{event_type: "ProjectUpdated", payload: %{project_id: "p"}})

      assert s.path == "/srv/primary"
    end

    test "pure guards: absolute and not an attached repo's checkout" do
      s = state([added("api", "/srv/api")])
      assert {:error, {:repo_path_not_absolute, "rel"}} = update(s, "rel")
      assert {:error, {:repo_path_duplicate, "/srv/api"}} = update(s, "/srv/api")
      assert {:ok, %{event_type: "ProjectUpdated"}} = update(s, "/srv/elsewhere")
      assert {:ok, %{event_type: "ProjectUpdated"}} = update(s, "/srv/primary")
    end
  end
end
