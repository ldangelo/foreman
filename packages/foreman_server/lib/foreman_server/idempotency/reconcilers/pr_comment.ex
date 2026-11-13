defmodule ForemanServer.Idempotency.Reconcilers.PrComment do
  @moduledoc """
  The `pr_comment` effect class (TRD-020): how the PR report comment is keyed, what its
  intent records and how an interrupted post is reconciled.

  ## Key and intent

  The key is `effect:pr_comment:<run_id>:<head_sha>:<digest>` (`key/3`), so a new head or a
  new digest is a new effect. A settled key is run again (`Effect` treats `completed` and
  `failed` as clear), so the key alone does not stop a second comment: the folded
  `evidence.report`, a marker lookup before any write and this reconciler do (TRD-021).
  `intent/4` is the metadata `Effect.run/4` records: `run_id`, `pr_url`, `head_sha` and
  `digest`, with no `cwd` (the comment is written by URL, no checkout is needed).

  ## Reconciliation

  `reconcile/2` lists the PR's comments (`GitHub.PrComment.list/2`, bounded by `Command`,
  `opts[:timeout_ms]`, default 30 s: the sweep waits on it) and answers:

    * `:done`: a comment written by the token's own user (`viewer_did_author`: a marker typed
      by anyone else proves nothing) whose first line is the marker for this run, head and
      digest (`PrReport.parse_marker/1`);
    * `:not_done`: the list was read completely and holds no such comment;
    * `:unknown`: incomplete metadata, or a failed, timed-out or unparsable answer. Never
      `:not_done`: a post that may have happened is not posted again on a guess.

  `repeatable?/1` is true and `blocks_run?/1` false (TRD-002, honoured by the sweep from
  TRD-039): a comment must never block, cancel or refuse a run, so a `done` or `unknown`
  verdict marks nothing and counts the key skipped, while `not_done` decides the key like
  any other.

  Production caller: none until the publisher (TRD-021) wraps its post in
  `Effect.run(:pr_comment, key/3, fun, intent/4)`. The registry entry is in
  `config/config.exs`; the boot sweep reaches `reconcile/1` through it.
  """

  @behaviour ForemanServer.Idempotency.Reconciler

  alias ForemanServer.GitHub.PrComment
  alias ForemanServer.Idempotency.Reconciler
  alias ForemanServer.PrReport

  require Logger

  @doc """
  The effect key of the report for `head_sha` and `digest` of `run_id`: a new head or a new
  digest is a new effect. Neither a head SHA nor a digest contains `:`.
  """
  @spec key(String.t(), String.t(), String.t()) :: String.t()
  def key(run_id, head_sha, digest),
    do: ForemanServer.Idempotency.Effect.key(:pr_comment, run_id, "#{head_sha}:#{digest}")

  @doc "The metadata of a PR comment's intent. Pass it to `Effect.run(:pr_comment, key, fun, meta)`."
  @spec intent(String.t(), String.t(), String.t(), String.t()) :: map()
  def intent(run_id, pr_url, head_sha, digest),
    do: %{run_id: run_id, pr_url: pr_url, head_sha: head_sha, digest: digest}

  @impl Reconciler
  def reconcile(metadata), do: reconcile(metadata, [])

  @doc """
  `reconcile/1` with `command_runner: runner` to replace `System.cmd/3` and `timeout_ms: ms`
  to replace the bound on the `gh` call (default `Command.default_timeout_ms/0`).
  """
  @spec reconcile(map(), keyword()) :: Reconciler.verdict()
  def reconcile(metadata, opts) when is_map(metadata) and is_list(opts) do
    with {:ok, pr_url} <- text(metadata, "pr_url"),
         {:ok, head_sha} <- text(metadata, "head_sha"),
         {:ok, digest} <- text(metadata, "digest"),
         run_id when is_binary(run_id) and run_id != "" <- metadata["run_id"] do
      list_opts = Keyword.take(opts, [:command_runner, :timeout_ms])

      case PrComment.list(pr_url, list_opts) do
        {:ok, comments} ->
          if Enum.any?(comments, &own_marker?(&1, run_id, head_sha, digest)),
            do: :done,
            else: :not_done

        {:error, reason} ->
          unknown(metadata, reason)
      end
    else
      {:error, field} -> unknown(metadata, {:incomplete_metadata, field})
      _ -> unknown(metadata, {:incomplete_metadata, "run_id"})
    end
  end

  @impl Reconciler
  def repeatable?(_metadata), do: true

  @impl Reconciler
  def blocks_run?(_metadata), do: false

  defp own_marker?(%{viewer_did_author: true, body: body}, run_id, head_sha, digest)
       when is_binary(body) do
    PrReport.parse_marker(body) ==
      {:ok, %{run_id: run_id, head_sha: head_sha, digest: digest}}
  end

  defp own_marker?(_comment, _run_id, _head_sha, _digest), do: false

  defp unknown(metadata, reason) do
    Logger.warning(
      "PrComment reconciler: cannot tell whether the report was posted: " <>
        "#{inspect(reason)}",
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
