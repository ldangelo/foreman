defmodule ForemanServer.ProjectSetup do
  @moduledoc """
  The project's setup script (E4-S4), run once after a fresh run worktree is
  created. Fatal on non-zero exit and on timeout (the `Jobsite.Hooks` contract).

  Trust: the script text comes ONLY from the project's environment record
  (`config.environment.setup_script`), written by the operator-only
  `project.environment.set` command. It is never interpolated with run/task
  data and never read from the repo or a prompt. It runs as `sh -c` with
  `cwd` = the worktree and env = resolved project env + secrets +
  `FOREMAN_WORKTREE_PATH`, `FOREMAN_RUN_ID`, `FOREMAN_PROJECT_ID`.

  Output is bounded to the last 64 KiB and redacted with the project's secret
  values before it is written to `<artifact_dir>/setup.log` or returned.

  `config :foreman_server, :project_setup, timeout_ms:` (default 300_000).
  """

  alias ForemanServer.Jobsite.HostCommand
  alias ForemanServer.Overwatch.WorkerLogPolicy
  alias ForemanServer.ProjectEnvironment

  @default_timeout_ms 300_000
  @reason_tail_bytes 2_048

  @type failure ::
          {:setup_script_failed, exit_code :: non_neg_integer(), output_tail :: String.t()}
          | {:setup_script_timeout, timeout_ms :: pos_integer(), output_tail :: String.t()}

  @doc "The configured wall-clock limit for one setup script."
  @spec timeout_ms() :: pos_integer()
  def timeout_ms,
    do:
      :foreman_server
      |> Application.get_env(:project_setup, [])
      |> Keyword.get(:timeout_ms, @default_timeout_ms)

  @doc "The project's setup script, or `nil` when none is configured."
  @spec script(String.t()) :: String.t() | nil
  def script(project_id) when is_binary(project_id),
    do: project_id |> ProjectEnvironment.environment() |> Map.fetch!("setup_script")

  @doc """
  Everything a runner needs to execute the project's script: `nil` when there is
  none, else `%{command:, env:, secrets:, timeout_ms:}`. `env` is the resolved
  project env plus `FOREMAN_PROJECT_ID`; callers add `FOREMAN_WORKTREE_PATH` and
  `FOREMAN_RUN_ID` once the worktree exists.
  """
  @spec plan(String.t()) ::
          nil
          | %{command: String.t(), env: map(), secrets: [String.t()], timeout_ms: pos_integer()}
  def plan(project_id) when is_binary(project_id) do
    case script(project_id) do
      nil ->
        nil

      command ->
        %{env: env, secrets: secrets} = ProjectEnvironment.resolve(project_id)

        %{
          command: command,
          env: Map.put(env, "FOREMAN_PROJECT_ID", project_id),
          secrets: secrets,
          timeout_ms: timeout_ms()
        }
    end
  end

  @doc """
  Run the project's script in `worktree_path`. `:ok` when there is no script or
  it exits 0; a typed `t:failure/0` otherwise. `opts[:log_dir]` receives
  `setup.log`.
  """
  @spec run(String.t(), String.t(), String.t(), keyword()) :: :ok | {:error, failure()}
  def run(project_id, worktree_path, run_id, opts \\ []) do
    case plan(project_id) do
      nil ->
        :ok

      %{command: command, env: env, secrets: secrets, timeout_ms: timeout} ->
        env =
          Map.merge(env, %{"FOREMAN_WORKTREE_PATH" => worktree_path, "FOREMAN_RUN_ID" => run_id})

        result = HostCommand.run(command, worktree_path, env: env, timeout_ms: timeout)
        finish(result, secrets, timeout, Keyword.get(opts, :log_dir))
    end
  end

  defp finish({:ok, %{exit_code: 0, output: output}}, secrets, _timeout, log_dir) do
    write_log(log_dir, redact(output, secrets))
    :ok
  end

  defp finish({:ok, %{exit_code: code, output: output}}, secrets, _timeout, log_dir) do
    tail = redact(output, secrets)
    write_log(log_dir, tail)
    {:error, {:setup_script_failed, code, bounded(tail)}}
  end

  defp finish({:error, {:timeout, output}}, secrets, timeout, log_dir) do
    tail = redact(output, secrets)
    write_log(log_dir, tail)
    {:error, {:setup_script_timeout, timeout, bounded(tail)}}
  end

  # The byte-bounded tail may begin mid-codepoint: normalise before redacting.
  defp redact(output, secrets),
    do: output |> String.replace_invalid("?") |> WorkerLogPolicy.redact(secrets)

  # The full (<= 64 KiB) output goes to setup.log; the failure reason a phase
  # carries keeps only the last 2 KiB so it stays readable in status output.
  defp bounded(tail) when byte_size(tail) > @reason_tail_bytes,
    do: binary_part(tail, byte_size(tail) - @reason_tail_bytes, @reason_tail_bytes)

  defp bounded(tail), do: tail

  defp write_log(nil, _text), do: :ok

  defp write_log(dir, text) do
    with :ok <- File.mkdir_p(dir), do: File.write(Path.join(dir, "setup.log"), text)
    :ok
  end
end
