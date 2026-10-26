defmodule ForemanServer.TestSupport.StrayAgent do
  @moduledoc false
  # A REAL harness run: the pi adapter launching `fake_agent.sh` under erlexec, exactly as
  # production launches pi. The agent starts a tool process (`sleep`) in a session of its own, as
  # pi's bash tool does, so a signal to the agent's process group never reaches it: it outlives
  # the agent, re-parented to pid 1 (foreman-zmhzw).
  #
  # By default the agent also ignores SIGINT, so a cancel only lands when the harness escalates to
  # SIGTERM (`cancel_grace_ms` later): between `Run.cancel/1` and that moment the run reads as
  # cancelled while the agent is still alive and the tool process is still its child.

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Jido.Harness.{Run, RunRequest}

  @fake_agent Path.expand("../foreman_server/jobsite/support/fake_agent.sh", __DIR__)

  @live_states [:starting, :running, :stopping]

  @doc "Absolute path of the fake pi CLI."
  def fake_agent, do: @fake_agent

  @doc """
  Shortens the harness's SIGINT -> SIGTERM -> SIGKILL escalation for the calling test (the process
  workers read it when they start), restoring it afterwards.
  """
  def tight_grace!(ms) do
    previous = Application.get_env(:jido_harness, :process_manager)

    Application.put_env(:jido_harness, :process_manager, %{cancel_grace_ms: ms, term_grace_ms: ms})

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:jido_harness, :process_manager)
        value -> Application.put_env(:jido_harness, :process_manager, value)
      end
    end)
  end

  @doc """
  Starts the agent with `dir` as its cwd and waits until its tool process exists. Returns
  `%{run_id:, agent_os_pid:, stray_pid:}`. `env` overrides the fake agent's knobs
  (`"FAKE_AGENT_IGNORE_INT" => nil` makes it die on SIGINT).
  """
  def start!(dir, env \\ %{}) do
    env =
      %{
        "FAKE_AGENT_STRAY_SECS" => "300",
        "FAKE_AGENT_SLEEP_ON_RUN" => "1",
        "FAKE_AGENT_SLEEP_SECS" => "300",
        "FAKE_AGENT_IGNORE_INT" => "1"
      }
      |> Map.merge(env)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    {:ok, request} =
      RunRequest.new(
        prompt: "go",
        provider: :pi,
        cwd: dir,
        env: env,
        idle_timeout_ms: 120_000,
        runtime_timeout_ms: :infinity,
        provider_options: %{cli_path: @fake_agent}
      )

    {:ok, run_id} = Run.start(:pi, request)
    stray_pid = stray_pid!(dir)
    agent_os_pid = await_agent_os_pid!(run_id)

    on_exit(fn ->
      Run.cancel(run_id)
      kill!(agent_os_pid)
      kill!(stray_pid)
    end)

    %{run_id: run_id, agent_os_pid: agent_os_pid, stray_pid: stray_pid}
  end

  @doc "Whether `pid` is a running process (a zombie is not)."
  def alive?(pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {out, 0} -> not String.starts_with?(String.trim(out), "Z")
      _ -> false
    end
  end

  @doc "`pid`'s parent pid, or nil when it is not running."
  def ppid(pid) do
    case System.cmd("ps", ["-o", "ppid=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {out, 0} -> out |> String.trim() |> Integer.parse() |> elem(0)
      _ -> nil
    end
  end

  @doc "Polls until `fun` is truthy; flunks after `tries` x 50 ms."
  def await!(what, fun, tries \\ 200) do
    cond do
      fun.() ->
        :ok

      tries > 0 ->
        Process.sleep(50)
        await!(what, fun, tries - 1)

      true ->
        ExUnit.Assertions.flunk("timed out waiting for #{what}")
    end
  end

  @doc "Kills `pid` with SIGKILL, whether or not it is running."
  def kill!(pid), do: System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)

  @doc """
  Waits for the fake agent to record the pid of its tool process in `dir/stray.pid` and returns it.
  """
  def stray_pid!(dir) do
    path = Path.join(dir, "stray.pid")

    await!("the agent's tool process (#{path})", fn ->
      match?({:ok, <<_, _::binary>>}, File.read(path))
    end)

    path |> File.read!() |> String.trim() |> String.to_integer()
  end

  @doc """
  A process that has nothing to do with any agent: `sleep` with cwd `dir`, whose parent exited, so
  it is an orphan (ppid 1) - what the reaper looks for. Killed after the test.
  """
  def spawn_orphan!(dir) do
    marker = "4#{System.unique_integer([:positive])}"

    {_, 0} =
      System.cmd("sh", [
        "-c",
        "cd \"$1\" && ( exec sleep #{marker} </dev/null >/dev/null 2>&1 & )",
        "sh",
        dir
      ])

    pid = await_pid!("sleep #{marker}")
    on_exit(fn -> kill!(pid) end)
    pid
  end

  defp await_pid!(command) do
    await!("`#{command}` to appear", fn -> pgrep(command) end)
    pgrep(command)
  end

  defp pgrep(command) do
    {out, _} = System.cmd("pgrep", ["-f", "^" <> command <> "$"], stderr_to_stdout: true)

    case Integer.parse(String.trim(out)) do
      {pid, _} -> pid
      :error -> nil
    end
  end

  defp await_agent_os_pid!(run_id) do
    await!("the harness to report the agent's pid", fn -> agent_os_pid(run_id) end)
    agent_os_pid(run_id)
  end

  defp agent_os_pid(run_id) do
    Enum.find_value(Jido.Harness.Process.list(states: @live_states), fn
      %{os_pid: os_pid, metadata: %{run_id: ^run_id}} when is_integer(os_pid) -> os_pid
      _other -> nil
    end)
  end
end
