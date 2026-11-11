defmodule ForemanServer.TestSupport.DockerJobsite do
  @moduledoc false
  # Helpers for the `:docker` jobsite tests (`network_policy_docker_test.exs`, `boot_recovery_test.exs`):
  # a REAL docker daemon, a real jobsite with an allowlist network policy (so a sandbox container, an
  # egress proxy sidecar and an internal network exist per jobsite), the real fake agent run inside
  # the container.
  #
  # Scope: everything is found and removed by the jobsite id's `foreman.jobsite=<id>` label or by an id
  # captured while the jobsite was live; no helper lists, stops or removes anything else.

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias ForemanServer.CommandRouter
  alias ForemanServer.Jobsite
  alias ForemanServer.Jobsite.{Agents, Sandboxes}

  @git_image "foreman-jobsite-test:git"
  @support Path.expand("../foreman_server/jobsite/support", __DIR__)
  @fake_agent Path.join(@support, "fake_agent.sh")

  @doc "The sandbox image: alpine with git (the jobsite commits inside the sandbox). Built once."
  @spec ensure_image!() :: String.t()
  def ensure_image! do
    case System.cmd("docker", ["image", "inspect", @git_image], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      _ ->
        dir =
          Path.join(
            System.tmp_dir!(),
            "foreman-jobsite-test-image-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(dir)

        File.write!(
          Path.join(dir, "Dockerfile"),
          "FROM alpine:3.20\nRUN apk add --no-cache git\n"
        )

        try do
          {out, status} =
            System.cmd("docker", ["build", "-q", "-t", @git_image, dir], stderr_to_stdout: true)

          assert status == 0, "building #{@git_image} failed: #{out}"
        after
          File.rm_rf(dir)
        end
    end

    @git_image
  end

  @doc "A git repo with one commit, removed on exit."
  @spec tmp_repo!() :: String.t()
  def tmp_repo! do
    path = Path.join(System.tmp_dir!(), "docker-jobsite-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    {_, 0} = System.cmd("git", ["-C", path, "init", "-q"])
    {_, 0} = System.cmd("git", ["-C", path, "config", "user.email", "test@example.com"])
    {_, 0} = System.cmd("git", ["-C", path, "config", "user.name", "Test"])
    File.write!(Path.join(path, "README.md"), "hello\n")
    {_, 0} = System.cmd("git", ["-C", path, "add", "-A"])
    {_, 0} = System.cmd("git", ["-C", path, "commit", "-q", "-m", "init"])
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  @doc "Registers a project at `repo` whose network policy is an allowlist; returns its id."
  @spec allowlist_project!(String.t()) :: String.t()
  def allowlist_project!(repo) do
    project_id = "docker-jobsite-#{Elixir.EventStore.UUID.uuid4()}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.register",
        payload: %{project_id: project_id, path: repo, config: %{}},
        aggregate_id: "project:#{project_id}"
      })

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.environment.set",
        payload: %{
          project_id: project_id,
          network: %{mode: "allowlist", hosts: ["pypi.org"]}
        },
        aggregate_id: "project:#{project_id}"
      })

    project_id
  end

  @doc """
  The options of a docker jobsite on `project_id` whose fake agent runs inside the container:
  the support directory is mounted read-only at the same path, so the shim's `docker exec` finds it.
  `agent_env` drives the fake agent (`FAKE_AGENT_SLEEP_ON_RUN` holds the iteration open).
  """
  @spec jobsite_opts(String.t(), String.t() | nil, map(), map()) :: keyword()
  def jobsite_opts(repo, project_id, agent_env, labels \\ %{}) do
    base = [
      repo_path: repo,
      strategy: :merge_to_head,
      sandbox:
        Sandboxes.docker(
          image: ensure_image!(),
          labels: labels,
          mounts: [%{host_path: @support, sandbox_path: @support, readonly?: true}]
        ),
      agent: Agents.pi("x", binary: @fake_agent, env: agent_env),
      prompt: "go",
      max_iterations: 1,
      completion_signal: "NEVER"
    ]

    if project_id, do: base ++ [project_id: project_id], else: base
  end

  @doc "Starts a jobsite whose agent holds its first iteration open for `hold_secs`, and waits until it is in it."
  @spec start_held!(String.t(), String.t(), pos_integer()) :: String.t()
  def start_held!(repo, project_id, hold_secs \\ 300) do
    start!(jobsite_opts(repo, project_id, held_env(hold_secs)), &"foreman.jobsite=#{&1}")
  end

  @doc """
  Like `start_held!/3` on a project with NO network policy: the jobsite has only its sandbox
  container, so nothing but the sandbox's own `close` removes it (a network teardown cannot). The
  container carries a test label unique to this call; returns `{jobsite_id, label}` for
  `containers/1`.
  """
  @spec start_held_plain!(String.t(), pos_integer()) :: {String.t(), String.t()}
  def start_held_plain!(repo, hold_secs \\ 300) do
    label = "foreman-docker-jobsite-test=plain-#{System.unique_integer([:positive])}"
    [key, value] = String.split(label, "=", parts: 2)
    opts = jobsite_opts(repo, nil, held_env(hold_secs), %{key => value})
    {start!(opts, fn _id -> label end), label}
  end

  defp held_env(hold_secs),
    do: %{
      "FAKE_AGENT_SLEEP_ON_RUN" => "1",
      "FAKE_AGENT_SLEEP_SECS" => Integer.to_string(hold_secs)
    }

  defp start!(opts, label_for) do
    assert {:ok, id} = Jobsite.run_async(opts)
    safety_net(label_for.(id))
    wait_until(fn -> (Jobsite.get(id) || %{})[:iteration_index] == 1 end, 60_000)
    id
  end

  @doc "Container ids (running or not) carrying `label` (`key=value`)."
  @spec containers(String.t()) :: [String.t()]
  def containers(label), do: resources_by_label(label).containers

  @doc """
  What docker holds for the jobsite right now, by its `foreman.jobsite=<id>` label:
  `%{containers: [id], networks: [id]}` (containers include stopped ones).
  """
  @spec resources(String.t()) :: %{containers: [String.t()], networks: [String.t()]}
  def resources(jobsite_id), do: resources_by_label("foreman.jobsite=#{jobsite_id}")

  defp resources_by_label(label) do
    filter = "label=" <> label

    %{
      containers: lines(docker(["ps", "-aq", "--no-trunc", "--filter", filter])),
      networks: lines(docker(["network", "ls", "-q", "--no-trunc", "--filter", filter]))
    }
  end

  @doc "True when docker still knows the container (running or not)."
  @spec container?(String.t()) :: boolean()
  def container?(id),
    do:
      match?(
        {_, 0},
        System.cmd("docker", ["inspect", "--type", "container", id], stderr_to_stdout: true)
      )

  @doc "True when docker still knows the network."
  @spec network?(String.t()) :: boolean()
  def network?(id),
    do: match?({_, 0}, System.cmd("docker", ["network", "inspect", id], stderr_to_stdout: true))

  @doc """
  The jobsite's live resources, asserted to be what an allowlist jobsite has: the sandbox container,
  the proxy sidecar (named `foreman-jobsite-proxy-<id>`) and the internal network.
  """
  @spec live_resources!(String.t()) :: %{containers: [String.t()], networks: [String.t()]}
  def live_resources!(jobsite_id) do
    found = resources(jobsite_id)
    assert length(found.containers) == 2, "expected sandbox + proxy, got #{inspect(found)}"
    assert length(found.networks) == 1, "expected one network, got #{inspect(found)}"

    names =
      docker([
        "ps",
        "-a",
        "--format",
        "{{.Names}}",
        "--filter",
        "label=foreman.jobsite=#{jobsite_id}"
      ])
      |> lines()

    assert "foreman-jobsite-proxy-#{jobsite_id}" in names
    found
  end

  @doc "Asserts that none of the captured resources exists any more."
  @spec assert_gone!(%{containers: [String.t()], networks: [String.t()]}) :: :ok
  def assert_gone!(%{containers: containers, networks: networks}) do
    for id <- containers, do: refute(container?(id), "container #{id} still exists")
    for id <- networks, do: refute(network?(id), "network #{id} still exists")
    :ok
  end

  @doc "Polls `fun` until it returns true or the deadline passes."
  @spec wait_until((-> boolean()), pos_integer()) :: :ok
  def wait_until(fun, deadline_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) >= deadline -> flunk("wait_until timed out")
      true -> Process.sleep(50) && do_wait(fun, deadline)
    end
  end

  # A failing test must not leave docker objects behind: remove exactly what carries this label.
  defp safety_net(label) do
    on_exit(fn ->
      found = resources_by_label(label)

      for id <- found.containers,
          do: System.cmd("docker", ["rm", "-f", id], stderr_to_stdout: true)

      for id <- found.networks,
          do: System.cmd("docker", ["network", "rm", id], stderr_to_stdout: true)
    end)
  end

  defp docker(args), do: elem(System.cmd("docker", args, stderr_to_stdout: true), 0)
  defp lines(output), do: output |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)
end
