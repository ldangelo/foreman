defmodule ForemanServer.Jobsite.Sandboxes.Docker do
  @moduledoc """
  Docker (or Podman, via `:binary`) sandbox provider. The worktree is
  bind-mounted into the container, so `kind/0` is `:bind_mount` — the
  container's filesystem IS the worktree, not a separate copy.
  """
  @behaviour ForemanServer.Jobsite.SandboxProvider

  alias ForemanServer.Aggregate
  alias ForemanServer.Jobsite.{Error, ExecResult}
  alias ForemanServer.Jobsite.Sandboxes.ExecTimeout

  @impl true
  def name, do: "docker"

  @impl true
  def kind, do: :bind_mount

  @impl true
  def create(config, worktree) do
    # `config` is atom-keyed on a fresh run and string-keyed after a resume's
    # JSON round-trip through the event store — `Aggregate.get/2,3` tries the
    # atom key first, then the string key, exactly as `ProjectionStore` and
    # every aggregate command handler already do for the same ambiguity.
    binary = get(config, :binary, "docker")
    image = get(config, :image) || default_image(worktree.repo_path)
    sandbox_path = get(config, :sandbox_path, "/workspace")
    uid = get(config, :uid) || host_id("-u")
    gid = get(config, :gid) || host_id("-g")
    mounts = get(config, :mounts, [])
    network = get(config, :network)
    state_dir = Path.join(worktree.path, ".foreman/state")

    with :ok <- ensure_image(binary, image) do
      File.mkdir_p!(state_dir)

      args =
        ["run", "-d", "--rm", "-v", "#{worktree.path}:#{sandbox_path}"] ++
          mount_args(mounts) ++
          ["-w", sandbox_path, "-u", "#{uid}:#{gid}"] ++
          network_args(network) ++
          [image, "sleep", "infinity"]

      case System.cmd(binary, args, stderr_to_stdout: true) do
        {output, 0} ->
          container = String.trim(output)

          {:ok,
           %{
             container: container,
             sandbox_path: sandbox_path,
             binary: binary,
             state_dir: state_dir,
             uid: uid,
             gid: gid,
             config: config
           }, sandbox_path, container}

        {output, code} ->
          {:error,
           Error.new(:sandbox_create_failed, "docker run failed", %{
             exit_code: code,
             output: String.trim(output)
           })}
      end
    end
  end

  @impl true
  def exec(state, command, opts) do
    cwd = Keyword.get(opts, :cwd, state.sandbox_path)
    timeout_ms = Keyword.get(opts, :timeout_ms)
    args = [state.binary, ["exec", "-w", cwd, state.container, "sh", "-c", command]]

    result =
      ExecTimeout.run(
        fn ->
          [bin, cmd_args] = args
          System.cmd(bin, cmd_args, stderr_to_stdout: true)
        end,
        timeout_ms
      )

    case result do
      {:ok, {output, code}} ->
        {:ok, %ExecResult{stdout: output, stderr: "", exit_code: code}}

      {:error, :timeout} ->
        {:error,
         Error.new(:sandbox_exec_failed, "command timed out", %{
           command: command,
           timeout_ms: timeout_ms
         })}
    end
  end

  @impl true
  def agent_cli_path(state, agent_binary, env) do
    env_file = Path.join(state.state_dir, "agent.env")
    shim_path = Path.join(state.state_dir, "agent-exec")

    env_content = Enum.map_join(env, "\n", fn {k, v} -> "#{k}=#{v}" end) <> "\n"
    File.write!(env_file, env_content)
    File.chmod!(env_file, 0o600)

    shim = """
    #!/bin/sh
    exec #{state.binary} exec -i --env-file "#{env_file}" -w "#{state.sandbox_path}" -u "#{state.uid}:#{state.gid}" "#{state.container}" "#{agent_binary}" "$@"
    """

    File.write!(shim_path, shim)
    File.chmod!(shim_path, 0o755)

    {:ok, shim_path}
  end

  @impl true
  def copy_file_in(state, host_path, sandbox_path) do
    docker_cp(state, host_path, "#{state.container}:#{sandbox_path}")
  end

  @impl true
  def copy_file_out(state, sandbox_path, host_path) do
    File.mkdir_p!(Path.dirname(host_path))
    docker_cp(state, "#{state.container}:#{sandbox_path}", host_path)
  end

  @impl true
  def close(state) do
    case System.cmd(state.binary, ["rm", "-f", state.container], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, _code} ->
        {:error,
         Error.new(:sandbox_exec_failed, "docker rm failed", %{output: String.trim(output)})}
    end
  end

  defp docker_cp(state, source, dest) do
    case System.cmd(state.binary, ["cp", source, dest], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, _code} ->
        {:error, Error.new(:copy_failed, "docker cp failed", %{output: String.trim(output)})}
    end
  end

  defp ensure_image(binary, image) do
    case System.cmd(binary, ["image", "inspect", image], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {_output, _code} ->
        {:error,
         Error.new(
           :image_missing,
           "image #{image} not found — build it first (e.g. `docker build -t #{image} .foreman`)",
           %{image: image}
         )}
    end
  end

  defp mount_args(mounts) do
    Enum.flat_map(mounts, fn m ->
      h = get(m, :host_path, nil)
      s = get(m, :sandbox_path, nil)
      ro = if get(m, :readonly?, false), do: ":ro", else: ""
      ["-v", "#{h}:#{s}#{ro}"]
    end)
  end

  defp get(map, key, default \\ nil), do: Aggregate.get(map, key, default)

  defp network_args(nil), do: []
  defp network_args(network), do: ["--network", network]

  defp default_image(repo_path), do: "foreman-jobsite:" <> Path.basename(repo_path)

  defp host_id(flag) do
    {output, 0} = System.cmd("id", [flag])
    String.trim(output)
  end
end
