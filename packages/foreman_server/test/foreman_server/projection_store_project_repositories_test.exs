defmodule ForemanServer.ProjectionStoreProjectRepositoriesTest do
  @moduledoc """
  Project repositories read model (E12-S1): legacy single-path projects get a
  primary synthesised at READ time; extras come from
  `ProjectRepositoryAdded/Removed`.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.Project
  alias ForemanServer.{CommandRouter, EventStore, ProjectionStore}
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @legacy_log "test/fixtures/foreman_server/legacy_project_log.json"

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    :ok
  end

  defp legacy_events, do: @legacy_log |> File.read!() |> Jason.decode!()

  defp register(id, path),
    do: %{event_type: "ProjectRegistered", payload: %{project_id: id, path: path}}

  defp added(id, repo_id, path, extra \\ %{}) do
    %{
      event_type: "ProjectRepositoryAdded",
      payload:
        Map.merge(
          %{
            project_id: id,
            repo_id: repo_id,
            path: path,
            default_branch: nil,
            vcs: %{adapter: "git"},
            task_provider: nil,
            added_by: "operator:alice",
            at: "2026-01-01T00:00:00Z"
          },
          extra
        )
    }
  end

  describe "legacy log replay (no repository events)" do
    test "synthesises the primary at read time with default_branch nil" do
      assert :ok = ProjectionStore.apply_events(legacy_events())

      assert [
               %{
                 id: "main",
                 path: "/srv/legacy",
                 default_branch: nil,
                 primary: true,
                 vcs: %{adapter: "git"},
                 task_provider: nil,
                 added_by: nil
               }
             ] = ProjectionStore.project_repositories("legacy-1")

      assert ProjectionStore.project_primary_repo_id("legacy-1") == "main"

      assert %{id: "main", path: "/srv/legacy"} =
               ProjectionStore.project_repository("legacy-1", "main")

      assert ProjectionStore.project_repository("legacy-1", "nope") == nil
    end

    test "the legacy aggregate stream replays with no repositories" do
      state =
        Enum.reduce(legacy_events(), Project.initial_state(), fn event, acc ->
          if event["event_type"] in ["ProjectRegistered", "ProjectUpdated"],
            do:
              Project.apply_event(acc, %{
                event_type: event["event_type"],
                payload: event["payload"]
              }),
            else: acc
        end)

      assert state.path == "/srv/legacy"
      assert state.repositories == []
    end

    test "legacy worktree events replay as the primary (no repo_id)" do
      assert :ok = ProjectionStore.apply_events(legacy_events())

      assert [%{repo_id: nil, primary?: true}] =
               ProjectionStore.worktrees_for_run("run-0123456789abcdef0123456789abcdef")
    end

    test "unknown project is nil / nil" do
      assert ProjectionStore.project_repositories("ghost") == nil
      assert ProjectionStore.project_primary_repo_id("ghost") == nil
      assert ProjectionStore.project_repository("ghost", "main") == nil
    end

    test "project.update path moves the synthesised primary" do
      assert :ok = ProjectionStore.apply_events(legacy_events())

      assert :ok =
               ProjectionStore.apply_events([
                 %{
                   event_type: "ProjectUpdated",
                   payload: %{project_id: "legacy-1", path: "/srv/moved"}
                 }
               ])

      assert [%{id: "main", path: "/srv/moved"}] =
               ProjectionStore.project_repositories("legacy-1")
    end
  end

  describe "ProjectRepositoryAdded / Removed" do
    test "extras follow the synthesised primary, in order; remove drops them" do
      assert :ok =
               ProjectionStore.apply_events([
                 register("p", "/srv/p"),
                 added("p", "api", "/srv/api"),
                 added("p", "web", "/srv/web", %{default_branch: "develop"})
               ])

      assert [%{id: "main"}, %{id: "api", primary: false}, %{id: "web"}] =
               ProjectionStore.project_repositories("p")

      assert %{default_branch: "develop", added_by: "operator:alice"} =
               ProjectionStore.project_repository("p", "web")

      assert ProjectionStore.project_primary_repo_id("p") == "main"

      assert :ok =
               ProjectionStore.apply_events([
                 %{
                   event_type: "ProjectRepositoryRemoved",
                   payload: %{
                     project_id: "p",
                     repo_id: "api",
                     removed_by: "operator:alice",
                     at: "t"
                   }
                 }
               ])

      assert [%{id: "main"}, %{id: "web"}] = ProjectionStore.project_repositories("p")
    end

    test "events for an unknown project are ignored without raising" do
      assert :ok = ProjectionStore.apply_events([added("ghost", "api", "/srv/api")])
      assert ProjectionStore.project_repositories("ghost") == nil
    end
  end

  describe "through CommandRouter" do
    test "add is idempotent per command_id; remove then re-add with a new id works" do
      id = "repos-#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               CommandRouter.dispatch(%{
                 type: "project.register",
                 aggregate_id: "project:#{id}",
                 payload: %{project_id: id, path: "/srv/#{id}"}
               })

      add = fn command_id ->
        CommandRouter.dispatch(%{
          type: "project.repo.add",
          aggregate_id: "project:#{id}",
          command_id: command_id,
          payload: %{
            project_id: id,
            repo_id: "api",
            path: "/srv/#{id}-api",
            added_by: "operator:alice"
          }
        })
      end

      assert {:ok, _} = add.("add-1")
      assert {:ok, _} = add.("add-1")
      assert [%{id: "main"}, %{id: "api"}] = ProjectionStore.project_repositories(id)

      assert {:ok, events} = EventStore.read_stream_forward("project:#{id}", 0, 100)
      assert Enum.count(events, &(&1.event_type == "ProjectRepositoryAdded")) == 1

      assert {:ok, _} =
               CommandRouter.dispatch(%{
                 type: "project.repo.remove",
                 aggregate_id: "project:#{id}",
                 command_id: "rm-1",
                 payload: %{project_id: id, repo_id: "api", removed_by: "operator:alice"}
               })

      assert [%{id: "main"}] = ProjectionStore.project_repositories(id)
      assert {:ok, _} = add.("add-2")
      assert [%{id: "main"}, %{id: "api"}] = ProjectionStore.project_repositories(id)
    end
  end
end
