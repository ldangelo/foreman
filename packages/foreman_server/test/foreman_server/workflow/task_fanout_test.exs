defmodule ForemanServer.Workflow.TaskFanoutTest do
  @moduledoc """
  E12-S11: `task.fanout` creates ONE single-repo task per repository through
  `task.create` (system command, never an operator route).
  """
  use ExUnit.Case, async: false

  alias ForemanServer.{CommandGateway, ProjectionStore, ProjectStore}
  alias ForemanServer.MCP.{Policy, Tools}
  alias ForemanServer.TestSupport.ProjectionStoreReset

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)

    project_id = "proj-fo-#{System.unique_integer([:positive])}"
    assert {:ok, _} = ProjectStore.save(%{project_id: project_id, path: "/tmp/fo-primary"})
    for id <- ~w(b c), do: add_repo!(project_id, id, "/tmp/fo-#{id}")

    %{project_id: project_id, fid: "fo-#{System.unique_integer([:positive])}"}
  end

  defp fanout(ctx, overrides \\ %{}) do
    payload =
      Map.merge(
        %{
          project_id: ctx.project_id,
          title: "Bump lint config",
          prompt: "Bump the lint config to v9.",
          workflow_name: "adhoc",
          repo_ids: "all",
          fanout_id: ctx.fid
        },
        overrides
      )

    CommandGateway.dispatch_system(%{
      type: "task.fanout",
      command_id: "mcp:fanout:#{System.unique_integer([:positive])}",
      aggregate_id: "project:" <> ctx.project_id,
      payload: payload
    })
  end

  defp tasks(ctx),
    do: ProjectionStore.list_tasks() |> Enum.filter(&(&1.project_id == ctx.project_id))

  test "\"all\" creates one task per repository with deterministic ids and a shared label", ctx do
    fid = ctx.fid
    assert {:ok, %{fanout_id: ^fid, tasks: outcomes}} = fanout(ctx)

    assert Enum.map(outcomes, &{&1.repo_id, &1.task_id, &1.status}) == [
             {"main", fid <> "-main", "created"},
             {"b", fid <> "-b", "created"},
             {"c", fid <> "-c", "created"}
           ]

    by_id = Map.new(tasks(ctx), &{&1.task_id, &1})
    assert map_size(by_id) == 3

    # Each task is its own single-repo run: the project primary is implicit
    # (no repo_id key), a secondary names itself as the run's primary, and
    # none carries extras.
    refute Map.has_key?(by_id[fid <> "-main"], :repo_id)
    assert by_id[fid <> "-b"].repo_id == "b"
    assert by_id[fid <> "-c"].repo_id == "c"
    refute Enum.any?(by_id, fn {_, t} -> Map.has_key?(t, :repo_ids) end)

    assert Enum.all?(by_id, fn {_, t} -> t.workflow_type == "adhoc" end)
  end

  test "the fanout_id label is carried on every TaskCreated event", ctx do
    assert {:ok, _} = fanout(ctx, %{repo_ids: ["b", "c"]})

    for repo <- ~w(b c) do
      assert {:ok, [event]} =
               ForemanServer.EventStore.read_stream_forward("task:#{ctx.fid}-#{repo}")

      assert %{"source" => "fanout:" <> _} = event.data |> Jason.encode!() |> Jason.decode!()
    end
  end

  test "retrying with the same fanout_id creates no duplicates", ctx do
    assert {:ok, _} = fanout(ctx)
    assert {:ok, %{tasks: again}} = fanout(ctx)

    assert length(tasks(ctx)) == 3
    assert Enum.all?(again, &(&1.status in ["created", "exists"]))
  end

  test "an unknown repo is rejected for itself and keeps the tasks already created", ctx do
    assert {:ok, %{tasks: [b, zzz, c]}} = fanout(ctx, %{repo_ids: ["b", "zzz", "c"]})

    assert b.status == "created"
    assert c.status == "created"
    assert %{status: "rejected", repo_id: "zzz", reason: reason} = zzz
    assert reason =~ "unknown_repo"

    assert tasks(ctx) |> Enum.map(& &1.task_id) |> Enum.sort() == [
             ctx.fid <> "-b",
             ctx.fid <> "-c"
           ]
  end

  test "a paused project rejects every repo and creates nothing", ctx do
    :ok =
      ProjectionStore.apply_events([
        %{event_type: "ProjectPaused", payload: %{project_id: ctx.project_id}}
      ])

    assert {:ok, %{tasks: outcomes}} = fanout(ctx)
    assert Enum.all?(outcomes, &(&1.status == "rejected" and &1.reason =~ "project_paused"))
    assert tasks(ctx) == []
  end

  test "an archived project rejects every repo", ctx do
    :ok =
      ProjectionStore.apply_events([
        %{event_type: "ProjectArchived", payload: %{project_id: ctx.project_id}}
      ])

    assert {:ok, %{tasks: outcomes}} = fanout(ctx)
    assert Enum.all?(outcomes, &(&1.status == "rejected" and &1.reason =~ "project_archived"))
  end

  test "malformed requests are errors, not partial fan-outs", ctx do
    assert {:error, {:duplicate_repo_ids, ["b"]}} = fanout(ctx, %{repo_ids: ["b", "b"]})
    assert {:error, {:invalid_repo_ids, []}} = fanout(ctx, %{repo_ids: []})
    assert {:error, {:invalid_repo_ids, "b"}} = fanout(ctx, %{repo_ids: "b"})
    assert {:error, {:missing_or_invalid, :title, nil}} = fanout(ctx, %{title: nil})
    assert {:error, {:invalid_fanout_id, "bad id"}} = fanout(ctx, %{fanout_id: "bad id"})
    assert {:error, {:project_not_found, "nope"}} = fanout(ctx, %{project_id: "nope"})
    assert tasks(ctx) == []
  end

  test "an omitted fanout_id is minted and shared by every task", ctx do
    payload = %{
      project_id: ctx.project_id,
      title: "t",
      prompt: "p",
      workflow_name: "adhoc",
      repo_ids: ["b", "c"]
    }

    assert {:ok, %{fanout_id: "fanout-" <> _ = id, tasks: [%{task_id: t1}, %{task_id: t2}]}} =
             CommandGateway.dispatch_system(%{
               type: "task.fanout",
               command_id: "x-#{ctx.fid}",
               aggregate_id: "project:" <> ctx.project_id,
               payload: payload
             })

    assert {t1, t2} == {id <> "-b", id <> "-c"}
  end

  test "task.fanout is not an operator command", ctx do
    assert {:error, {:command_not_allowed, "task.fanout"}} =
             CommandGateway.dispatch_operator(%{
               type: "task.fanout",
               command_id: "op-fo",
               aggregate_id: "project:" <> ctx.project_id,
               payload: %{project_id: ctx.project_id}
             })
  end

  describe "MCP tools" do
    test "both tools are write tools" do
      names = Enum.map(Tools.list_tools(), & &1.name)
      assert "foreman_task_fanout" in names
      assert "foreman_run_request_repo" in names

      prev = Application.get_env(:foreman_server, :mcp, [])
      on_exit(fn -> Application.put_env(:foreman_server, :mcp, prev) end)
      Application.put_env(:foreman_server, :mcp, Keyword.put(prev, :allow_workflow_writes, false))

      refute Policy.authorized?("foreman_task_fanout")
      refute Policy.authorized?("foreman_run_request_repo")
      refute "foreman_task_fanout" in Enum.map(Policy.list_tools(Tools.list_tools()), & &1.name)

      assert {:error, %{code: "WRITE_NOT_ALLOWED"}} =
               Tools.call_tool("foreman_task_fanout", %{
                 project_id: "p",
                 title: "t",
                 prompt: "p",
                 workflow: "w",
                 repo_ids: "all"
               })
    end

    test "foreman_task_fanout fans out when writes are allowed", ctx do
      prev = Application.get_env(:foreman_server, :mcp, [])
      on_exit(fn -> Application.put_env(:foreman_server, :mcp, prev) end)
      Application.put_env(:foreman_server, :mcp, Keyword.put(prev, :allow_workflow_writes, true))

      assert {:ok, %{tasks: [_, _, _]}} =
               Tools.call_tool("foreman_task_fanout", %{
                 project_id: ctx.project_id,
                 title: "t",
                 prompt: "p",
                 workflow: "adhoc",
                 repo_ids: "all",
                 fanout_id: ctx.fid
               })
    end

    test "foreman_run_request_repo says the repo takes effect next phase" do
      tool = Enum.find(Tools.list_tools(), &(&1.name == "foreman_run_request_repo"))
      assert tool.description =~ "effective next phase"
    end
  end

  defp add_repo!(project_id, repo_id, path) do
    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectRepositoryAdded",
          payload: %{
            project_id: project_id,
            repo_id: repo_id,
            path: path,
            default_branch: nil,
            vcs: %{adapter: "git"},
            task_provider: nil,
            added_by: "operator:test",
            at: "2026-01-01T00:00:00Z"
          }
        }
      ])
  end
end
