defmodule ForemanServer.Jobsite.SandboxPathTest do
  # The agent CLI is spawned as a HOST process, and the harness refuses a `cwd`
  # that does not exist on the host. A container sandbox reports the path INSIDE
  # the container (`/workspace`), which never exists on the host, so passing that
  # as the launch cwd failed every Docker run with `cwd must be an existing
  # directory` (found by running the Docker sandbox against a real agent).
  use ExUnit.Case, async: false

  alias ForemanServer.Jobsite
  alias ForemanServer.Jobsite.Agents

  @fake_agent Path.join(__DIR__, "support/fake_agent.sh")

  # Behaves like the host provider but, like a container provider, reports a
  # sandbox path that does not exist on the host.
  defmodule ContainerPathProvider do
    @behaviour ForemanServer.Jobsite.SandboxProvider

    alias ForemanServer.Jobsite.Sandboxes.Host

    @impl true
    def name, do: "host"
    @impl true
    def kind, do: Host.kind()

    @impl true
    def create(config, worktree) do
      with {:ok, state, _host_path, nil} <- Host.create(config, worktree) do
        {:ok, state, "/workspace-that-only-exists-in-a-container", nil}
      end
    end

    @impl true
    defdelegate exec(state, command, opts), to: Host
    @impl true
    defdelegate agent_cli_path(state, binary, env), to: Host
    @impl true
    defdelegate copy_file_in(state, host_path, sandbox_path), to: Host
    @impl true
    defdelegate copy_file_out(state, sandbox_path, host_path), to: Host
    @impl true
    defdelegate close(state), to: Host
  end

  defp tmp_repo! do
    path = Path.join(System.tmp_dir!(), "jobsite-sbxpath-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    {_, 0} = System.cmd("git", ["-C", path, "init", "-q"])
    {_, 0} = System.cmd("git", ["-C", path, "config", "user.email", "t@example.com"])
    {_, 0} = System.cmd("git", ["-C", path, "config", "user.name", "T"])
    File.write!(Path.join(path, "README.md"), "hi\n")
    {_, 0} = System.cmd("git", ["-C", path, "add", "-A"])
    {_, 0} = System.cmd("git", ["-C", path, "commit", "-q", "-m", "init"])
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  test "the agent launches from the host worktree even when the sandbox path exists only in a container" do
    repo = tmp_repo!()

    assert {:ok, result} =
             Jobsite.run(
               repo_path: repo,
               strategy: {:branch, "agent/container-path"},
               sandbox: {ContainerPathProvider, %{}},
               agent: Agents.pi("x", binary: @fake_agent),
               prompt: "go"
             )

    assert [_ | _] = result.commits
  end
end
