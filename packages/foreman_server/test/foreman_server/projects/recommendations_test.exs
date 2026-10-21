defmodule ForemanServer.Projects.RecommendationsTest do
  # Pure: constructs %Facts{} directly, no I/O.
  use ExUnit.Case, async: true

  alias ForemanServer.Projects.Recommendations
  alias ForemanServer.Projects.Recommendations.Facts
  alias ForemanServer.ProjectSettings

  # A healthy project: nothing to recommend.
  defp healthy(overrides \\ []) do
    struct!(
      %Facts{
        project_id: "p",
        repo_path: "/r",
        project_status: "active",
        task_provider: "beads",
        beads_db_path: "/r/.beads/beads.db",
        has_beads_dir: true,
        br_binary: true,
        files: %{
          agents_md: true,
          claude_md: false,
          ci: [".github/workflows/ci.yml"],
          manifests: ["mix.exs"]
        },
        gh: :authenticated,
        git_remote: true,
        workflows_installed: true,
        unmapped_issue_types: [],
        provider_rows: [claude: :installed],
        settings: %ProjectSettings{goal: "g", instructions: "i", coordinator_provider: "claude"},
        env_secret_keys: [],
        memory_count: 3
      },
      overrides
    )
  end

  defp ids(facts), do: facts |> Recommendations.evaluate() |> Enum.map(& &1.id)

  test "the healthy fixture produces nothing" do
    assert ids(healthy()) == []
  end

  test "each detector fires on its fixture and only on it" do
    cases = [
      {"task_provider.wire_beads", healthy(task_provider: nil)},
      {"task_provider.br_missing", healthy(br_binary: false)},
      {"repo.agents_md_missing",
       healthy(files: %{agents_md: false, claude_md: false, ci: ["x"], manifests: []})},
      {"ci.none_detected",
       healthy(files: %{agents_md: true, claude_md: false, ci: [], manifests: []})},
      {"gh.unauthenticated", healthy(gh: :unauthenticated)},
      {"gh.unauthenticated", healthy(gh: :missing)},
      {"gh.check_timeout", healthy(gh: :timeout)},
      {"git.no_remote", healthy(git_remote: false)},
      {"workflows.not_installed", healthy(workflows_installed: false)},
      {"workflows.unmapped_types", healthy(unmapped_issue_types: ["epic"])},
      {"provider.coordinator_unavailable", healthy(provider_rows: [pi: :installed])},
      {"provider.none_installed",
       healthy(
         provider_rows: [claude: :not_installed],
         settings: %ProjectSettings{goal: "g", instructions: "i"}
       )},
      {"settings.instructions_empty",
       healthy(
         settings: %ProjectSettings{goal: "g", instructions: nil, coordinator_provider: "claude"},
         files: %{agents_md: true, claude_md: false, ci: ["x"], manifests: []}
       )},
      {"settings.goal_empty",
       healthy(
         settings: %ProjectSettings{goal: "", instructions: "i", coordinator_provider: "claude"}
       )},
      {"settings.env_plain_secrets", healthy(env_secret_keys: ["API_TOKEN"])},
      {"memory.empty", healthy(memory_count: 0)},
      {"project.paused", healthy(project_status: "paused")},
      {"stack.test_hint",
       healthy(
         settings: %ProjectSettings{goal: "g", instructions: nil, coordinator_provider: "claude"}
       )}
    ]

    for {id, facts} <- cases do
      assert id in ids(facts), "expected #{id}"
    end
  end

  test "wire_beads proposes exactly the detected database path, and is silent once wired" do
    [rec] = Recommendations.evaluate(healthy(task_provider: nil))

    assert rec.severity == :action

    assert rec.fix == %{
             kind: :command,
             type: "project.update",
             payload: %{
               project_id: "p",
               task_provider: %{provider: "beads", config: %{database_path: "/r/.beads/beads.db"}}
             }
           }

    refute "task_provider.wire_beads" in ids(healthy(task_provider: "beads"))
    refute "task_provider.wire_beads" in ids(healthy(task_provider: nil, beads_db_path: nil))
  end

  test "AGENTS.md or CLAUDE.md alone satisfies the guidance check" do
    for files <- [%{agents_md: true, claude_md: false}, %{agents_md: false, claude_md: true}] do
      facts = healthy(files: Map.merge(%{ci: ["x"], manifests: []}, files))
      refute "repo.agents_md_missing" in ids(facts)
    end
  end

  test "a gh timeout names the timeout instead of staying silent" do
    [rec] = Recommendations.evaluate(healthy(gh: :timeout))
    assert rec.severity == :warn
    assert rec.detail =~ "did not answer within"
  end

  test "unavailable facts never produce recommendations" do
    unknown =
      healthy(
        gh: :unavailable,
        git_remote: :unavailable,
        workflows_installed: :unavailable,
        unmapped_issue_types: :unavailable,
        provider_rows: :unavailable,
        settings: :unavailable,
        memory_count: :unavailable
      )

    assert ids(unknown) == []
  end

  test "ordering: action before warn before info, then by id" do
    facts =
      healthy(
        project_status: "paused",
        task_provider: nil,
        gh: :unauthenticated,
        git_remote: false,
        memory_count: 0,
        files: %{agents_md: true, claude_md: false, ci: [], manifests: []}
      )

    recs = Recommendations.evaluate(facts)

    assert Enum.map(recs, &{&1.severity, &1.id}) == [
             {:action, "project.paused"},
             {:action, "task_provider.wire_beads"},
             {:warn, "gh.unauthenticated"},
             {:warn, "git.no_remote"},
             {:info, "ci.none_detected"},
             {:info, "memory.empty"}
           ]
  end

  test "only command fixes are applicable" do
    recs = Recommendations.evaluate(healthy(project_status: "paused", git_remote: false))
    assert for(r <- recs, Recommendations.applicable?(r), do: r.id) == ["project.paused"]
  end
end
