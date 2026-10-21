defmodule ForemanServer.Aggregates.TaskRepoTargetingTest do
  # E12 S9: `task.create` may name the run's primary repository (`repo_id`) and
  # extra repositories (`repo_ids`). They are validated against the project's
  # registered repositories before TaskCreated is written, and the written
  # fields are exactly what RunRepoSet resolves at run start.
  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.Task
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.Workflow.RunRepoSet

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)

    :ok =
      ProjectionStore.apply_events([
        %{event_type: "ProjectRegistered", payload: %{project_id: "rt-1", path: "/tmp/rt-1"}},
        added("b"),
        added("c"),
        added("d")
      ])
  end

  defp added(repo_id) do
    %{
      event_type: "ProjectRepositoryAdded",
      payload: %{
        project_id: "rt-1",
        repo_id: repo_id,
        path: "/tmp/rt-1-#{repo_id}",
        default_branch: nil,
        vcs: %{adapter: "git"},
        task_provider: nil,
        added_by: "operator:alice",
        at: "2026-01-01T00:00:00Z"
      }
    }
  end

  defp create(extra) do
    Task.handle_command(Task.initial_state(), %{
      type: "task.create",
      payload: Map.merge(%{task_id: "t-rt", project_id: "rt-1"}, extra)
    })
  end

  test "no repo fields: the event carries no repo keys (single-repo byte-identical)" do
    assert {:ok, %{payload: payload}} = create(%{})
    refute Map.has_key?(payload, :repo_id)
    refute Map.has_key?(payload, :repo_ids)
  end

  test "explicit project primary id is dropped from the event" do
    assert {:ok, %{payload: payload}} = create(%{repo_id: "main"})
    refute Map.has_key?(payload, :repo_id)
  end

  test "secondary primary and extras are written and resolve to the run's set" do
    assert {:ok, %{payload: payload}} = create(%{"repo_id" => "b", "repo_ids" => ["main", "c"]})
    assert payload.repo_id == "b"
    assert payload.repo_ids == ["main", "c"]

    assert {:ok, %{primary: %{id: "b"}, extras: [%{id: "main"}, %{id: "c"}]}} =
             RunRepoSet.resolve("rt-1", payload, 4)
  end

  test "unknown repo ids are rejected" do
    assert {:error, {:unknown_repo, "zzz"}} = create(%{repo_id: "zzz"})
    assert {:error, {:unknown_repo, "zzz"}} = create(%{repo_ids: ["b", "zzz"]})
  end

  test "duplicates and an extra equal to the effective primary are rejected before the cap" do
    assert {:error, {:duplicate_repo_ids, ["b"]}} = create(%{repo_ids: ["b", "b"]})
    assert {:error, {:repo_id_is_primary, "main"}} = create(%{repo_ids: ["main"]})
    assert {:error, {:repo_id_is_primary, "b"}} = create(%{repo_id: "b", repo_ids: ["b"]})
  end

  test "the cap counts the primary plus extras" do
    # default cap 4: primary + 3 extras fits, primary + 4 does not
    assert {:ok, _} = create(%{repo_ids: ["b", "c", "d"]})
    :ok = ProjectionStore.apply_events([added("e")])
    assert {:error, {:max_repos_exceeded, 4}} = create(%{repo_ids: ["b", "c", "d", "e"]})

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectUpdated",
          payload: %{project_id: "rt-1", max_repos_per_run: 2}
        }
      ])

    assert {:ok, _} = create(%{repo_ids: ["b"]})
    assert {:error, {:max_repos_exceeded, 2}} = create(%{repo_ids: ["b", "c"]})
  end

  test "a non-primary run primary counts toward the cap too" do
    :ok =
      ProjectionStore.apply_events([
        %{event_type: "ProjectUpdated", payload: %{project_id: "rt-1", max_repos_per_run: 2}}
      ])

    assert {:error, {:max_repos_exceeded, 2}} = create(%{repo_id: "b", repo_ids: ["c", "d"]})
  end

  test "repo fields on an unknown project are rejected" do
    assert {:error, {:project_not_found, "nope"}} =
             Task.handle_command(Task.initial_state(), %{
               type: "task.create",
               payload: %{task_id: "t-x", project_id: "nope", repo_id: "b"}
             })
  end
end
