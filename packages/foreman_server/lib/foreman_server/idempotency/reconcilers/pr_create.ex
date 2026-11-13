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
  created. A PR in any state is `:done`, none is `:not_done`, and a failed, timed out,
  unparsable or unexpected answer (or incomplete metadata) is `:unknown`.

  `gh` runs through a 3-arity runner (`opts[:command_runner]`, default
  `System.cmd/3`), bounded by `opts[:timeout_ms]` (default 30 s, see
  `Reconcilers.Command`) because the boot sweep waits on it. The registry entry is
  in `config/config.exs`; `ForemanServer.Idempotency.Reconciler` calls
  `reconcile/1` from the boot sweep.
  """

  @behaviour ForemanServer.Idempotency.Reconciler

  alias ForemanServer.Idempotency.Effect
  alias ForemanServer.Idempotency.KeyStore
  alias ForemanServer.Idempotency.Reconciler
  alias ForemanServer.Idempotency.Reconcilers.Command

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

  @doc """
  GitHub has answered for the run's PR create (the run adopted the PR it found), so a key an
  earlier attempt left `started` or `ambiguous` is settled `completed`, with what recovery
  wrote on it (the unresolved marker, the decision) cleared: the doctor does not list it, and
  a later Create PR after the PR was closed is not refused for good. A key that is absent or
  already settled is left alone.
  """
  @spec settle_adopted(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def settle_adopted(run_id, head_branch, base_branch) do
    key = key(run_id, head_branch, base_branch)

    case KeyStore.get(key) do
      {:ok, %{status: status}} when status in [:started, :ambiguous] ->
        case KeyStore.mark_completed(key, KeyStore.recovery_fields_cleared()) do
          # Settled between the read and the write: left alone, like an already settled key.
          :status_changed -> :ok
          other -> other
        end

      :not_found ->
        :ok

      {:ok, %{status: _settled}} ->
        :ok
    end
  catch
    :exit, reason -> {:error, {:key_store_unavailable, reason}}
  end

  @impl Reconciler
  def reconcile(metadata), do: reconcile(metadata, [])

  @doc """
  `reconcile/1` with `command_runner: runner` to replace `System.cmd/3` and
  `timeout_ms: ms` to replace the bound on the `gh` call (default
  `Command.default_timeout_ms/0`). A call that does not answer in time is `:unknown`.
  """
  @spec reconcile(map(), keyword()) :: Reconciler.verdict()
  def reconcile(metadata, opts) when is_map(metadata) and is_list(opts) do
    with {:ok, head_branch} <- text(metadata, "head_branch"),
         {:ok, base_branch} <- text(metadata, "base_branch"),
         {:ok, cwd} <- text(metadata, "cwd") do
      runner = Keyword.get(opts, :command_runner) || (&System.cmd/3)
      timeout_ms = Keyword.get(opts, :timeout_ms, Command.default_timeout_ms())

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

      case Command.run(runner, "gh", args, cd: cwd, timeout_ms: timeout_ms) do
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
end
