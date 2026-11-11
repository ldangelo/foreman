defmodule ForemanServer.Idempotency.Reconcilers.BranchPush do
  @moduledoc """
  The `branch_push` effect class (TRD-013): how a `git push` is keyed, what its
  intent records, and how an interrupted one is reconciled.

  ## Intent

  `intent/4` reads, before the push runs, the two SHAs the reconciler later
  compares the remote against, and returns the metadata `Effect.run/4` writes
  into the `started` key (`AutoPR` and `PhasePR` pass it straight through):

    * `pre_push_remote_sha` - the remote branch head as it stands
      (`git ls-remote origin refs/heads/<head_branch>`); `nil` for a branch the
      remote does not have yet;
    * `pushed_local_sha` - the local tip being pushed
      (`git rev-parse --verify refs/heads/<head_branch>`).

  Both are read in the push's `cwd`. When either cannot be read, or there is no
  `cwd`, the intent is not recorded and the push does not run
  (`{:error, {:intent_not_recorded, reason}}`).

  ## Reconciliation

  `reconcile/2` re-reads the remote ref in the key's `cwd` (never the server's
  working directory) and applies these clauses in order:

    1. `pre_push_remote_sha` equal to `pushed_local_sha`: origin already held the
       tip, the push was a no-op, re-pushing changes nothing: `:not_done`,
       whatever the remote ref is now (it is not even read);
    2. the remote ref equal to `pushed_local_sha`: `:done`;
    3. the remote ref equal to `pre_push_remote_sha` (both absent counts as
       equal): `:not_done`;
    4. anything else (another commit landed, the ref cannot be read, the
       metadata is incomplete): `:unknown`.

  `git` runs through a 3-arity runner (`opts[:command_runner]`, default
  `System.cmd/3`) with `cd:` the key's `cwd`. The registry entry is in
  `config/config.exs`; `ForemanServer.Idempotency.Reconciler` calls
  `reconcile/1` from the boot sweep.
  """

  @behaviour ForemanServer.Idempotency.Reconciler

  alias ForemanServer.Idempotency.Effect
  alias ForemanServer.Idempotency.Reconciler

  require Logger

  @type runner :: (String.t(), [String.t()], keyword() -> {String.t(), integer()})

  @sha ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/

  @doc "The effect key of the push of `head_branch` by `run_id`: stable across attempts."
  @spec key(String.t(), String.t()) :: String.t()
  def key(run_id, head_branch), do: Effect.key(:branch_push, run_id, head_branch)

  @doc """
  The metadata of a push's intent key, with the two SHAs read through `runner`
  in `cwd`. Pass it to `Effect.run(:branch_push, key(run_id, head_branch), fun, meta)`.
  """
  @spec intent(runner(), String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, {:intent_not_recorded, term()}}
  def intent(_runner, _run_id, _head_branch, cwd) when not is_binary(cwd) or cwd == "",
    do: {:error, {:intent_not_recorded, :cwd_missing}}

  def intent(runner, run_id, head_branch, cwd) do
    with {:ok, local_sha} <- local_head(runner, head_branch, cwd),
         {:ok, remote_sha} <- remote_head(runner, head_branch, cwd) do
      {:ok,
       %{
         run_id: run_id,
         head_branch: head_branch,
         cwd: cwd,
         pre_push_remote_sha: remote_sha,
         pushed_local_sha: local_sha
       }}
    else
      {:error, reason} -> {:error, {:intent_not_recorded, reason}}
    end
  end

  @impl Reconciler
  def reconcile(metadata), do: reconcile(metadata, [])

  @doc "`reconcile/1` with `command_runner: runner` to replace `System.cmd/3`."
  @spec reconcile(map(), keyword()) :: Reconciler.verdict()
  def reconcile(metadata, opts) when is_map(metadata) and is_list(opts) do
    case fields(metadata) do
      {:ok, %{pre: same, pushed: same}} ->
        :not_done

      {:ok, fields} ->
        runner = Keyword.get(opts, :command_runner) || (&System.cmd/3)
        decide(fields, remote_head(runner, fields.head_branch, fields.cwd), metadata)

      {:error, reason} ->
        unknown(metadata, {:incomplete_metadata, reason})
    end
  end

  defp decide(%{pushed: pushed}, {:ok, pushed}, _metadata), do: :done
  defp decide(%{pre: pre}, {:ok, pre}, _metadata), do: :not_done

  defp decide(%{head_branch: head_branch}, {:ok, remote}, metadata),
    do: unknown(metadata, {:remote_head_unexpected, head_branch, remote})

  defp decide(_fields, {:error, reason}, metadata), do: unknown(metadata, reason)

  defp unknown(metadata, reason) do
    Logger.warning(
      "BranchPush reconciler: cannot tell whether the push of #{inspect(metadata["head_branch"])} " <>
        "landed: #{inspect(reason)}",
      run_id: metadata["run_id"]
    )

    :unknown
  end

  defp fields(metadata) do
    with {:ok, head_branch} <- text(metadata, "head_branch"),
         {:ok, cwd} <- text(metadata, "cwd"),
         {:ok, pushed} <- text(metadata, "pushed_local_sha"),
         {:ok, pre} <- optional_text(metadata, "pre_push_remote_sha") do
      {:ok,
       %{
         head_branch: head_branch,
         cwd: cwd,
         pushed: normalize(pushed),
         pre: pre && normalize(pre)
       }}
    end
  end

  defp text(metadata, field) do
    case Map.get(metadata, field) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, field}
    end
  end

  # An absent pre-push SHA is a branch the remote did not have; anything that is
  # present and not a string is a malformed record, not an absent one.
  defp optional_text(metadata, field) do
    case Map.get(metadata, field) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, field}
    end
  end

  defp normalize(sha), do: sha |> String.trim() |> String.downcase()

  defp local_head(runner, head_branch, cwd) do
    case call(runner, "git", ["rev-parse", "--verify", "refs/heads/" <> head_branch], cwd) do
      {:ok, {output, 0}} ->
        sha = normalize(output)

        if Regex.match?(@sha, sha),
          do: {:ok, sha},
          else: {:error, {:local_head_unreadable, {:unparsable, String.trim(output)}}}

      {:ok, {output, code}} ->
        {:error, {:local_head_unreadable, {code, String.trim(output)}}}

      {:error, reason} ->
        {:error, {:local_head_unreadable, reason}}
    end
  end

  # `{:ok, sha}` for a branch the remote has, `{:ok, nil}` for one it does not.
  defp remote_head(runner, head_branch, cwd) do
    ref = "refs/heads/" <> head_branch

    case call(runner, "git", ["ls-remote", "origin", ref], cwd) do
      {:ok, {output, 0}} -> parse_remote(output, ref)
      {:ok, {output, code}} -> {:error, {:remote_head_unreadable, {code, String.trim(output)}}}
      {:error, reason} -> {:error, {:remote_head_unreadable, reason}}
    end
  end

  # `git ls-remote <pattern>` matches the tail of a ref, so the line is picked by
  # its exact ref name; stderr is merged into the output and its lines are skipped.
  defp parse_remote(output, ref) do
    output
    |> String.split("\n", trim: true)
    |> Enum.find_value({:ok, nil}, fn line ->
      case String.split(String.trim_trailing(line), "\t", parts: 2) do
        [sha, ^ref] ->
          sha = normalize(sha)

          if Regex.match?(@sha, sha),
            do: {:ok, sha},
            else: {:error, {:remote_head_unreadable, {:unparsable, String.trim(line)}}}

        _ ->
          nil
      end
    end)
  end

  defp call(runner, executable, args, cwd) do
    case runner.(executable, args, cd: cwd, stderr_to_stdout: true) do
      {output, code} when is_binary(output) and is_integer(code) -> {:ok, {output, code}}
      other -> {:error, {:unexpected_runner_result, other}}
    end
  rescue
    error in ErlangError -> {:error, {:command_not_run, executable, error.original}}
  end
end
