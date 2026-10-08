defmodule ForemanServer.Jobsite.Prompt do
  @moduledoc """
  Resolves a jobsite's prompt from exactly one of `:prompt` (passed through
  literally, no substitution or expansion) or `:prompt_file` (substitution
  then `` !`command` `` expansion, in that order — so
  `` !`gh issue view {{ISSUE_NUMBER}}` `` works, and expansion scans only the
  file's own text, never a substituted value, so a value passed through
  `prompt_args` cannot inject a command).
  """

  alias ForemanServer.Jobsite.{Error, ExecResult, Sandbox}

  @reserved_keys ~w(SOURCE_BRANCH TARGET_BRANCH)
  @var_pattern ~r/\{\{([A-Z0-9_]+)\}\}/
  @expansion_pattern ~r/!`([^`]+)`/

  @spec resolve(keyword(), Sandbox.t(), map()) :: {:ok, String.t()} | {:error, Error.t()}
  def resolve(opts, sandbox, context) do
    prompt = Keyword.get(opts, :prompt)
    prompt_file = Keyword.get(opts, :prompt_file)
    prompt_args = opts |> Keyword.get(:prompt_args, %{}) |> normalize_vars()

    case {prompt, prompt_file} do
      {nil, nil} ->
        {:error, Error.new(:prompt_source_missing, "exactly one of :prompt or :prompt_file is required", %{})}

      {p, f} when not is_nil(p) and not is_nil(f) ->
        {:error, Error.new(:prompt_source_conflict, "only one of :prompt or :prompt_file may be given", %{})}

      {p, nil} ->
        if map_size(prompt_args) > 0 do
          {:error, Error.new(:prompt_source_conflict, "prompt_args is not supported with an inline :prompt", %{})}
        else
          {:ok, p}
        end

      {nil, file} ->
        resolve_file(file, prompt_args, sandbox, context)
    end
  end

  defp resolve_file(file, prompt_args, sandbox, context) do
    with :ok <- check_reserved(prompt_args),
         {:ok, text} <- read_file(file) do
      vars = build_vars(context, prompt_args, sandbox)
      # Expansion candidates are located in the ORIGINAL file text, before
      # substitution — never in the substituted text — so a value passed
      # through `prompt_args` cannot introduce a new `` !`cmd` `` span.
      original_matches = @expansion_pattern |> Regex.scan(text) |> Enum.map(fn [full, cmd] -> {full, cmd} end) |> Enum.uniq()

      with {:ok, substituted} <- substitute(text, vars) do
        expand(substituted, original_matches, vars, sandbox)
      end
    end
  end

  defp check_reserved(prompt_args) do
    case Enum.find(@reserved_keys, &Map.has_key?(prompt_args, &1)) do
      nil ->
        :ok

      key ->
        {:error,
         Error.new(:prompt_arg_reserved, "prompt_args cannot set reserved key #{key}", %{key: key})}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, Error.new(:prompt_source_missing, "could not read prompt_file", %{path: path, reason: reason})}
    end
  end

  defp build_vars(context, prompt_args, sandbox) do
    builtins = %{"SOURCE_BRANCH" => sandbox.worktree.branch, "TARGET_BRANCH" => sandbox.worktree.target_branch || sandbox.worktree.branch}

    context
    |> normalize_vars()
    |> Map.merge(prompt_args)
    |> Map.merge(builtins)
  end

  defp normalize_vars(map) do
    Map.new(map, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp substitute(text, vars) do
    keys = @var_pattern |> Regex.scan(text) |> Enum.map(fn [_, k] -> k end) |> Enum.uniq()

    case Enum.find(keys, fn k -> not Map.has_key?(vars, k) end) do
      nil ->
        {:ok, Regex.replace(@var_pattern, text, fn _, k -> Map.fetch!(vars, k) end)}

      missing ->
        {:error, Error.new(:prompt_arg_missing, "prompt references undefined key #{missing}", %{key: missing})}
    end
  end

  defp expand(substituted_text, original_matches, vars, sandbox) do
    original_matches
    |> Enum.map(fn {_full, cmd} ->
      {:ok, cmd_sub} = substitute(cmd, vars)
      {"!`" <> cmd_sub <> "`", cmd_sub}
    end)
    |> Enum.uniq()
    |> Task.async_stream(fn {full, cmd} -> {full, cmd, Sandbox.exec(sandbox, cmd)} end,
      ordered: true,
      max_concurrency: max(System.schedulers_online(), 1)
    )
    |> Enum.reduce_while({:ok, substituted_text}, &reduce_expansion/2)
  end

  defp reduce_expansion({:ok, {full, _cmd, {:ok, %ExecResult{exit_code: 0, stdout: out}}}}, {:ok, acc}) do
    {:cont, {:ok, String.replace(acc, full, String.trim_trailing(out, "\n"), global: true)}}
  end

  defp reduce_expansion({:ok, {full, cmd, {:ok, %ExecResult{exit_code: code, stdout: out}}}}, _acc) do
    {:halt,
     {:error,
      Error.new(:prompt_expansion_failed, "prompt expansion command exited non-zero", %{
        command: cmd,
        token: full,
        exit_code: code,
        output: out
      })}}
  end

  defp reduce_expansion({:ok, {full, cmd, {:error, reason}}}, _acc) do
    {:halt,
     {:error,
      Error.new(:prompt_expansion_failed, "prompt expansion command failed to run", %{
        command: cmd,
        token: full,
        reason: reason
      })}}
  end
end
