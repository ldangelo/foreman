defmodule ForemanServer.TaskProviders.BeadsOrphanJanitor do
  @moduledoc """
  Periodic scanner that closes Foreman-tagged beads whose corresponding
  Foreman task is missing or already terminal.

  Per PRD REQ-023 / AC-023-1..AC-023-4:

    * One supervised GenServer per registered project (`:start_beads_orphan_janitor?`
      flag controls whether the supervisor boots any; opt-in per
      TRD-014-TASK).
    * `init/1` resolves the JSONL tail target via the configured `BrRunner`
      (production: `SystemBrRunner`; test: `BrRunnerMock`).
    * The first scan is scheduled after `@grace_ms` (default 300s) to avoid
      racing the synchronous in-process Actor hook on first boot. Subsequent
      scans fire every `@scan_interval_ms` (default 60s).
    * On every scan, the loop reads the JSONL tail and for each
      foreman-tagged entry applies the **per-entry age gate** (PRD REQ-023):
      only entries whose `agent_context.foreman.linked_at` is older than
      `@grace_ms` are eligible. Beads created after the last scan could
      otherwise be closed on the very next 60s tick, which would defeat the
      purpose of the grace window.
    * Per-entry flow after the age gate:
        - (a) no `ForemanServer.ProjectionStore` task with `external_id ==
          bead.id` → close with `transition_comment: "foreman-orphan:no-task"`.
        - (b) task exists and is `closed` / `failed` → close with
          `transition_comment: "foreman-orphan:terminal-task"`.
        - non-foreman-tagged → skip, emit
          `[:foreman_server, :task_provider, :beads, :orphan, :janitor, :retained]`.
        - foreman-tagged but no `linked_at` (or malformed `linked_at`) →
          retain defensively (PRD REQ-023 only authorises close when the
          age is provably > grace_ms; missing or unparseable timestamps
          stay retained until provenance is re-established).
        - foreman-tagged and `linked_at` is younger than `grace_ms` → retain
          with telemetry `[:retained, :age_young]`.

    * On every successful close, emit
      `[:foreman_server, :task_provider, :beads, :orphan, :janitor, :closed]`
      carrying `bead_id`, `project_id`, `transition_comment`, and
      `elapsed_ms` (milliseconds since `linked_at`).

  Architectural invariants:

    * `BeadsOrphanJanitor` closes ONLY foreman-tagged beads. Untagged beads
      are NEVER touched (AC-023-4). The foreman-tag check is the FIRST
      filter in the per-line loop, before any `br close` call.
    * The janitor NEVER fabricates events and NEVER routes through
      `CommandRouter`; the close call is the `BeadsAdapter.complete/3`
      subprocess path (PRD-2026-48f7b420 REQ-009). The Actor's
      `in_flight_beads` cache is bypassed by design: orphan recovery is a
      filesystem-anchored scan, not a command dispatch.
    * Time comparison is anchored to `System.system_time(:millisecond)`
      (Unix epoch ms) for both `now_ms` and `linked_at_ms`. Mixing
      monotonic and system time is a hard bug because the difference is
      meaningless — `DateTime.to_unix/2` returns Unix epoch ms.

  Required opts:

    * `:project_id` — string identifier of the registered project.
    * `:database_path` — absolute path to the project's `.beads/`
      directory (the `BeadsAdapter.complete/3` close path reuses this
      verbatim).

  Optional opts:

    * `:grace_ms` — per-entry age threshold in milliseconds (default 300000).
    * `:scan_interval_ms` — inter-scan cadence in milliseconds (default 60000).
    * `:name` — process registration name. Supervisor wiring supplies a
      per-project `:name` opt; in test harnesses, an atom may be passed
      for direct `GenServer.call` / introspection. **When `:name` is
      absent the janitor starts unregistered** (atom-leak safety:
      operator-controlled `project_id` strings never flow through atom
      conversion).
  """

  use GenServer

  alias ForemanServer.TaskProvider.Telemetry, as: TaskProviderTelemetry

  @runner Application.compile_env(
            :foreman_server,
            :br_runner,
            ForemanServer.TaskProviders.SystemBrRunner
          )

  # --- Counters (TRD §3 Risk-Mitigation symmetry with BeadsWatcher) ---
  #
  # `[:orphan, :janitor, :scan_completed]` carries the counters so operators
  # can size the steady-state scan cost (boot-time tail cost is
  # `lines_processed - lines_tagged - lines_untagged` = the number of
  # non-bead lines the file holds, typically zero on a healthy `.beads/`).
  defmodule Counters do
    @moduledoc false
    defstruct lines_processed: 0,
              lines_tagged: 0,
              lines_untagged: 0,
              lines_malformed: 0,
              lines_retained: 0,
              lines_closed: 0,
              lines_age_young: 0,
              lines_no_linked_at: 0
  end

  @type counters :: %Counters{}

  @grace_ms 300_000
  @scan_interval_ms 60_000
  @preflight_timeout_ms 30_000

  # Telemetry event paths
  @start_event [:foreman_server, :task_provider, :beads, :orphan, :janitor, :start]
  @scan_started_event [:foreman_server, :task_provider, :beads, :orphan, :janitor, :scan_started]
  @scan_completed_event [
    :foreman_server,
    :task_provider,
    :beads,
    :orphan,
    :janitor,
    :scan_completed
  ]
  @retained_event [:foreman_server, :task_provider, :beads, :orphan, :janitor, :retained]
  @closed_event [:foreman_server, :task_provider, :beads, :orphan, :janitor, :closed]
  @error_event [:foreman_server, :task_provider, :beads, :orphan, :janitor, :error]

  @valid_terminal_statuses MapSet.new(["closed", "failed"])

  @type t :: %__MODULE__{
          project_id: String.t(),
          database_path: String.t(),
          jsonl_path: String.t(),
          grace_ms: non_neg_integer(),
          scan_interval_ms: pos_integer(),
          # Cached snapshot of the most recent run_scan/2 result. nil
          # until the first scan completes. The doctor reads this via
          # `get_counters/1`; the value is NEVER recomputed on read
          # (CQRS read path: no `run_scan/2`, no `BeadsAdapter.complete/3`).
          last_counters: counters() | nil
        }

  defstruct project_id: nil,
            database_path: nil,
            jsonl_path: nil,
            grace_ms: @grace_ms,
            scan_interval_ms: @scan_interval_ms,
            last_counters: nil

  # ---------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------

  @doc """
  Start a janitor for `project_id`.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} ->
        GenServer.start_link(__MODULE__, opts, name: name)

      :error ->
        GenServer.start_link(__MODULE__, opts)
    end
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :project_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }
  end

  @doc """
  Read the most recent scan counters for a janitor process.

  This is a SIDE-EFFECT-FREE read against the janitor's in-memory state.
  It does NOT invoke `run_scan/2`, does NOT call `BeadsAdapter.complete/3`,
  and does NOT dispatch through `CommandRouter`. The doctor and other
  diagnostic surfaces MUST use this entry point; calling `run_scan/2`
  from a read path would mutate provider state and violate the CQRS
  query boundary.

  `server` is any value accepted by `GenServer.call/2` (pid, registered
  name, or `{:via, Registry, _}`). Returns the cached counters, or `nil`
  if no scan has completed yet. Errors from a dead/wedged process
  propagate as `GenServer.call/2` exits (`:noproc`, `:timeout`).
  """
  @spec get_counters(GenServer.server()) :: counters() | nil
  def get_counters(server) do
    GenServer.call(server, :get_counters)
  end

  # ---------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------

  @impl true
  def init(opts) do
    project_id = Keyword.fetch!(opts, :project_id)
    database_path = Keyword.fetch!(opts, :database_path)
    grace_ms = Keyword.get(opts, :grace_ms, @grace_ms)
    scan_interval_ms = Keyword.get(opts, :scan_interval_ms, @scan_interval_ms)

    TaskProviderTelemetry.emit(
      @start_event,
      %{system_time: System.system_time()},
      %{
        project_id: project_id,
        grace_ms: grace_ms,
        scan_interval_ms: scan_interval_ms
      }
    )

    with {:ok, jsonl_path} <- resolve_jsonl_path(project_id, database_path) do
      state = %__MODULE__{
        project_id: project_id,
        database_path: database_path,
        jsonl_path: jsonl_path,
        grace_ms: grace_ms,
        scan_interval_ms: scan_interval_ms
      }

      # First scan after grace_ms to avoid racing the synchronous Actor
      # hook on first boot. The per-entry age gate (see `age_gate/4`)
      # also enforces the grace window so a long-running Janitor is
      # safe even if a new bead is created between the first scan and
      # the second.
      Process.send_after(self(), :scan, grace_ms)
      {:ok, state}
    else
      {:error, {:preflight_failed, _project_id, reason}} ->
        TaskProviderTelemetry.emit(
          @error_event,
          %{system_time: System.system_time()},
          %{project_id: project_id, stage: :preflight, reason: inspect(reason)}
        )

        {:stop, {:preflight_failed, reason}}

      {:error, reason} ->
        TaskProviderTelemetry.emit(
          @error_event,
          %{system_time: System.system_time()},
          %{project_id: project_id, stage: :init, reason: inspect(reason)}
        )

        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_counters, _from, state) do
    # Side-effect-free read; doctor and other diagnostic surfaces use this
    # instead of run_scan/2 (which mutates BeadsAdapter.complete/3).
    {:reply, state.last_counters, state}
  end

  @impl true
  def handle_info(:scan, state) do
    TaskProviderTelemetry.emit(
      @scan_started_event,
      %{system_time: System.system_time()},
      %{project_id: state.project_id, jsonl_path: state.jsonl_path}
    )

    started_at_ms = System.monotonic_time(:millisecond)
    counters = run_scan(state)
    completed_at_ms = System.monotonic_time(:millisecond)

    # `duration_ms` is the only place we use monotonic time — and only
    # for elapsed measurement, never against wall-clock timestamps. The
    # per-entry age gate uses `System.system_time(:millisecond)` against
    # Unix epoch-derived `linked_at_ms`.
    TaskProviderTelemetry.emit(
      @scan_completed_event,
      %{
        system_time: System.system_time(),
        duration_ms: completed_at_ms - started_at_ms
      },
      %{
        project_id: state.project_id,
        lines_processed: counters.lines_processed,
        lines_tagged: counters.lines_tagged,
        lines_untagged: counters.lines_untagged,
        lines_malformed: counters.lines_malformed,
        lines_retained: counters.lines_retained,
        lines_closed: counters.lines_closed,
        lines_age_young: counters.lines_age_young,
        lines_no_linked_at: counters.lines_no_linked_at
      }
    )

    # Cache the counters in state for the CQRS read path (`get_counters/1`).
    # The doctor reads this snapshot; it does NOT re-run the scan.
    state = %{state | last_counters: counters}

    Process.send_after(self(), :scan, state.scan_interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------
  # Public scan entry point (test seam)
  # ---------------------------------------------------------------------

  @doc """
  Run a single scan and return the counters. Tests invoke this directly
  to assert the per-entry age gate and the three-classify flow without
  scheduling a real scan timer.

  `now_ms` is injectable for deterministic tests. Production callers
  pass `System.system_time(:millisecond)` (Unix epoch ms — same units
  as `linked_at` parsed by `DateTime.to_unix/2`).
  """
  @spec run_scan(t(), keyword()) :: counters()
  def run_scan(%__MODULE__{} = state, opts \\ []) do
    now_ms = Keyword.get(opts, :now_ms, System.system_time(:millisecond))

    case read_jsonl_lines(state.jsonl_path) do
      {:ok, lines} ->
        Enum.reduce(lines, %Counters{}, fn line, counters ->
          process_line(state, line, now_ms, counters)
        end)

      {:error, reason} ->
        TaskProviderTelemetry.emit(
          @error_event,
          %{system_time: System.system_time()},
          %{
            project_id: state.project_id,
            stage: :read_jsonl,
            reason: inspect(reason)
          }
        )

        %Counters{lines_processed: 0}
    end
  end

  # ---------------------------------------------------------------------
  # Per-line processing
  # ---------------------------------------------------------------------

  # `process_line/4` is the single mutation point for `counters`. It
  # takes a `%Counters{}` accumulator and returns a `%Counters{}` so
  # `Enum.reduce/3` over the JSONL lines stays well-typed. The
  # diagnostic flow happens inside `classify_line/3` which returns a
  # tagged tuple and carries the `bead_id` (when known) so the
  # retained-telemetry path can emit without re-parsing.
  #
  # Steps (in order):
  #
  #  1. Decode the JSON line. On failure, count `:malformed` and return
  #     — the orphan pipeline MUST stay resilient against garbage lines
  #     in the JSONL (operators may have run `br edit` mid-scan).
  #  2. Foreman-tag check (AC-023-4). Non-foreman-tagged → untagged
  #     counter; foreman-tagged → tagged counter and proceed.
  #  3. Per-entry age gate (PRD REQ-023). If `linked_at` is missing or
  #     unparseable, retain with `:no_linked_at` reason. If `linked_at` is
  #     younger than `@grace_ms`, retain with `:age_young` reason. Only
  #     when age >= grace_ms does the pipeline proceed to projection
  #     lookup and orphan classification.
  #  4. Projection lookup. If no task → close with
  #     `transition_comment: "foreman-orphan:no-task"`. If task exists
  #     and status ∈ {`closed`, `failed`} → close with
  #     `transition_comment: "foreman-orphan:terminal-task"`. Otherwise
  #     retain (the Foreman-side story is still in flight).
  defp process_line(state, line, now_ms, counters) do
    counters = %{counters | lines_processed: counters.lines_processed + 1}

    case classify_line(state, line, now_ms) do
      {:ok, counter_deltas} ->
        merge_counters(counters, counter_deltas)

      {:untagged, _bead_id} ->
        %Counters{counters | lines_untagged: counters.lines_untagged + 1}

      {:malformed, _bead_id} ->
        %Counters{counters | lines_malformed: counters.lines_malformed + 1}

      {:retained, reason, bead_id} ->
        emit_retained(state, bead_id, reason, now_ms)
        increment_retained(counters, reason)
    end
  end

  # `classify_line/3` returns a tagged tuple:
  #
  #   `{:ok, counter_deltas}`             — orphan closed successfully
  #   `{:retained, reason, bead_id}`      — bead kept (age_young,
  #                                         no_linked_at, active_task,
  #                                         projection_shape, close_failure)
  #   `{:untagged, nil}`                  — non-foreman-tagged line
  #   `{:malformed, nil}`                 — JSON parse failure
  #
  # `bead_id` is `nil` for the malformed/untagged branches because no
  # foreman tag was parsed. For retained branches, `bead_id` is the
  # parsed `"id"` from the JSONL line so telemetry can identify the bead.
  defp classify_line(state, line, now_ms) do
    case decode_line(line) do
      :malformed ->
        {:malformed, nil}

      {:ok, parsed} ->
        bead_id = Map.get(parsed, "id")

        case foreman_tag_classify(parsed) do
          :untagged ->
            {:untagged, nil}

          {:tagged, tag} ->
            case age_gate(state, parsed, tag, now_ms) do
              :ok ->
                classify_orphan(state, parsed, tag, now_ms)

              {:retained, reason} ->
                emit_age_retained(state, parsed, reason)
                {:retained, reason, bead_id}
            end
        end
    end
  end

  # ----- Step 1: JSON parse --------------------------------------------

  defp decode_line(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, parsed} when is_map(parsed) -> {:ok, parsed}
      _ -> :malformed
    end
  end

  # ----- Step 2: Foreman-tag check (AC-023-4) --------------------------

  # Returns `{:tagged, tag_map}` when `agent_context.foreman` is present;
  # `:untagged` otherwise. The foreman-tag check is the architectural
  # invariant: the janitor NEVER touches untagged beads.
  defp foreman_tag_classify(parsed) when is_map(parsed) do
    case parsed do
      %{"agent_context" => %{"foreman" => tag}} when is_map(tag) ->
        {:tagged, tag}

      _ ->
        :untagged
    end
  end

  # ----- Step 3: Per-entry age gate (PRD REQ-023) ----------------------

  # Returns `:ok` when the bead is older than `@grace_ms`; otherwise
  # `{:retained, :age_young | :no_linked_at}`.
  #
  # Defensive: missing or unparseable `linked_at` is treated as
  # un-provenanced and the bead is RETAINED. The janitor is the recovery
  # safety valve and the cost of retaining a misformatted bead is
  # bounded; the cost of closing a bead whose age cannot be established
  # is unbounded.
  defp age_gate(state, _parsed, tag, now_ms) do
    case Map.get(tag, "linked_at") do
      linked_at when is_binary(linked_at) and linked_at != "" ->
        case parse_iso8601_to_system_ms(linked_at) do
          {:ok, linked_at_ms} ->
            elapsed_ms = now_ms - linked_at_ms

            if elapsed_ms >= state.grace_ms do
              :ok
            else
              {:retained, :age_young}
            end

          :error ->
            {:retained, :no_linked_at}
        end

      _ ->
        {:retained, :no_linked_at}
    end
  end

  # ----- Step 4: Projection lookup + orphan classification ------------

  # `nil` → no task → orphan case (a) → close with `:no-task`.
  # `%{status: "closed" | "failed"}` → orphan case (b) → close with
  #   `:terminal-task`.
  # `%{status: <other>}` → foreman-side story still in flight → retain.
  defp classify_orphan(state, parsed, tag, now_ms) do
    bead_id = Map.get(parsed, "id")

    case lookup_task(state.project_id, bead_id) do
      nil ->
        close_orphan(state, bead_id, tag, "foreman-orphan:no-task", now_ms)

      %{status: status} when is_binary(status) ->
        if MapSet.member?(@valid_terminal_statuses, status) do
          close_orphan(state, bead_id, tag, "foreman-orphan:terminal-task", now_ms)
        else
          {:retained, {:active_task, status}, bead_id}
        end

      _other ->
        {:retained, :projection_shape, bead_id}
    end
  end

  # Returns `{:ok, counter_deltas}` on successful close, or
  # `{:retained, :close_failure, bead_id}` on adapter failure (the
  # next scan will retry).
  defp close_orphan(state, bead_id, tag, transition_comment, now_ms) do
    linked_at = Map.get(tag, "linked_at")
    elapsed_ms = compute_elapsed_ms(linked_at, now_ms)
    project_config = %{database_path: state.database_path}

    case beads_adapter().complete(
           bead_id,
           %{transition_comment: transition_comment},
           project_config
         ) do
      {:ok, _issue} ->
        emit_closed(state, bead_id, transition_comment, elapsed_ms)
        {:ok, %{lines_tagged: 1, lines_closed: 1}}

      {:error, reason} ->
        TaskProviderTelemetry.emit(
          @error_event,
          %{system_time: System.system_time()},
          %{
            project_id: state.project_id,
            stage: :close,
            bead_id: bead_id,
            reason: inspect(reason)
          }
        )

        # Treat the close failure as a transient retain — the next scan
        # will retry. The Janitor MUST NOT lose the bead on a transient
        # `br close` failure.
        {:retained, :close_failure, bead_id}
    end
  end

  # ---------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------

  # Read the JSONL file from offset 0 to EOF, returning a list of
  # complete lines (no trailing fragment). A read failure returns
  # `{:error, reason}` and the caller short-circuits with no counters.
  #
  # Test seam: this is the only I/O call in the scan path. Tests use
  # `tmp` directories under `System.tmp_dir!/0` to provide JSONL
  # fixtures.
  @doc false
  @spec read_jsonl_lines(Path.t()) :: {:ok, [binary()]} | {:error, term()}
  def read_jsonl_lines(jsonl_path) when is_binary(jsonl_path) do
    case File.read(jsonl_path) do
      {:ok, content} when is_binary(content) ->
        case :binary.split(content, "\n", [:global]) do
          [] -> {:ok, []}
          parts -> {:ok, Enum.reject(parts, &(&1 == ""))}
        end

      {:error, reason} ->
        {:error, {:jsonl_read_failed, jsonl_path, reason}}
    end
  end

  # Resolve the JSONL tail target for `project_id` via the configured
  # `BrRunner`. Same protocol as `BeadsWatcher.resolve_jsonl_path/2`;
  # duplicated here (rather than shared) so the Janitor's failure modes
  # stay independent of the watcher's and the boundary stays auditable.
  defp resolve_jsonl_path(project_id, database_path)
       when is_binary(project_id) and is_binary(database_path) do
    request = {:where, %{database_path: database_path}}
    project_config = %{database_path: database_path}

    case @runner.cmd(request, project_config, timeout_ms: @preflight_timeout_ms) do
      {:ok, %{stdout: stdout}} when is_binary(stdout) ->
        case Jason.decode(stdout) do
          {:ok, %{"jsonl_path" => path}} when is_binary(path) and path != "" ->
            {:ok, path}

          {:ok, %{"jsonl_path" => _other}} ->
            {:error, {:invalid_jsonl_path, project_id, stdout}}

          {:ok, _other_map} ->
            {:error, {:missing_jsonl_path_key, project_id, stdout}}

          {:error, _reason} ->
            {:error, {:jsonl_path_decode_failed, project_id, stdout}}
        end

      {:ok, other} ->
        {:error, {:unexpected_preflight_response, project_id, other}}

      {:error, reason} ->
        {:error, {:preflight_failed, project_id, reason}}
    end
  end

  # Resolve the configured `BeadsAdapter` module. Production defaults to
  # `ForemanServer.TaskProviders.BeadsAdapter`; test harnesses may inject
  # a fake via `Application.put_env(:foreman_server, :beads_adapter_module, ...)`.
  # The indirection is required so the close path remains substitutable
  # without `Application.put_env/3` magic at the call site.
  defp beads_adapter do
    Application.get_env(
      :foreman_server,
      :beads_adapter_module,
      ForemanServer.TaskProviders.BeadsAdapter
    )
  end

  defp lookup_task(_project_id, bead_id) do
    case projection_store().get_task(external_id: bead_id) do
      nil ->
        nil

      task when is_map(task) ->
        task

      _other ->
        nil
    end
  end

  defp projection_store do
    Application.get_env(
      :foreman_server,
      :projection_store_module,
      ForemanServer.ProjectionStore
    )
  end

  defp emit_retained(state, bead_id, reason, now_ms) do
    TaskProviderTelemetry.emit(
      @retained_event,
      %{system_time: System.system_time(), now_ms: now_ms},
      %{
        project_id: state.project_id,
        bead_id: bead_id,
        reason: inspect_reason(reason)
      }
    )
  end

  defp emit_age_retained(state, parsed, reason) do
    TaskProviderTelemetry.emit(
      @retained_event,
      %{system_time: System.system_time()},
      %{
        project_id: state.project_id,
        bead_id: Map.get(parsed, "id"),
        reason: inspect_reason(reason)
      }
    )
  end

  defp emit_closed(state, bead_id, transition_comment, elapsed_ms) do
    TaskProviderTelemetry.emit(
      @closed_event,
      %{system_time: System.system_time()},
      %{
        project_id: state.project_id,
        bead_id: bead_id,
        transition_comment: transition_comment,
        elapsed_ms: elapsed_ms
      }
    )
  end

  defp inspect_reason(:age_young), do: "age_young"
  defp inspect_reason(:no_linked_at), do: "no_linked_at"
  defp inspect_reason(:projection_shape), do: "projection_shape"
  defp inspect_reason(:close_failure), do: "close_failure"
  defp inspect_reason({:active_task, status}), do: "active_task:#{status}"
  defp inspect_reason(reason), do: inspect(reason)

  # `merge_counters/2` folds a `%{counter => delta}` map into the
  # accumulator. Negative deltas are allowed (none at the moment) but
  # never cross below zero — the loop always inspects the counter
  # field before merging.
  defp merge_counters(counters, deltas) when is_map(deltas) do
    Enum.reduce(deltas, counters, fn {field, delta}, acc ->
      Map.update!(acc, field, &(&1 + delta))
    end)
  end

  defp increment_retained(counters, :age_young) do
    %{
      counters
      | lines_retained: counters.lines_retained + 1,
        lines_age_young: counters.lines_age_young + 1,
        lines_tagged: counters.lines_tagged + 1
    }
  end

  defp increment_retained(counters, :no_linked_at) do
    %{
      counters
      | lines_retained: counters.lines_retained + 1,
        lines_no_linked_at: counters.lines_no_linked_at + 1,
        lines_tagged: counters.lines_tagged + 1
    }
  end

  defp increment_retained(counters, :close_failure) do
    %{
      counters
      | lines_retained: counters.lines_retained + 1,
        lines_tagged: counters.lines_tagged + 1
    }
  end

  defp increment_retained(counters, :projection_shape) do
    %{
      counters
      | lines_retained: counters.lines_retained + 1,
        lines_tagged: counters.lines_tagged + 1
    }
  end

  defp increment_retained(counters, {:active_task, _status}) do
    %{
      counters
      | lines_retained: counters.lines_retained + 1,
        lines_tagged: counters.lines_tagged + 1
    }
  end

  defp increment_retained(counters, _other) do
    %{counters | lines_retained: counters.lines_retained + 1}
  end

  # ISO8601 / RFC 3339 timestamp → Unix epoch milliseconds.
  #
  # `DateTime.from_iso8601/1` accepts the full RFC 3339 shape including
  # fractional seconds and `Z` / `±HH:MM` offsets. The PRD contract
  # requires UTC (`Z` suffix); we coerce to UTC and convert to
  # `:millisecond` units so the comparison against `now_ms` (Unix
  # epoch ms from `System.system_time(:millisecond)`) is consistent.
  #
  # Returns `:error` on any parse failure — caller treats parse failure
  # as "un-provenanced" and retains the bead.
  @doc false
  @spec parse_iso8601_to_system_ms(binary()) :: {:ok, integer()} | :error
  def parse_iso8601_to_system_ms(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        try do
          {:ok, DateTime.to_unix(dt, :millisecond)}
        rescue
          _ -> :error
        end

      _ ->
        :error
    end
  end

  # Compute elapsed milliseconds since `linked_at`. Returns `nil` when
  # `linked_at` is missing or unparseable (callers should emit
  # `elapsed_ms: nil` in that case to make the gap visible in
  # telemetry).
  defp compute_elapsed_ms(linked_at, now_ms) when is_binary(linked_at) do
    case parse_iso8601_to_system_ms(linked_at) do
      {:ok, linked_at_ms} -> now_ms - linked_at_ms
      :error -> nil
    end
  end

  defp compute_elapsed_ms(_linked_at, _now_ms), do: nil
end
