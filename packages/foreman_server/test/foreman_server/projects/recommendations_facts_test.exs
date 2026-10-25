defmodule ForemanServer.Projects.RecommendationsFactsTest do
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectionStore
  alias ForemanServer.Projects.Recommendations.Facts
  alias ForemanServer.Projects.Recommendations.Facts.Probe
  alias ForemanServer.TestSupport.RecommendationsProbe

  @moduletag :tmp_dir

  defmodule HangingGh do
    @behaviour ForemanServer.Projects.Recommendations.Facts.Probe
    defdelegate exists?(p), to: Probe.System
    defdelegate glob(p), to: Probe.System
    defdelegate read_head(p, n), to: Probe.System
    def find_executable("gh"), do: "/bin/sleep"
    def find_executable(_), do: nil
    def cmd(exe, _args, timeout), do: Probe.System.cmd(exe, ["30"], timeout)
    def call(_fun, _timeout), do: {:error, :failed}
  end

  defp register!(id, path, config \\ %{}) do
    :ok =
      ProjectionStore.apply_events([
        %{event_type: "ProjectRegistered", payload: %{project_id: id, path: path, config: config}}
      ])
  end

  test "unknown project", _ do
    assert {:error, :project_not_found} = Facts.collect("no-such-project-e13")
  end

  test "observes fixed files and the beads db without reading repo content", %{tmp_dir: repo} do
    File.mkdir_p!(Path.join(repo, ".beads"))
    File.write!(Path.join([repo, ".beads", "beads.db"]), "")
    File.write!(Path.join(repo, "AGENTS.md"), "x")
    File.write!(Path.join(repo, "mix.exs"), "")
    File.mkdir_p!(Path.join([repo, ".github", "workflows"]))
    File.write!(Path.join([repo, ".github", "workflows", "ci.yml"]), "")
    File.mkdir_p!(Path.join(repo, ".git"))
    File.write!(Path.join([repo, ".git", "config"]), ~s([remote "origin"]\n\turl = x\n))
    id = "facts-#{System.unique_integer([:positive])}"
    register!(id, repo)

    assert {:ok, facts} = Facts.collect(id, probe_timeout_ms: 500)
    assert facts.has_beads_dir
    assert facts.beads_db_path == Path.join([repo, ".beads", "beads.db"])
    assert facts.files.agents_md and not facts.files.claude_md
    assert facts.files.ci == [".github/workflows/ci.yml"]
    assert facts.files.manifests == ["mix.exs"]
    assert facts.git_remote == true
  end

  test "a hanging gh yields :timeout within the bound, not a hang", %{tmp_dir: repo} do
    id = "facts-#{System.unique_integer([:positive])}"
    register!(id, repo)

    {micros, {:ok, facts}} =
      :timer.tc(fn -> Facts.collect(id, probe: HangingGh, probe_timeout_ms: 200) end)

    assert facts.gh == :timeout
    assert micros < 3_000_000
  end

  test "the real probe never executes a binary planted in the repo", %{tmp_dir: repo} do
    marker = Path.join(repo, "PWNED")

    for name <- ["gh", "br", "git"] do
      path = Path.join(repo, name)
      File.write!(path, "#!/bin/sh\ntouch #{marker}\n")
      File.chmod!(path, 0o755)
    end

    File.mkdir_p!(Path.join(repo, ".git"))
    File.write!(Path.join([repo, ".git", "config"]), "[core]\n\tfsmonitor = #{repo}/git\n")
    id = "facts-#{System.unique_integer([:positive])}"
    register!(id, repo)

    assert {:ok, _facts} = Facts.collect(id, probe_timeout_ms: 2_000)
    refute File.exists?(marker)
  end

  test "Probe.System.call bounds a hung function" do
    assert {:error, :timeout} = Probe.System.call(fn -> Process.sleep(:infinity) end, 50)
    assert {:ok, 1} = Probe.System.call(fn -> 1 end, 1_000)
    assert {:error, :failed} = Probe.System.call(fn -> raise "boom" end, 1_000)
  end

  describe "checked_out_branch" do
    setup %{tmp_dir: repo} do
      File.mkdir_p!(Path.join(repo, ".git"))
      id = "facts-#{System.unique_integer([:positive])}"
      register!(id, repo)
      %{id: id, head: Path.join([repo, ".git", "HEAD"])}
    end

    defp branch(id) do
      assert {:ok, facts} = Facts.collect(id, probe: RecommendationsProbe)
      facts.checked_out_branch
    end

    test "a branch is named, a bare commit is a detached HEAD", %{id: id, head: head} do
      File.write!(head, "ref: refs/heads/feature/x\n")
      assert branch(id) == "feature/x"

      File.write!(head, "0123456789abcdef0123456789abcdef01234567\n")
      assert branch(id) == :detached

      File.write!(head, String.duplicate("ab", 32) <> "\n")
      assert branch(id) == :detached
    end

    test "anything else cannot be observed, so no recommendation follows", %{id: id, head: head} do
      File.write!(head, "ref: refs/remotes/origin/main\n")
      assert branch(id) == :unavailable

      File.write!(head, "not a commit id\n")
      assert branch(id) == :unavailable

      File.rm!(head)
      assert branch(id) == :unavailable
    end

    test "a worktree's .git file and a missing repo are unavailable", %{tmp_dir: repo} do
      linked = Path.join(repo, "linked")
      File.mkdir_p!(linked)
      File.write!(Path.join(linked, ".git"), "gitdir: /elsewhere\n")
      linked_id = "facts-#{System.unique_integer([:positive])}"
      register!(linked_id, linked)
      assert branch(linked_id) == :unavailable

      bare_id = "facts-#{System.unique_integer([:positive])}"
      register!(bare_id, Path.join(repo, "does-not-exist"))
      assert branch(bare_id) == :unavailable
    end
  end

  describe "environment facts" do
    defp collect(id, repo) do
      register!(id, repo)
      assert {:ok, facts} = Facts.collect(id, probe: RecommendationsProbe)
      facts
    end

    defp fresh_id, do: "facts-#{System.unique_integer([:positive])}"

    test "a legacy flat env is judged by the rule `project env set` enforces", %{tmp_dir: repo} do
      id = fresh_id()

      register!(id, repo, %{
        env: %{
          "API_TOKEN" => "tok",
          "DB_PASSWORD" => "pw",
          "EMPTY_SECRET" => "",
          "NODE_ENV" => "t"
        }
      })

      assert {:ok, facts} = Facts.collect(id, probe: RecommendationsProbe)
      assert facts.env_secret_keys == ["API_TOKEN", "DB_PASSWORD"]
      assert facts.env_names == ["API_TOKEN", "DB_PASSWORD", "EMPTY_SECRET", "NODE_ENV"]
    end

    test "once the environment record exists the legacy env is ignored, as agents ignore it",
         %{tmp_dir: repo} do
      id = fresh_id()

      register!(id, repo, %{
        environment: %{"vars" => %{"NPM_REGISTRY" => "https://r.example"}},
        env: %{"API_TOKEN" => "tok"}
      })

      assert {:ok, facts} = Facts.collect(id, probe: RecommendationsProbe)
      assert facts.env_secret_keys == []
      assert facts.env_names == ["NPM_REGISTRY"]
    end

    test "stored secrets count as environment, by name only", %{tmp_dir: repo} do
      id = fresh_id()
      assert collect(id, repo).env_names == []

      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "ProjectSecretSet",
            payload: %{
              project_id: id,
              name: "DEPLOY_TOKEN",
              version: 1,
              at: "2026-10-25T00:00:00Z"
            }
          }
        ])

      assert {:ok, facts} = Facts.collect(id, probe: RecommendationsProbe)
      assert facts.env_names == ["DEPLOY_TOKEN"]
      assert facts.env_secret_keys == []
    end
  end
end
