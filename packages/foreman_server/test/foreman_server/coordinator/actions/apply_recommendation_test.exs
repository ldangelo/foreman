defmodule ForemanServer.Coordinator.Actions.ApplyRecommendationTest do
  # `apply_recommendation` through the real Executor, gateway and event store: the
  # model supplies an id, Foreman recomputes the recommendation and runs only the
  # fix it computed itself. The probe is a fixture: no `gh`, `br` or provider runs.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.Coordinator.{Action, Commands, Dispatch, Executor}
  alias ForemanServer.{CommandGateway, ProjectionStore, ProjectSettings}
  alias ForemanServer.Projects.Recommendations
  alias ForemanServer.Projects.Recommendations.Facts

  alias ForemanServer.TestSupport.CoordinatorHelpers, as: H
  alias ForemanServer.TestSupport.CoordinatorHelpers.SpyGateway
  alias ForemanServer.TestSupport.RecommendationsProbe

  setup %{tmp_dir: dir} do
    RecommendationsProbe.install!()

    repo = Path.join(dir, "repo")
    db = Path.join([repo, ".beads", "beads.db"])
    File.mkdir_p!(Path.dirname(db))
    File.write!(db, "")

    project_id = H.register_project(repo)
    SpyGateway.watch()
    on_exit(&SpyGateway.unwatch/0)

    {:ok, _} = Commands.turn_start(CommandGateway, project_id, "m1:a1", 1, ["m1"])
    {:ok, project_id: project_id, db: db}
  end

  defp apply_rec(id), do: %{"kind" => "apply_recommendation", "recommendation_id" => id}

  defp run(project_id, raws, overrides \\ %{}) do
    trigger = Map.get(overrides, :trigger_key, "m1")

    items =
      Enum.map(raws, fn raw ->
        case Action.normalize(raw, project_id, trigger) do
          {:ok, action} -> {:ok, action}
          {:error, {:invalid_action, reason}} -> {:invalid, raw, reason}
        end
      end)

    base = %{
      project_id: project_id,
      turn_id: "m1:a1",
      trigger_key: trigger,
      authority: :operator,
      gateway: SpyGateway
    }

    Executor.run(items, struct!(Executor.Ctx, Map.merge(base, overrides)))
  end

  defp sent(type), do: for({^type, command} <- SpyGateway.drain(), do: command)

  test "wire_beads dispatches exactly one project.update carrying the database Foreman detected",
       %{project_id: p, db: db} do
    outcomes = run(p, [apply_rec("task_provider.wire_beads")])

    assert [
             %{
               status: "executed",
               kind: "apply_recommendation",
               reason: nil,
               result_ref: %{
                 "recommendation_id" => "task_provider.wire_beads",
                 "command" => "project.update"
               }
             }
           ] = outcomes

    assert [command] = sent("project.update")
    assert command.aggregate_id == "project:" <> p

    assert command.payload == %{
             project_id: p,
             task_provider: %{provider: "beads", config: %{database_path: db}}
           }

    assert %{task_provider: %{provider: "beads"}} = ProjectionStore.project(p)
    assert Executor.notice(outcomes) == "Applied setup recommendation task_provider.wire_beads."
  end

  test "a model-supplied payload is refused at normalisation; nothing reaches the gateway", %{
    project_id: p
  } do
    raw =
      Map.put(apply_rec("task_provider.wire_beads"), "payload", %{"task_provider" => "evil"})

    assert {:error, {:invalid_action, {:unknown_keys, :apply_recommendation, ["payload"]}}} =
             Action.normalize(raw, p, "m1")

    assert [%{status: "rejected", reason: reason}] = run(p, [raw])
    assert reason =~ "unknown_keys"
    assert sent("project.update") == []
    assert ProjectionStore.project(p).task_provider == nil
  end

  test "an id that is unknown, or no longer recommended, is rejected as recommendation_not_found",
       %{project_id: p} do
    assert [%{status: "rejected", reason: unknown}] = run(p, [apply_rec("settings.nope")])
    assert unknown =~ "recommendation_not_found"
    assert sent("project.update") == []

    assert [%{status: "executed"}] = run(p, [apply_rec("task_provider.wire_beads")])

    assert [%{status: "rejected", reason: stale}] =
             run(p, [apply_rec("task_provider.wire_beads")], %{trigger_key: "m2"})

    assert stale =~ "recommendation_not_found"
    assert length(sent("project.update")) == 1
  end

  test "advice-only recommendations are rejected as not_appliable", %{project_id: p} do
    assert [%{status: "rejected", reason: reason}] = run(p, [apply_rec("repo.agents_md_missing")])
    assert reason =~ "not_appliable"
    assert sent("project.update") == []
  end

  test "a paused project is resumed by project.paused, the one other command fix", %{
    project_id: p
  } do
    {:ok, _} =
      CommandGateway.dispatch_operator(%{
        command_id: "pause-#{p}",
        aggregate_id: "project:" <> p,
        type: "project.pause",
        payload: %{project_id: p, reason: "freeze"}
      })

    assert %{status: "paused"} = ProjectionStore.project(p)

    assert [%{status: "executed", result_ref: %{"command" => "project.resume"}}] =
             run(p, [apply_rec("project.paused")])

    assert [%{payload: %{project_id: ^p}}] = sent("project.resume")
    assert %{status: "active"} = ProjectionStore.project(p)
  end

  test "a machine turn cannot apply a recommendation, whatever the id", %{project_id: p} do
    assert [%{status: "rejected", reason: reason}] =
             run(p, [apply_rec("task_provider.wire_beads")], %{authority: :machine})

    assert reason =~ "apply_recommendation needs an operator message"
    assert sent("project.update") == []
    assert ProjectionStore.project(p).task_provider == nil
  end

  test "only the turn's own project is recomputed and changed", %{project_id: p, tmp_dir: dir} do
    bare = Path.join(dir, "bare")
    File.mkdir_p!(bare)
    other = H.register_project(bare)

    assert [%{status: "rejected", reason: reason}] =
             run(other, [apply_rec("task_provider.wire_beads")])

    assert reason =~ "recommendation_not_found"
    assert sent("project.update") == []
    assert ProjectionStore.project(p).task_provider == nil
    assert ProjectionStore.project(other).task_provider == nil
  end

  test "every command fix evaluate/1 can emit is a command the coordinator may dispatch" do
    facts = %Facts{
      project_id: "p",
      repo_path: "/r",
      project_status: "paused",
      task_provider: nil,
      beads_db_path: "/r/.beads/beads.db",
      has_beads_dir: true,
      br_binary: false,
      files: %{agents_md: false, claude_md: false, ci: [], manifests: ["mix.exs"]},
      checked_out_branch: :detached,
      gh: :timeout,
      git_remote: false,
      workflows_installed: false,
      unmapped_issue_types: ["epic"],
      provider_rows: [claude: :not_installed],
      settings: %ProjectSettings{coordinator_provider: "claude"},
      env_secret_keys: ["API_TOKEN"],
      env_names: [],
      memory_count: 0
    }

    types =
      for %{fix: %{kind: :command, type: type}} <- Recommendations.evaluate(facts),
          uniq: true,
          do: type

    assert Enum.sort(types) == ["project.resume", "project.update"]
    assert types -- Dispatch.command_types() == []
  end
end
