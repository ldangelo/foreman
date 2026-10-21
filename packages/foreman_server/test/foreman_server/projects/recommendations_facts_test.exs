defmodule ForemanServer.Projects.RecommendationsFactsTest do
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectionStore
  alias ForemanServer.Projects.Recommendations.Facts
  alias ForemanServer.Projects.Recommendations.Facts.Probe

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

  defp register!(id, path) do
    :ok =
      ProjectionStore.apply_events([
        %{event_type: "ProjectRegistered", payload: %{project_id: id, path: path}}
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
end
