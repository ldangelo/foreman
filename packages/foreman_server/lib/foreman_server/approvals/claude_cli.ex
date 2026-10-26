defmodule ForemanServer.Approvals.ClaudeCli do
  @moduledoc """
  Whether the claude CLI Foreman launches knows `--permission-prompt-tool` (bead foreman-dc618), the
  flag `priv/bin/foreman-claude-permission` adds so that a claude phase's permission prompts reach
  `ForemanServer.Approvals.Inflight`. A CLI that predates it exits 1 at once with
  `error: unknown option '--permission-prompt-tool'`, which used to fail every
  `approval_mode: prompt` phase with an opaque `{:other, :execution}`.

  `permission_prompt_tool/1` runs the CLI with the flag and NO value. The CLI's argument parser
  (commander) rejects that while it reads its arguments, before it does anything else (no network,
  no files written), and the message says which of the two it is:

    * `error: option '--permission-prompt-tool <tool>' argument missing` - the flag is known;
    * `error: unknown option '--permission-prompt-tool'` - it is not.

  Observed on claude 2.1.308 (native) and on the npm builds 1.0.0, 1.0.119 and 2.0.50 (known) and
  0.2.60 (unknown), each exiting 1 in well under a second. `claude --help` cannot answer this:
  every build that has the flag registers it hidden, so the help never lists it.

  Only those two messages are a verdict. A CLI that cannot be run, times out or says anything else
  is `{:unknown, reason}`: the caller carries on as if the flag were there, which is what happened
  before this probe existed.

  The CLI probed is the one the wrapper script runs: `FOREMAN_CLAUDE_CLI`, else `claude` on the PATH.
  """

  alias Jido.Harness.Process, as: HarnessProcess
  alias Jido.Harness.{ProcessInfo, ProcessSpec}

  @flag "--permission-prompt-tool"
  @known "option '#{@flag} <tool>' argument missing"
  @unknown "unknown option '#{@flag}'"
  @env_var "FOREMAN_CLAUDE_CLI"
  @default_executable "claude"
  @probe_timeout_ms 10_000
  # The harness stops a timed-out process SIGINT -> SIGTERM -> SIGKILL, 5 s per step.
  @stop_grace_ms 15_000

  @type unknown_reason ::
          {:not_installed, String.t()}
          | {:probe_failed, term()}
          | {:unrecognised_output, String.t()}

  @type support :: :supported | {:unsupported, String.t()} | {:unknown, unknown_reason()}

  @doc """
  Probe the claude CLI for `--permission-prompt-tool`. `{:unsupported, executable}` names the
  executable that rejected it. `opts`: `:timeout_ms` (default #{@probe_timeout_ms}).
  """
  @spec permission_prompt_tool(keyword()) :: support()
  def permission_prompt_tool(opts \\ []) do
    executable = executable()

    case ProcessSpec.resolve_executable(executable) do
      {:ok, path} ->
        path |> probe(Keyword.get(opts, :timeout_ms, @probe_timeout_ms)) |> classify(path)

      {:error, _not_found} ->
        {:unknown, {:not_installed, executable}}
    end
  end

  defp executable do
    case System.get_env(@env_var) do
      name when name in [nil, ""] -> @default_executable
      name -> name
    end
  end

  defp probe(path, timeout_ms) do
    spec = %{executable: path, argv: [@flag], stdin: false, runtime_timeout_ms: timeout_ms}

    with {:ok, id} <- HarnessProcess.start(spec) do
      result = await_output(id, timeout_ms)
      _ = HarnessProcess.prune(id)
      result
    end
  end

  defp await_output(id, timeout_ms) do
    case HarnessProcess.await(id, timeout_ms + @stop_grace_ms) do
      {:ok, %ProcessInfo{state: state}} when state in [:exited, :failed] ->
        with {:ok, events} <- HarnessProcess.replay(id, cursor: 0, limit: 100),
             do: {:ok, output(events)}

      {:ok, %ProcessInfo{state: state}} ->
        {:error, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp output(events) do
    events
    |> Enum.filter(&(&1.type in [:stdout, :stderr]))
    |> Enum.map_join("", &to_string(&1.data))
  end

  defp classify({:ok, output}, path) do
    cond do
      String.contains?(output, @unknown) -> {:unsupported, path}
      String.contains?(output, @known) -> :supported
      true -> {:unknown, {:unrecognised_output, String.slice(output, 0, 200)}}
    end
  end

  defp classify({:error, reason}, _path), do: {:unknown, {:probe_failed, reason}}
end
