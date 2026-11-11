defmodule ForemanServer.Idempotency.Reconcilers.PrCreate do
  @moduledoc """
  The `pr_create` effect class (TRD-013): how a `gh pr create` is keyed, what its
  intent records, and how an interrupted one is reconciled. GitHub is the source
  of truth for whether the PR exists.

  ## Intent

  `intent/4` is the metadata of the `started` key `Effect.run/4` writes before
  `gh pr create` runs: `run_id`, `head_branch`, `base_branch` and `cwd` (the
  directory the reconciler runs `gh` in).

  ## Reconciliation

  `reconcile/2` asks GitHub, in the key's `cwd` (never the server's working
  directory):

      gh pr list --head <head> --base <base> --state all --json url,number,state

  `--state all` is required: `gh pr list` lists only open PRs by default, and a PR
  that was merged or closed before recovery ran is still the PR this effect
  created. A PR in any state is `:done`, none is `:not_done`, and a failed,
  unparsable or unexpected answer (or incomplete metadata) is `:unknown`.

  `gh` runs through a 3-arity runner (`opts[:command_runner]`, default
  `System.cmd/3`). The registry entry is in `config/config.exs`;
  `ForemanServer.Idempotency.Reconciler` calls `reconcile/1` from the boot sweep.
  """

  @behaviour ForemanServer.Idempotency.Reconciler

  alias ForemanServer.Idempotency.Effect
  alias ForemanServer.Idempotency.Reconciler

  require Logger

  @type runner :: (String.t(), [String.t()], keyword() -> {String.t(), integer()})

  @doc """
  The effect key of the PR from `head_branch` into `base_branch` for `run_id`:
  stable across attempts. Git ref names cannot contain `:`, so `head:base` is
  unambiguous.
  """
  @spec key(String.t(), String.t(), String.t()) :: String.t()
  def key(run_id, head_branch, base_branch),
    do: Effect.key(:pr_create, run_id, "#{head_branch}:#{base_branch}")

  @doc """
  The metadata of a PR create's intent key. Pass it to
  `Effect.run(:pr_create, key(run_id, head, base), fun, meta)`, which refuses a
  missing `cwd`.
  """
  @spec intent(String.t(), String.t(), String.t(), String.t() | nil) :: map()
  def intent(run_id, head_branch, base_branch, cwd),
    do: %{run_id: run_id, head_branch: head_branch, base_branch: base_branch, cwd: cwd}

  @impl Reconciler
  def reconcile(metadata), do: reconcile(metadata, [])

  @doc "`reconcile/1` with `command_runner: runner` to replace `System.cmd/3`."
  @spec reconcile(map(), keyword()) :: Reconciler.verdict()
  def reconcile(metadata, opts) when is_map(metadata) and is_list(opts) do
    with {:ok, head_branch} <- text(metadata, "head_branch"),
         {:ok, base_branch} <- text(metadata, "base_branch"),
         {:ok, cwd} <- text(metadata, "cwd") do
      runner = Keyword.get(opts, :command_runner) || (&System.cmd/3)

      args = [
        "pr",
        "list",
        "--head",
        head_branch,
        "--base",
        base_branch,
        "--state",
        "all",
        "--json",
        "url,number,state"
      ]

      case call(runner, args, cwd) do
        {:ok, {output, 0}} -> verdict(output, metadata)
        {:ok, {output, code}} -> unknown(metadata, {:gh_failed, code, String.trim(output)})
        {:error, reason} -> unknown(metadata, reason)
      end
    else
      {:error, field} -> unknown(metadata, {:incomplete_metadata, field})
    end
  end

  defp verdict(output, metadata) do
    case Jason.decode(String.trim(output)) do
      {:ok, []} ->
        :not_done

      {:ok, [_ | _] = prs} ->
        if Enum.any?(prs, &pr?/1),
          do: :done,
          else: unknown(metadata, {:unexpected_pr_list, String.slice(output, 0, 200)})

      {:ok, _other} ->
        unknown(metadata, {:unexpected_pr_list, String.slice(output, 0, 200)})

      {:error, _} ->
        unknown(metadata, {:unparsable_pr_list, String.slice(output, 0, 200)})
    end
  end

  defp pr?(%{"url" => url}) when is_binary(url), do: url != ""
  defp pr?(_), do: false

  defp unknown(metadata, reason) do
    Logger.warning(
      "PrCreate reconciler: cannot tell whether the PR for #{inspect(metadata["head_branch"])} " <>
        "into #{inspect(metadata["base_branch"])} exists: #{inspect(reason)}",
      run_id: metadata["run_id"]
    )

    :unknown
  end

  defp text(metadata, field) do
    case Map.get(metadata, field) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, field}
    end
  end

  defp call(runner, args, cwd) do
    case runner.("gh", args, cd: cwd, stderr_to_stdout: true) do
      {output, code} when is_binary(output) and is_integer(code) -> {:ok, {output, code}}
      other -> {:error, {:unexpected_runner_result, other}}
    end
  rescue
    error in ErlangError -> {:error, {:command_not_run, "gh", error.original}}
  end
end
