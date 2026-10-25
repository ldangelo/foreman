defmodule ForemanServer.Workflow.OrphanReaper do
  @moduledoc """
  Terminates agent OS processes that outlived what started them: the server that started them
  (before their worktree is reused), or the agent they are the tool processes of (when a run is
  cancelled or the server shuts down).

  ## Why this exists

  Agents run under `erlexec` (`Jido.Harness.ProcessDriver.Erlexec`): each one
  is a child of the `exec-port` helper, in its own process group
  (`{:group, 0}`, `:kill_group`). When the BEAM dies, `exec-port` sees its pipe
  close and kills those groups; probed live with `kill -9` of the BEAM, the
  `pi` agent and its `bash` tool child both died. An agent only survives when
  `exec-port` is killed too (`pkill -9 -f <repo path>` matches its binary path,
  an OOM kill, a container stop) - it is then re-parented to `init` (pid 1)
  and keeps editing the worktree.

  Nothing persists agent pids, and the pid is not exposed past the harness, so
  there is nothing to look up. What IS durable is the working directory: every
  agent is launched with `cwd` inside its run's worktree. `reap/1` finds
  processes whose cwd is inside the worktree AND whose parent is pid 1 (an
  orphan of a dead server - a live server's agents are children of its
  `exec-port`), then terminates them and every descendant (the agent's tool
  processes run in their own process groups): `SIGTERM`, then `SIGKILL`.

  Processes that still have a live parent are never touched, whatever their cwd.
  On hosts where orphans are re-parented to a subreaper other than pid 1 no
  orphan is recognised; nothing is killed in that case.

  ## Tool processes outlive their agent

  The agent's tool processes (pi's `bash` tool starts each command detached, in a session and
  process group of its own) are not reached by a signal to the agent's group, so stopping the
  agent - `run.cancel`, `thread stop`, a graceful shutdown - leaves them running, re-parented to
  pid 1, in a worktree nobody owns any more. The same cwd + pid-1 match finds them, but only once
  the agent is gone: callers that stop an agent themselves wait for its exit first
  (`ForemanServer.AgentRuntime.JidoHarness.Driver.await_exit/2`) and then call `reap/1`. A server
  that is shutting down does not wait for its agents to die first (the harness kills them as it
  stops), so it takes them out together with every descendant while the tree is still intact:
  `reap_trees/1`.
  """

  require Logger

  @term_wait_ms 5_000
  @poll_ms 100
  # An agent's command line carries its whole prompt.
  @logged_command_chars 160

  @type reaped :: %{pid: pos_integer(), pgid: pos_integer(), command: String.t()}
  @type reason ::
          {:orphan_survived, [reaped()]}
          | {:lsof_unavailable, String.t()}
          | {:lsof_failed, non_neg_integer(), String.t()}
          | {:ps_failed, non_neg_integer(), String.t()}

  @doc """
  Kills orphaned agent processes whose cwd is inside `worktree_path`.

  Returns the processes that were terminated. `{:error, {:lsof_unavailable, _}}`,
  `{:error, {:lsof_failed, _, _}}` and `{:error, {:ps_failed, _, _}}` mean the scan could not run (callers log
  and proceed: the worktree is still reused); `{:error, {:orphan_survived, _}}`
  means a process refused to die and the worktree must NOT be reused.
  """
  @spec reap(String.t()) :: {:ok, [reaped()]} | {:error, reason()}
  def reap(worktree_path) when is_binary(worktree_path) and worktree_path != "" do
    roots = roots(worktree_path)

    with {:ok, procs} <- cwd_scan(),
         {:ok, table} <- process_table() do
      roots_found =
        for {pid, cwd} <- procs,
            pid != self_os_pid(),
            inside?(cwd, roots),
            %{ppid: 1} = info <- [Map.get(table, pid)],
            do: info

      kill_roots(roots_found, table, "orphaned process(es) in #{worktree_path}")
    end
  end

  @doc """
  Terminates the processes `os_pids` and every descendant of them (`SIGTERM`, then `SIGKILL`),
  whatever their cwd and parent.

  For agents that are still alive, the one case `reap/1` cannot see: their tool processes still
  have the agent as parent. Same return values as `reap/1`; a pid that is no longer running is
  skipped.
  """
  @spec reap_trees([pos_integer()]) :: {:ok, [reaped()]} | {:error, reason()}
  def reap_trees([]), do: {:ok, []}

  def reap_trees(os_pids) when is_list(os_pids) do
    with {:ok, table} <- process_table() do
      roots = for pid <- os_pids, info = Map.get(table, pid), do: info
      kill_roots(roots, table, "process(es) of agents still running")
    end
  end

  # The orphans plus everything they spawned, logged and terminated.
  defp kill_roots(roots, table, what) do
    case targets(roots, table) do
      [] ->
        {:ok, []}

      targets ->
        Logger.warning(
          "OrphanReaper: terminating #{length(targets)} #{what}: " <>
            inspect(
              Enum.map(targets, &{&1.pid, String.slice(&1.command, 0, @logged_command_chars)})
            )
        )

        terminate(targets)
    end
  end

  # -- scan -----------------------------------------------------------------

  defp cwd_scan do
    case System.find_executable("lsof") do
      nil ->
        {:error, {:lsof_unavailable, "lsof not found on PATH"}}

      lsof ->
        # `-Fpn`: one `p<pid>` line, then one `n<path>` line per selected fd.
        case System.cmd(lsof, ["-nP", "-a", "-d", "cwd", "-Fpn"], stderr_to_stdout: true) do
          {out, status} when status in [0, 1] -> {:ok, parse_lsof(out)}
          {out, status} -> {:error, {:lsof_failed, status, String.slice(out, 0, 500)}}
        end
    end
  end

  defp parse_lsof(out) do
    {entries, _pid} =
      out
      |> String.split("\n", trim: true)
      |> Enum.reduce({[], nil}, fn
        "p" <> pid, {acc, _} ->
          case Integer.parse(pid) do
            {n, ""} -> {acc, n}
            _ -> {acc, nil}
          end

        "n" <> path, {acc, pid} when is_integer(pid) ->
          {[{pid, path} | acc], pid}

        _other, acc ->
          acc
      end)

    entries
  end

  defp roots(worktree_path) do
    expanded = Path.expand(worktree_path)
    Enum.uniq([expanded, physical_path(expanded)])
  end

  # lsof reports the physical path (`/private/var/...`), the registry may hold a
  # symlinked one (`/var/...`); compare against both.
  defp physical_path(path) do
    case System.cmd("sh", ["-c", ~s(cd "$1" 2>/dev/null && pwd -P), "sh", path]) do
      {out, 0} when out != "" -> String.trim(out)
      _ -> path
    end
  end

  defp inside?(cwd, roots),
    do: Enum.any?(roots, fn root -> cwd == root or String.starts_with?(cwd, root <> "/") end)

  defp self_os_pid, do: String.to_integer(System.pid())

  # One snapshot of the process table. An orphan of a dead server is a process
  # re-parented to init (ppid 1).
  defp process_table do
    case System.cmd("ps", ["-axo", "pid=,ppid=,pgid=,command="], stderr_to_stdout: true) do
      {out, 0} ->
        table =
          for line <- String.split(out, "\n", trim: true),
              [pid, ppid, pgid, command] <- [String.split(String.trim(line), ~r/\s+/, parts: 4)],
              into: %{} do
            {String.to_integer(pid),
             %{
               pid: String.to_integer(pid),
               ppid: String.to_integer(ppid),
               pgid: String.to_integer(pgid),
               command: command
             }}
          end

        {:ok, table}

      {out, status} ->
        {:error, {:ps_failed, status, String.slice(out, 0, 500)}}
    end
  end

  # The orphans plus everything they spawned. Tool processes (the agent's bash)
  # start their own process group, so signalling the agent's group is not enough.
  defp targets(roots, table) do
    children =
      Enum.group_by(Map.values(table), & &1.ppid)

    roots
    |> Enum.flat_map(&[&1 | descendants(&1.pid, children)])
    |> Enum.uniq_by(& &1.pid)
  end

  defp descendants(pid, children) do
    Enum.flat_map(Map.get(children, pid, []), &[&1 | descendants(&1.pid, children)])
  end

  # -- terminate ---------------------------------------------------------------

  defp terminate(orphans) do
    Enum.each(orphans, &signal(&1, "TERM"))

    case wait_gone(orphans, @term_wait_ms) do
      [] ->
        {:ok, orphans}

      stubborn ->
        Enum.each(stubborn, &signal(&1, "KILL"))

        case wait_gone(stubborn, @term_wait_ms) do
          [] -> {:ok, orphans}
          survivors -> {:error, {:orphan_survived, survivors}}
        end
    end
  end

  # The agent is its own group leader (`{:group, 0}`): signal the whole group so
  # the tool processes it spawned die with it. A process that is not a group
  # leader is signalled alone.
  defp signal(%{pid: pid, pgid: pid}, sig), do: kill(["-s", sig, "--", "-#{pid}"])
  defp signal(%{pid: pid}, sig), do: kill(["-s", sig, Integer.to_string(pid)])

  defp kill(args), do: System.cmd("kill", args, stderr_to_stdout: true)

  defp wait_gone(procs, budget) do
    alive = Enum.filter(procs, &alive?/1)

    cond do
      alive == [] ->
        []

      budget <= 0 ->
        alive

      true ->
        Process.sleep(@poll_ms)
        wait_gone(alive, budget - @poll_ms)
    end
  end

  defp alive?(%{pid: pid}) do
    # `kill -0` succeeds for a zombie too; `ps` state `Z` is dead for our purpose.
    case System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {out, 0} -> not String.starts_with?(String.trim(out), "Z")
      _ -> false
    end
  end
end
