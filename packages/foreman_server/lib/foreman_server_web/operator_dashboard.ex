defmodule ForemanServerWeb.OperatorDashboard do
  @moduledoc """
  Projection-backed context for the operator run dashboard.

  This module is the boundary between the LiveView and Foreman's read/write
  contracts: reads come from `ProjectionStore`; run-control mutations go
  through `CommandGateway.dispatch_operator/1`.
  """

  alias ForemanServer.ProjectionStore
  alias ForemanServerWeb.OperatorDashboard.ChangeEvidence

  @default_limit 100
  @max_limit 250
  @default_gateway ForemanServer.CommandGateway

  defmodule RunDTO do
    @moduledoc false
    @enforce_keys [:run_id, :status]
    defstruct [
      :run_id,
      :project_id,
      :status,
      :workflow,
      :task_id,
      :task_label,
      :current_phase_id,
      :current_phase_name,
      :current_phase_status,
      :started_at_ms,
      :last_event_at_ms,
      :latest_stall,
      :pr_url,
      :pr_marker,
      :terminal?,
      :failure_reason,
      :actions
    ]
  end

  defmodule DetailDTO do
    @moduledoc false
    @enforce_keys [:run]
    defstruct [
      :run,
      phases: [],
      task: :absent,
      logs: :absent,
      # loaded lazily by the LiveView
      changes: :absent,
      worktrees: [],
      pr_association: :absent
    ]
  end

  @doc "List run rows with bounded filters."
  def list_runs(params \\ %{}) do
    case query_opts(params) do
      {:ok, opts} ->
        rows =
          opts
          |> ProjectionStore.list_runs()
          |> Enum.map(&run_dto/1)

        {:ok, rows}

      {:error, _} = error ->
        error
    end
  end

  @doc "Load full dashboard detail for one run."
  def run_detail(run_id) when is_binary(run_id) and run_id != "" do
    case ProjectionStore.run(run_id) do
      nil ->
        {:error, :run_not_found}

      run ->
        phases = ProjectionStore.phases_for_run(run_id)
        task = task_for_run(run)
        logs = ProjectionStore.run_logs(run_id)
        worktrees = ProjectionStore.worktrees_for_run(run_id)
        pr_association = pr_association(run_id)

        {:ok,
         %DetailDTO{
           run: run_dto(run, phases),
           phases: Enum.map(phases, &phase_dto/1),
           task: task,
           logs: logs,
           worktrees: worktrees,
           pr_association: pr_association
         }}
    end
  end

  def run_detail(_), do: {:error, :run_not_found}

  def run_logs(run_id) when is_binary(run_id) and run_id != "" do
    ProjectionStore.run_logs(run_id)
  end

  def change_evidence(run_id) when is_binary(run_id) and run_id != "" do
    ChangeEvidence.for_run(run_id)
  end

  @doc "Action eligibility matrix used by UI and tests."
  def actions_for_status(status) do
    normalized = to_string(status || "")

    %{
      stop: %{
        enabled: normalized in ["awaiting_worker", "in_progress", "needs_recovery"],
        command: "run.pause"
      },
      abandon: %{enabled: normalized not in ["deleted", "removed"], command: "run.remove"},
      resume: %{enabled: normalized == "paused", command: "run.resume"},
      reset: %{enabled: normalized in ["failed", "stuck", "needs_recovery"], command: "run.reset"}
    }
  end

  def pause_run(run_id, reason \\ nil, idempotency_key \\ nil),
    do: dispatch_action("run.pause", run_id, reason || "operator_pause", idempotency_key)

  def resume_run(run_id, reason \\ nil, idempotency_key \\ nil),
    do: dispatch_action("run.resume", run_id, reason || "operator_resume", idempotency_key)

  def remove_run(run_id, reason \\ nil, idempotency_key \\ nil),
    do: dispatch_action("run.remove", run_id, reason || "operator_abandon", idempotency_key)

  def reset_run(run_id, reason \\ nil, idempotency_key \\ nil),
    do: dispatch_action("run.reset", run_id, reason || "operator_reset", idempotency_key)

  @doc """
  Dispatch a run-control command. `idempotency_key`, when supplied by the
  caller, is reused verbatim as the command-id suffix so a client-side retry
  of the SAME confirmed operator intent (e.g. a LiveView reconnect resending
  an unacknowledged click) produces the same `command_id` and is deduplicated
  by `CommandRouter`. Omit it to get a fresh one-shot id (default; matches
  prior behavior for callers that don't track intent identity).
  """
  def dispatch_action(type, run_id, reason, idempotency_key \\ nil)

  def dispatch_action(type, run_id, reason, idempotency_key)
      when is_binary(run_id) and run_id != "" do
    clean_reason = non_blank(reason, default_reason(type))

    envelope = %{
      type: type,
      command_id: command_id(type, run_id, idempotency_key),
      aggregate_id: "run:" <> run_id,
      payload: %{run_id: run_id, reason: clean_reason, actor: "operator_dashboard"}
    }

    case command_gateway().dispatch_operator(envelope) do
      {:ok, result} -> {:ok, %{command: envelope, result: result}}
      {:error, reason} -> {:error, reason, envelope}
      {:error, reason, detail} -> {:error, {reason, detail}, envelope}
    end
  end

  def dispatch_action(_type, _run_id, _reason, _idempotency_key), do: {:error, :run_not_found}

  defp command_gateway do
    Application.get_env(:foreman_server, :command_gateway_module, @default_gateway)
  end

  defp command_id(type, run_id, idempotency_key) do
    suffix = idempotency_key || System.unique_integer([:positive, :monotonic])
    "dashboard:#{type}:#{run_id}:#{suffix}"
  end

  defp default_reason("run.pause"), do: "operator_pause"
  defp default_reason("run.resume"), do: "operator_resume"
  defp default_reason("run.remove"), do: "operator_abandon"
  defp default_reason("run.reset"), do: "operator_reset"
  defp default_reason(_), do: "operator_dashboard"

  defp non_blank(value, default) when is_binary(value) do
    case String.trim(value) do
      "" -> default
      trimmed -> trimmed
    end
  end

  defp non_blank(_, default), do: default

  defp query_opts(params) do
    case limit_from(params) do
      {:ok, limit} ->
        opts =
          params
          |> normalize_params()
          |> Enum.reduce([limit: limit], fn
            {:status, value}, acc when is_binary(value) and value != "" ->
              Keyword.put(acc, :status, value)

            {:project_id, value}, acc when is_binary(value) and value != "" ->
              Keyword.put(acc, :project_id, value)

            _, acc ->
              acc
          end)

        {:ok, opts}

      {:error, _} = error ->
        error
    end
  end

  defp normalize_params(params) when is_map(params) do
    %{
      status: value(params, :status),
      project_id: value(params, :project_id),
      limit: value(params, :limit)
    }
  end

  defp normalize_params(_), do: %{}

  # Absent limit defaults; a PRESENT but invalid limit ("abc", "10x", 0,
  # negative) is a malformed-input error, never silently coerced to the
  # default -- that would make invalid operator input look successful.
  defp limit_from(params) do
    params
    |> normalize_params()
    |> Map.get(:limit)
    |> parse_limit()
    |> case do
      {:ok, limit} -> {:ok, min(limit, @max_limit)}
      {:error, _} = error -> error
    end
  end

  defp parse_limit(nil), do: {:ok, @default_limit}
  defp parse_limit(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> {:error, {:malformed_limit, value}}
    end
  end

  defp parse_limit(value), do: {:error, {:malformed_limit, value}}

  defp run_dto(run, phases \\ nil) do
    phases = phases || phases_for_run(run)
    current_phase = current_phase(phases)
    task_id = value(run, :task_id)

    # Required invariant fields — fail loudly if absent rather than masking.
    run_id = run_id(run)
    status = status(run)

    pr_url = value(run, :pr_url)

    %RunDTO{
      run_id: run_id,
      project_id: value(run, :project_id) || :absent,
      status: status,
      workflow: value(run, :workflow_name) || :absent,
      task_id: task_id || :absent,
      task_label: if(task_id in [nil, ""], do: "ad-hoc run", else: task_id),
      current_phase_id: value(current_phase, :phase_id) || :absent,
      current_phase_name: value(current_phase, :name) || :absent,
      current_phase_status: value(current_phase, :status) || :absent,
      started_at_ms: value(run, :started_at_ms) || :absent,
      last_event_at_ms: value(run, :last_event_at_ms) || :absent,
      latest_stall: latest_stall(run, phases),
      pr_url: pr_url || :absent,
      pr_marker: if(is_binary(pr_url) and pr_url != "", do: "PR", else: "no PR"),
      terminal?: value(run, :terminal?) || false,
      failure_reason: value(run, :failure_reason) || :absent,
      actions: actions_for_status(status)
    }
  end

  # Fail loudly on missing required invariant fields.
  defp run_id(run) do
    case value(run, :run_id) do
      id when is_binary(id) and id != "" -> id
      _ -> raise KeyError, key: :run_id, term: run
    end
  end

  defp status(run) do
    case value(run, :status) do
      s when is_binary(s) -> s
      _ -> raise KeyError, key: :status, term: run
    end
  end

  defp phases_for_run(run) do
    case value(run, :run_id) do
      id when is_binary(id) and id != "" -> ProjectionStore.phases_for_run(id)
      _ -> []
    end
  end

  defp current_phase([]), do: %{}

  defp current_phase(phases) do
    Enum.find(phases, fn phase -> value(phase, :status) == "in_progress" end) || List.last(phases) ||
      %{}
  end

  defp latest_stall(run, phases) do
    cond do
      value(run, :latest_stall) not in [nil, ""] ->
        value(run, :latest_stall)

      true ->
        Enum.find_value(phases, :absent, fn phase -> value(phase, :latest_stall) end) || :absent
    end
  end

  defp task_for_run(run) do
    case value(run, :task_id) do
      task_id when is_binary(task_id) and task_id != "" ->
        ProjectionStore.task_projection(task_id) || :absent

      _ ->
        :absent
    end
  end

  defp pr_association(run_id) do
    case ProjectionStore.pr_association(run_id) do
      {:ok, assoc} -> assoc
      {:error, :not_found} -> :absent
    end
  end

  defp phase_dto(phase) do
    %{
      phase_id: value(phase, :phase_id) || :absent,
      index: value(phase, :index) || :absent,
      name: value(phase, :name) || :absent,
      status: value(phase, :status) || :absent,
      attempt: value(phase, :attempt) || :absent,
      artifact: value(phase, :artifact) || :absent,
      failure_reason: value(phase, :failure_reason) || :absent,
      latest_stall: value(phase, :latest_stall) || :absent,
      started_at_ms: value(phase, :started_at_ms) || :absent,
      last_event_at_ms: value(phase, :last_event_at_ms) || :absent
    }
  end

  # Normalize once at this single boundary rather than letting every reader
  # probe both key shapes: the atom key wins deterministically whenever
  # present, even if its value is falsy (`false`, `0`, `""`) -- `||` here
  # would incorrectly fall through to the string key on a legitimate falsy
  # atom value, and would pick whichever key happens to be truthy when both
  # are present with conflicting values. Public so
  # `OperatorDashboard.ChangeEvidence` shares this boundary instead of
  # keeping its own drifting copy.
  def value(nil, _key), do: nil
  def value(:absent, _key), do: nil

  def value(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end

defmodule ForemanServerWeb.OperatorDashboard.ChangeEvidence do
  @moduledoc false

  alias ForemanServer.ProjectionStore

  @max_files 200
  @max_bytes 24_000

  def for_run(run_id) when is_binary(run_id) and run_id != "" do
    with run when is_map(run) <- ProjectionStore.run(run_id),
         {:ok, source} <- evidence_source(run_id, run),
         {:ok, files} <- changed_files(source) do
      {:ok,
       %{
         state: :available,
         source: source.kind,
         files: Enum.take(files, @max_files),
         truncated?: length(files) > @max_files
       }}
    else
      nil -> {:error, :run_not_found}
      {:unavailable, reason, meta} -> {:ok, %{state: reason, meta: meta, files: []}}
      {:error, reason} -> {:ok, %{state: reason, files: []}}
    end
  end

  def for_run(_), do: {:error, :run_not_found}

  def preview(run_id, rel_path) when is_binary(rel_path) do
    with {:ok, %{state: :available, files: files}} <- for_run(run_id),
         true <- safe_relative?(rel_path),
         true <- Enum.any?(files, &(&1.path == rel_path)),
         {:ok, source} <- evidence_source(run_id, ProjectionStore.run(run_id)),
         {:ok, text} <- git(source.cwd, ["diff", source.base <> "..HEAD", "--", rel_path]) do
      {:ok, String.slice(text, 0, @max_bytes)}
    else
      false -> {:error, :malformed_path}
      _ -> {:error, :unavailable}
    end
  end

  defp evidence_source(run_id, run) do
    worktree = ProjectionStore.worktrees_for_run(run_id) |> Enum.find(&created_worktree?/1)

    cond do
      is_map(worktree) and safe_abs_dir?(worktree_path(worktree)) and usable_base?(worktree, run) ->
        {:ok,
         %{
           kind: :worktree,
           cwd: worktree_path(worktree),
           base: value(worktree, :base_ref) || value(run, :base_branch)
         }}

      is_map(worktree) ->
        {:unavailable, :base_unavailable, %{worktree: worktree_path(worktree) || :absent}}

      value(run, :pr_url) not in [nil, ""] ->
        {:unavailable, :worktree_missing, %{pr_url: value(run, :pr_url)}}

      true ->
        {:unavailable, :worktree_missing, %{run_id: run_id}}
    end
  end

  defp created_worktree?(worktree) do
    value(worktree, :status) in [nil, "created"] and is_binary(worktree_path(worktree))
  end

  defp usable_base?(worktree, run) do
    base = value(worktree, :base_ref) || value(run, :base_branch)
    is_binary(base) and base != ""
  end

  defp changed_files(%{cwd: cwd, base: base}) do
    case git(cwd, ["diff", "--name-status", "--find-renames", base <> "..HEAD", "--"]) do
      {:ok, output} -> {:ok, parse_name_status(output)}
      {:error, _} -> {:error, :base_unavailable}
    end
  end

  defp parse_name_status(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, "\t") do
        [status, path] -> file_row(status, path)
        [status, _old, path] -> file_row(status, path)
        _ -> []
      end
    end)
  end

  defp file_row(status, path) do
    if safe_relative?(path), do: [%{status: status, path: path, source: :worktree}], else: []
  end

  defp git(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, _} -> {:error, String.slice(out, 0, 1_000)}
    end
  rescue
    _ -> {:error, :git_unavailable}
  end

  defp worktree_path(worktree), do: value(worktree, :worktree_path) || value(worktree, :path)

  defp safe_abs_dir?(path),
    do: is_binary(path) and Path.type(path) == :absolute and File.dir?(path)

  defp safe_relative?(path) when is_binary(path) do
    Path.type(path) == :relative and not String.starts_with?(path, "../") and
      not String.contains?(path, "/../") and path != ".."
  end

  defp safe_relative?(_), do: false

  # Shared with `OperatorDashboard.value/2` -- one normalization boundary
  # for projection records, not two independently-drifting copies.
  defp value(map, key), do: ForemanServerWeb.OperatorDashboard.value(map, key)
end
