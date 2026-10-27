defmodule ForemanServer.Workflow.BeadsTreeCompletion do
  @moduledoc """
  Whether the Beads tree an `implement-trd-beads` run was dispatched to execute
  is actually finished (PRD-2026-72f477ca REQ-008).

  The run hands its root epic bead (`implementation.bead_id`) to
  `ensemble-beads-build`. That skill is a prompt, not a program: it has no exit
  code and no machine-readable result. When it stops short (`EXECUTION BLOCKED`,
  a debug loop out of retries, a refused quality gate, a failed `br` call) the
  agent simply ends its turn, and to Foreman that is a phase that completed. The
  only durable signal that the tree is not done is the bead graph, so the run is
  judged on the graph:

    * a descendant is every bead reachable from the root through `parent-child`
      dependency edges (a `blocks` edge into another tree does not make that
      tree's beads part of this one — the same scope as `br show`'s `rollup`);
    * the tree is complete when every descendant is `closed`;
    * the root's OWN status is never consulted: an epic can stay `open` while
      every descendant is closed (`br` reports that as `rollup.status: "closed"`),
      and that run still completed — completion is judged by child-bead state, not
      by the epic's status field (AC-008-2);
    * a descendant closed by a human mid-run is closed, nothing more (AC-010-2).

  The graph is read fresh at the end of every phase; nothing is cached between
  attempts, so a resumed run is judged on the graph as it is then (AC-005-2).

  A tree that cannot be read is not a tree that was finished: `br` failing, or
  answering in a shape this module does not know, fails the run rather than
  passing it.
  """

  alias ForemanServer.AgentRuntime.JidoHarness.FailureCause
  alias ForemanServer.TaskProviders.ProviderError

  require Logger

  @runner Application.compile_env(
            :foreman_server,
            :br_runner,
            ForemanServer.TaskProviders.SystemBrRunner
          )

  @show_timeout_ms 30_000

  # How many incomplete children the one-line failure reason names. The full list
  # is in the run's artifact; the reason is bounded by `FailureCause.sanitize/2`.
  @inline_children 8

  defmodule Child do
    @moduledoc "A descendant bead of the tree's root, as `br show` reports it."

    @enforce_keys [:id, :title, :status]
    defstruct [:id, :title, :status]

    @type t :: %__MODULE__{id: String.t(), title: String.t(), status: String.t()}
  end

  @doc """
  Judges the run's tree.

  `plan_context` is the run's frozen implementation context (string keys). A run
  without a `bead_id` is not a Beads-tree run and has nothing to check (`:ok`).
  On an incomplete tree the incomplete children are appended to the phase
  artifact at `artifact_path` and named in the returned `FailureCause`.
  """
  @spec verify(map(), String.t() | nil) :: :ok | {:error, FailureCause.t()}
  def verify(plan_context, artifact_path) when is_map(plan_context) do
    case Map.get(plan_context, "bead_id") do
      nil ->
        :ok

      bead_id when is_binary(bead_id) and bead_id != "" ->
        verify_tree(bead_id, Map.get(plan_context, "beads_database_path"), artifact_path)

      other ->
        unverifiable("the frozen bead_id is not a non-empty string: #{inspect(other)}")
    end
  end

  defp verify_tree(bead_id, database_path, artifact_path)
       when is_binary(database_path) and database_path != "" do
    case incomplete_descendants(database_path, bead_id) do
      {:ok, []} ->
        :ok

      {:ok, incomplete} ->
        record_in_artifact(artifact_path, bead_id, incomplete)

        {:error,
         %FailureCause{
           code: :incomplete_children,
           detail: FailureCause.sanitize(describe(bead_id, incomplete), [])
         }}

      {:error, %ProviderError{code: code, message: message}} ->
        {:error,
         %FailureCause{
           code: :beads_tree_unreadable,
           detail: FailureCause.sanitize("#{code}: #{message}", [])
         }}
    end
  end

  defp verify_tree(_bead_id, other, _artifact_path),
    do:
      unverifiable("the frozen beads_database_path is not a non-empty string: #{inspect(other)}")

  defp unverifiable(detail),
    do: {:error, %FailureCause{code: :beads_tree_unverifiable, detail: detail}}

  @doc """
  The descendants of `root_id` that are not `closed`, in breadth-first order
  (level by level, each level in `br`'s order).

  One `br show` per level of the tree, however many beads the level holds.
  """
  @spec incomplete_descendants(String.t(), String.t()) ::
          {:ok, [Child.t()]} | {:error, ProviderError.t()}
  def incomplete_descendants(database_path, root_id)
      when is_binary(database_path) and is_binary(root_id) do
    with {:ok, descendants} <- walk(database_path, root_id, [root_id], MapSet.new([root_id]), []) do
      {:ok, Enum.reject(descendants, &(&1.status == "closed"))}
    end
  end

  # Breadth-first over `parent-child` edges. `seen` keeps a bead reachable through
  # two parents, or a corrupt cycle, from being visited twice.
  defp walk(_database_path, _root_id, [], _seen, found), do: {:ok, Enum.reverse(found)}

  defp walk(database_path, root_id, frontier, seen, found) do
    with {:ok, issues} <- show(database_path, root_id, frontier),
         {:ok, level} <- children(frontier, issues, root_id) do
      {next, seen, found} =
        Enum.reduce(level, {[], seen, found}, fn %Child{id: id} = child, {next, seen, found} ->
          if MapSet.member?(seen, id),
            do: {next, seen, found},
            else: {[id | next], MapSet.put(seen, id), [child | found]}
        end)

      walk(database_path, root_id, Enum.reverse(next), seen, found)
    end
  end

  # `br show <id>...` answers with one issue object per id, in a JSON array. A
  # missing id makes it exit non-zero (error envelope on stdout), so a short
  # answer is a contract break, not "no such beads".
  defp show(database_path, root_id, ids) do
    case @runner.cmd({:show, %{flags: ids}}, %{database_path: database_path},
           timeout_ms: @show_timeout_ms
         ) do
      {:ok, %{stdout: stdout}} when is_binary(stdout) ->
        parse_show(stdout, ids, root_id)

      {:error, %{} = result} ->
        {:error, read_error(root_id, ids, "br show failed: #{error_detail(result)}", result)}

      other ->
        {:error,
         read_error(
           root_id,
           ids,
           "br runner returned an unexpected shape: #{inspect(other)}",
           %{}
         )}
    end
  end

  defp parse_show(stdout, ids, root_id) do
    with {:ok, issues} when is_list(issues) <- Jason.decode(stdout),
         by_id = for(%{"id" => id} = issue <- issues, is_binary(id), into: %{}, do: {id, issue}),
         [] <- ids -- Map.keys(by_id) do
      {:ok, by_id}
    else
      {:ok, other} ->
        {:error, read_error(root_id, ids, "br show returned #{inspect(other, limit: 3)}", %{})}

      {:error, %Jason.DecodeError{}} ->
        {:error, read_error(root_id, ids, "br show returned output that is not JSON", %{})}

      [_ | _] = missing ->
        {:error,
         read_error(root_id, ids, "br show did not return #{Enum.join(missing, ", ")}", %{})}
    end
  end

  # The `parent-child` dependents of every bead in the level. Other dependents
  # (`blocks`, `related`, ...) are edges to beads that are not part of this tree.
  defp children(frontier, issues, root_id) do
    Enum.reduce_while(frontier, {:ok, []}, fn id, {:ok, level} ->
      case issues |> Map.fetch!(id) |> parent_children() do
        {:ok, children} -> {:cont, {:ok, level ++ children}}
        {:error, detail} -> {:halt, {:error, read_error(root_id, [id], detail, %{})}}
      end
    end)
  end

  # `br show` omits `dependents` for a bead that has none.
  defp parent_children(issue) do
    case Map.get(issue, "dependents") do
      nil -> {:ok, []}
      dependents when is_list(dependents) -> collect_children(dependents)
      other -> {:error, "dependents is not a list: #{inspect(other, limit: 3)}"}
    end
  end

  defp collect_children(dependents) do
    Enum.reduce_while(dependents, {:ok, []}, fn
      %{"dependency_type" => "parent-child"} = dependent, {:ok, children} ->
        case dependent do
          %{"id" => id, "title" => title, "status" => status}
          when is_binary(id) and is_binary(title) and is_binary(status) ->
            {:cont, {:ok, children ++ [%Child{id: id, title: title, status: status}]}}

          other ->
            {:halt, {:error, "a parent-child dependent lacks id/title/status: #{inspect(other)}"}}
        end

      _not_a_child_edge, acc ->
        {:cont, acc}
    end)
  end

  defp read_error(root_id, ids, message, result) do
    context = Map.merge(%{id: root_id}, exit_code(result))

    ProviderError.new(
      "BEADS_TREE_UNREADABLE",
      "reading #{length(ids)} bead(s) under #{root_id}: #{message}",
      hint: "Check the Beads database and the installed br version, then retry the task.",
      retryable?: false,
      context: context
    )
  end

  defp exit_code(%{exit_code: code}) when is_integer(code), do: %{exit_code: code}
  defp exit_code(_result), do: %{}

  # br puts its JSON error envelope on stdout for `show` (exit 3, ISSUE_NOT_FOUND)
  # and plain text on stderr for everything else.
  defp error_detail(result) do
    stdout = to_string(Map.get(result, :stdout, ""))
    stderr = to_string(Map.get(result, :stderr, ""))

    cond do
      message = envelope_message(stdout) -> message
      message = envelope_message(stderr) -> message
      String.trim(stderr) != "" -> String.trim(stderr)
      reason = Map.get(result, :reason) -> inspect(reason)
      true -> "exit code #{inspect(Map.get(result, :exit_code))}"
    end
  end

  defp envelope_message(text) do
    case Jason.decode(text) do
      {:ok, %{"error" => %{"code" => code, "message" => message}}}
      when is_binary(code) and is_binary(message) ->
        "#{code}: #{message}"

      _not_an_envelope ->
        nil
    end
  end

  defp describe(root_id, incomplete) do
    {named, rest} = Enum.split(incomplete, @inline_children)

    listed = Enum.map_join(named, ", ", &"#{&1.id} (#{&1.status})")

    more =
      case length(rest) do
        0 -> ""
        n -> ", and #{n} more (all of them are listed in the phase artifact)"
      end

    "#{length(incomplete)} descendant bead(s) of #{root_id} are not closed: #{listed}#{more}"
  end

  # The full list goes where the operator looks first: the phase's report, whose
  # path `RunExecutor` hands the provider's failure comment. Failing to write it
  # never hides the failure being reported, so it only logs.
  defp record_in_artifact(nil, _root_id, _incomplete), do: :ok

  defp record_in_artifact(artifact_path, root_id, incomplete) do
    section = [
      "\n\n## Incomplete children of #{root_id}\n\n",
      "`ensemble-beads-build` ended with these descendants of `#{root_id}` not closed:\n\n",
      Enum.map(incomplete, fn child ->
        "- `#{child.id}` (#{child.status}): #{String.replace(child.title, ~r/\s+/, " ")}\n"
      end)
    ]

    case File.write(artifact_path, section, [:append]) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "BeadsTreeCompletion could not append the incomplete children of #{root_id} " <>
            "to #{artifact_path}: #{inspect(reason)}"
        )
    end
  end
end
