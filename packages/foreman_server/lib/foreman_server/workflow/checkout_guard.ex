defmodule ForemanServer.Workflow.CheckoutGuard do
  @moduledoc """
  Fails a run whose work landed in the main checkout instead of its worktree
  (foreman-koas6).

  A worker that is handed (or infers) the checkout's absolute path writes there,
  not into the run's worktree. The thread completes, the run's branch has no
  commit, and `git show` of it is empty: nothing in the exit status says so
  (foreman-2onq1 fixed the prompt that caused it; this is the deterministic
  backstop).

  ## When it applies

  Only to a run whose workflow was EXPECTED to commit: at least one phase declares
  `commit: true` explicitly (`expected?/1`). An absent `commit:` also means "commit" to
  `RunExecutor.phase_commits?/1`, but that default is not an expectation: `assess` declares
  nothing and writes its report outside the worktree, so an empty branch is its normal
  outcome. A workflow whose every phase says `commit: false`, or says nothing, is never
  guarded. Of the bundled workflows, `fix`, `implement-trd`, `implement-trd-beads`, `prd` and
  `review` declare `commit: true` (guarded); `assess` declares none (not guarded).

  ## What is compared

  `snapshot/1` records the checkout's `git status --porcelain` entries (path ->
  status code, size, mtime) when the run's worktree is first provisioned, BEFORE
  any agent runs. `verify/2` re-reads them after the last phase and fails the run
  only when BOTH hold:

    1. the run's worktree is empty: its branch has no commit past the base the
       run was cut from AND the worktree itself is clean (uncommitted work in the
       worktree is the worktree being written, `commit: false` deferral included);
    2. the checkout gained entries since the snapshot: a path that was not in the
       snapshot, or whose status/size/mtime differs from it. A dirty checkout the
       operator was already editing is therefore not "gained" - only changes that
       happened during the run window count. `.beads/` is excluded (the beads
       watcher and `br` write there for reasons unrelated to a worker).

  The failure is a `FailureCause` with code `:checkout_written_instead_of_worktree`
  naming the files.

  ## What it cannot detect

    * A workflow with no explicit `commit: true` phase (see above).
    * A run that DID commit in its worktree and also wrote elsewhere in the
      checkout: its branch is not empty, so this is not the silent-empty failure.
    * An operator editing the checkout during a run of a committing workflow whose
      agent legitimately changed nothing (for example a review that found nothing):
      indistinguishable by status alone, so such a run is failed and the reason
      names the files for the operator to judge. A run that commits is never failed,
      whatever the operator does.
    * A write that leaves the checkout's status unchanged (an ignored path, or a
      byte-identical rewrite of a tracked file).
    * Resumed runs: the snapshot lives in executor memory, so a resumed executor
      takes none and the guard stays silent.
    * Writes to a secondary repository's checkout (multi-repo runs): only the
      primary is checked.
  """

  alias ForemanServer.AgentRuntime.JidoHarness.FailureCause

  @inline_files 8
  @ignored_prefixes [".beads/"]

  @enforce_keys [:checkout, :base_ref, :entries]
  defstruct [:checkout, :base_ref, :entries]

  @type entry :: {status :: String.t(), size :: non_neg_integer() | nil, mtime :: integer() | nil}
  @type t :: %__MODULE__{
          checkout: String.t(),
          base_ref: String.t(),
          entries: %{String.t() => entry()}
        }

  @doc """
  Whether the workflow was expected to commit: some phase declares `commit: true`
  explicitly. `phase_specs` are normalized `PhaseSpec` maps, where an absent `commit:` is
  `nil` (`RunExecutor.phase_commits?/1` treats that as commit, which is a default, not an
  expectation).
  """
  @spec expected?([map()]) :: boolean()
  def expected?(phase_specs) when is_list(phase_specs),
    do: Enum.any?(phase_specs, &(Map.get(&1, :commit) == true))

  @doc "Records the checkout's status entries and the base the run is cut from."
  @spec snapshot(%{project_root: String.t(), base_ref: String.t()}) ::
          {:ok, t()} | {:error, term()}
  def snapshot(%{project_root: root, base_ref: base_ref})
      when is_binary(root) and root != "" and is_binary(base_ref) and base_ref != "" do
    with {:ok, entries} <- status_entries(root) do
      {:ok, %__MODULE__{checkout: root, base_ref: base_ref, entries: entries}}
    end
  end

  @doc """
  Judges the run against its snapshot. `record` is the run's worktree record
  (`worktree_path`, `branch`). A `nil` snapshot (resumed run) passes.
  """
  @spec verify(t() | nil, %{worktree_path: String.t(), branch: String.t()}) ::
          :ok | {:error, FailureCause.t()}
  def verify(nil, _record), do: :ok

  def verify(%__MODULE__{} = snap, %{worktree_path: path, branch: branch})
      when is_binary(path) and is_binary(branch) do
    with {:ok, true} <- worktree_empty?(snap, path, branch),
         {:ok, current} <- status_entries(snap.checkout),
         [_ | _] = gained <- gained_paths(snap.entries, current) do
      {:error,
       %FailureCause{
         code: :checkout_written_instead_of_worktree,
         detail: FailureCause.sanitize(describe(snap, path, gained), [])
       }}
    else
      {:ok, false} -> :ok
      [] -> :ok
      {:error, reason} -> {:error, unverifiable(snap, reason)}
    end
  end

  defp gained_paths(before, current) do
    current
    |> Enum.reject(fn {file, entry} -> Map.get(before, file) == entry end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp worktree_empty?(snap, path, branch) do
    with {:ok, count} <-
           git(snap.checkout, ["rev-list", "--count", "#{snap.base_ref}..#{branch}"]),
         {:ok, dirty} <- git(path, ["status", "--porcelain"]) do
      {:ok, String.trim(count) == "0" and String.trim(dirty) == ""}
    end
  end

  defp status_entries(root) do
    with {:ok, out} <-
           git(root, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]) do
      {:ok,
       out
       |> String.split(<<0>>, trim: true)
       |> parse_status([])
       |> Enum.reject(fn {file, _} ->
         Enum.any?(@ignored_prefixes, &String.starts_with?(file, &1))
       end)
       |> Map.new(fn {file, code} ->
         {file, {code, stat_size(root, file), stat_mtime(root, file)}}
       end)}
    end
  end

  # `-z` porcelain v1: "XY path"; a rename/copy is followed by its origin path as a
  # separate NUL field, which is not an entry.
  defp parse_status([], acc), do: acc

  defp parse_status([<<x, y, ?\s, file::binary>> | rest], acc) when x in [?R, ?C] do
    parse_status(Enum.drop(rest, 1), [{file, <<x, y>>} | acc])
  end

  defp parse_status([<<x, y, ?\s, file::binary>> | rest], acc),
    do: parse_status(rest, [{file, <<x, y>>} | acc])

  defp parse_status([_other | rest], acc), do: parse_status(rest, acc)

  defp stat_size(root, file), do: stat(root, file, :size)
  defp stat_mtime(root, file), do: stat(root, file, :mtime)

  defp stat(root, file, key) do
    case File.stat(Path.join(root, file), time: :posix) do
      {:ok, st} -> Map.fetch!(st, key)
      {:error, _} -> nil
    end
  end

  defp git(dir, args) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, {:git_failed, args, code, String.trim(out)}}
    end
  end

  defp describe(snap, worktree, gained) do
    shown = gained |> Enum.take(@inline_files) |> Enum.join(", ")
    more = length(gained) - @inline_files
    more_text = if more > 0, do: " (+#{more} more)", else: ""

    "a worker wrote into the main checkout #{snap.checkout} instead of the run's worktree: " <>
      "#{length(gained)} file(s) appeared or changed there during the run (#{shown}#{more_text}) " <>
      "while the worktree #{worktree} has no commit and no changes. " <>
      "The work is in the checkout, not on the run's branch."
  end

  defp unverifiable(snap, reason) do
    %FailureCause{
      code: :checkout_guard_unverifiable,
      detail:
        FailureCause.sanitize(
          "could not compare the checkout #{snap.checkout} with the run's worktree: #{inspect(reason)}",
          []
        )
    }
  end
end
