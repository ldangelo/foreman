defmodule ForemanServer.TaskProviders.BeadsWatcher do
  @moduledoc """
  Per-project tail of the Beads JSONL stream.

  Each registered project gets one supervised `GenServer` process that:

    * On `init/1`, resolves the JSONL path via the configured `BrRunner`
      implementation (`@runner`, default `SystemBrRunner`, test override
      `BrRunnerMock`), opens the file with `:file.open/2`, then returns
      via `{:continue, :boot_replay}`. `handle_continue/2` runs
      `boot_replay/1` (offset 0 → EOF under the 3-way cursor priority)
      only once `CommandRouter` is registered — checked via
      `command_router_ready?/0` and retried every `@boot_replay_retry_ms`
      otherwise, so a watcher that starts (opt-in, before `CommandRouter`
      in the application's children list) before the router does cannot
      crash-loop on the lease-acquisition dispatch `boot_replay/1`
      performs. Once ready, replay subscribes to a `file_system` watch
      on the JSONL's parent directory (TRD-011), then schedules the
      first tail-mode `:read_more` poll via `Process.send_after/3`.
    * In tail mode, a `{:file_event, pid, {path, events}}` for the
      exact `jsonl_path` is the primary (<1s) trigger: it schedules a
      single `:debounced_read_more` `@debounce_ms` (100ms) out,
      coalescing any further events in that window into the same read.
      The fixed-cadence `:read_more` poll (`@default_poll_ms`, 30s)
      remains as an eventual-consistency backstop for a missed watch
      event.
    * For each complete line, applies the full pipeline via
      `process_line/2`: parse JSON → check `agent_context.foreman`
      (suppress + `:skipped` per AC-022-3) → check
      `ProjectionStore.get_task(external_id: bead.id)`. No existing task
      → proceed. An existing task still `status: "open"` (created but
      never approved, e.g. a prior `task.approve` attempt failed) →
      retry approval directly, without a new `task.create` dispatch
      (`:imported` on success, `:transient` on failure so the next poll
      retries again — see the auto-approval paragraph below). An
      existing task already past `"open"` → dedupe (`:reconciled` per
      AC-022-2) → status gate (TRD-004: only `status: "open"` proceeds;
      others are `:skipped`) → workflow selection (TRD-005:
      `Catalog.type_to_workflow/1`; a missing or non-string
      `issue_type` is `:malformed`; a present but unmapped `issue_type`
      holds `:transient`) → `trd_path` check (TRD-006: required for
      `implement-trd`/`implement-trd-beads`; missing/empty moves the
      bead to `blocked` and returns `:skipped`) → otherwise synthesize
      a deterministic `task.create` envelope, dispatch via
      `CommandGateway.dispatch_system/2`, and auto-approve with a
      matching `task.approve` on success (TRD-007). `:imported` per
      AC-022-1 / AC-003-2 is reported only once BOTH `task.create` (or
      an idempotent `{:error, {:already_exists, :task, _}}` retry) AND
      the following `task.approve` succeed; a `task.create` success
      with a failed `task.approve` returns `:transient` instead of a
      misleading `:imported`, and is retried via the dedupe branch
      above on the next poll.

  ## 3-way cursor priority (TRD §2.2.6 item 6)

  `read_offset` is the byte position of the START of the FIRST LINE NOT
  TERMINALLY DISPATCHED:

    (a) start byte of the first transient complete-line if the loop
        stopped at a transient;
    (b) start byte of any trailing fragment if the file ends on an
        unterminated JSONL line;
    (c) the file size (EOF) if the file ends on a terminator.

  `partial_line` is the bytes of that first-undispatched line
  (transient-line bytes, trailing fragment bytes, or `""`).
  It is observability metadata; correctness on the next poll does
  NOT depend on it (the next read seeks to `read_offset` and
  re-reads the bytes from disk).

  Terminal advance moves `read_offset` past `byte_size(line) + 1`.
  Transient hold leaves `read_offset` at the transient-line start byte.

  ## Restart contract (full-replay-on-every-boot, TRD §2.2.6 item 8)

  The watcher does NOT maintain a durable offset. On every boot, the
  watcher reads the JSONL from offset 0 to current EOF, applies the
  full status-gated parse + dedupe + suppress + status-gate +
  workflow-selection + trd_path-check + dispatch-and-approve pipeline
  (`process_line/2`), then captures the boot-completion cursor and
  enters tail mode. The `ProjectionStore` dedupe check is the
  cross-restart safety net — beads that transitioned to `open` while
  the watcher was offline are recovered, created, and approved on the
  next boot's replay exactly as they would have been had the watcher
  been running continuously (TRD-004..TRD-007 requirement REQ-004).

  ## Opt-in supervision (TRD §2.2.6 item 9)

  The supervisor child is added by `ForemanServer.Application.maybe_beads_watcher_child/0`
  (TRD-014-TASK) and reads `:start_beads_watcher?` (default `false`).
  Per-project process registration is handled by the TRD-014 supervisor
  design — this module's `start_link/1` simply accepts a `:name` opt so
  the supervisor can choose the registration strategy.
  """

  use GenServer

  alias ForemanServer.Aggregates.BeadsDbLease
  alias ForemanServer.CommandRouter
  alias ForemanServer.TaskProvider.Telemetry, as: TaskProviderTelemetry

  @runner Application.compile_env(
            :foreman_server,
            :br_runner,
            ForemanServer.TaskProviders.SystemBrRunner
          )

  # Side-effect seams — overridable in test via Application env so the
  # full parse+dedupe+dispatch pipeline is exercised without booting
  # the real CommandGateway or ProjectionStore GenServers. Runtime
  # resolution (not compile_env) so test setup env changes take effect
  # without recompilation.
  defp command_gateway do
    Application.get_env(
      :foreman_server,
      :command_gateway_module,
      ForemanServer.CommandGateway
    )
  end

  defp projection_store do
    Application.get_env(
      :foreman_server,
      :projection_store_module,
      ForemanServer.ProjectionStore
    )
  end

  defp workflow_catalog do
    Application.get_env(
      :foreman_server,
      :workflow_catalog_module,
      ForemanServer.Workflow.Catalog
    )
  end

  @type t :: %__MODULE__{
          project_id: String.t(),
          jsonl_path: String.t(),
          database_path: String.t(),
          file_handle: :file.io_device(),
          read_offset: non_neg_integer(),
          partial_line: binary(),
          poll_ms: pos_integer(),
          fs_watcher_pid: pid() | nil,
          debounce_timer: reference() | nil
        }

  defstruct [
    :project_id,
    :jsonl_path,
    :database_path,
    :file_handle,
    :read_offset,
    :partial_line,
    :poll_ms,
    :fs_watcher_pid,
    :debounce_timer
  ]

  # Replay counters — TRD §3 Risk-Mitigation (line 607) calls for
  # `lines_processed / lines_imported / lines_suppressed / lines_reconciled`
  # on the [:watcher, :replay_completed] telemetry event so operators
  # can size the boot-replay storm.
  defmodule Counters do
    @moduledoc false
    defstruct lines_processed: 0,
              lines_imported: 0,
              lines_suppressed: 0,
              lines_reconciled: 0,
              lines_malformed: 0,
              lines_transient: 0
  end

  @type counters :: %Counters{}

  @default_poll_ms 30_000
  @debounce_ms 100
  @preflight_timeout_ms 30_000
  @read_chunk_bytes 64 * 1024
  @boot_replay_retry_ms 50

  # Telemetry event paths
  @start_event [:foreman_server, :task_provider, :beads, :watcher, :start]
  @replay_started_event [:foreman_server, :task_provider, :beads, :watcher, :replay_started]
  @replay_completed_event [:foreman_server, :task_provider, :beads, :watcher, :replay_completed]
  @read_more_event [:foreman_server, :task_provider, :beads, :watcher, :read_more]
  @line_processed_event [:foreman_server, :task_provider, :beads, :watcher, :line_processed]
  @skipped_event [:foreman_server, :task_provider, :beads, :watcher, :skipped]
  @reconciled_event [:foreman_server, :task_provider, :beads, :watcher, :reconciled]
  @imported_event [:foreman_server, :task_provider, :beads, :watcher, :imported]
  @malformed_event [:foreman_server, :task_provider, :beads, :watcher, :malformed]
  @error_event [:foreman_server, :task_provider, :beads, :watcher, :error]
  @rejected_event [:foreman_server, :task_provider, :beads, :watcher, :rejected]
  @status_gate_skipped_draft_status_event [
    :foreman_server,
    :task_provider,
    :beads,
    :watcher,
    :status_gate,
    :skipped,
    :draft_status
  ]
  @status_gate_skipped_unmapped_type_event [
    :foreman_server,
    :task_provider,
    :beads,
    :watcher,
    :status_gate,
    :skipped,
    :unmapped_type
  ]
  @status_gate_skipped_missing_trd_path_event [
    :foreman_server,
    :task_provider,
    :beads,
    :watcher,
    :status_gate,
    :skipped,
    :missing_trd_path
  ]
  @dispatch_and_approve_event [
    :foreman_server,
    :task_provider,
    :beads,
    :watcher,
    :dispatch_and_approve
  ]
  @coverage_drift_event [:foreman_server, :task_provider, :beads, :watcher, :coverage_drift]
  # ---------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------

  @doc """
  Start a watcher for `project_id`.

  Required opts:
    * `:project_id` — string identifier of the registered project
    * `:database_path` — absolute path to the project's `.beads/` directory

  Optional opts:
    * `:poll_ms` — tail-mode polling cadence (default #{@default_poll_ms} ms)
    * `:name` — process registration name. The supervisor design
      (TRD-014-TASK) supplies a per-project `:name` opt when wiring the
      child spec. **When `:name` is absent the watcher starts
      unregistered** — atom-leak safety: operator-controlled
      `project_id` strings never flow through atom conversion.
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

  # ---------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------

  @impl true
  def init(opts) do
    project_id = Keyword.fetch!(opts, :project_id)
    database_path = Keyword.fetch!(opts, :database_path)
    poll_ms = Keyword.get(opts, :poll_ms, @default_poll_ms)

    TaskProviderTelemetry.emit(
      @start_event,
      %{system_time: System.system_time()},
      %{project_id: project_id}
    )

    with :ok <- check_coverage_drift(project_id, database_path),
         {:ok, jsonl_path} <- resolve_jsonl_path(project_id, database_path),
         {:ok, file_handle} <- :file.open(jsonl_path, [:read, :binary, :raw]) do
      initial = %__MODULE__{
        project_id: project_id,
        jsonl_path: jsonl_path,
        database_path: database_path,
        file_handle: file_handle,
        read_offset: 0,
        partial_line: "",
        poll_ms: poll_ms
      }

      if command_router_ready?() do
        try do
          state = boot_replay(initial)
          state = start_fs_watcher(state)
          schedule_read_more(state.poll_ms)
          {:ok, state}
        rescue
          e ->
            # Close the file handle on any boot-replay failure so we don't
            # leak an OS file descriptor. terminate/2 is NOT called when
            # init raises, so the rescue branch owns the cleanup.
            :file.close(file_handle)
            reraise e, __STACKTRACE__
        end
      else
        # `CommandRouter` starts after this (opt-in) watcher in the
        # application's children list (`maybe_beads_watcher_child/0` is
        # called before `ForemanServer.CommandRouter` in
        # `Application.start/2`), so running `boot_replay/1`
        # synchronously here would deterministically crash on any
        # project with at least one open bead at boot:
        # `with_beads_lease/2`'s `BeadsDbLease.with_lease/4` call
        # dispatches through `CommandGateway`/`CommandRouter`, which
        # raises `ArgumentError` (`:erlang.send/2` to an unregistered
        # name) rather than returning an error tuple when the router
        # isn't registered yet. Deferring via `{:continue, :boot_replay}`
        # and retrying until the router is up (`handle_continue/2`
        # below) mirrors `BootReconciliation`'s established
        # `command_router_ready?/0` guard for the identical hazard.
        # Only reached during the real production boot race — every
        # test and every normal steady-state restart finds the router
        # already registered and takes the synchronous branch above,
        # so this adds no timing change to the common case.
        {:ok, initial, {:continue, :boot_replay}}
      end
    else
      {:error, {:coverage_drift, status}} ->
        TaskProviderTelemetry.emit(
          @coverage_drift_event,
          %{system_time: System.system_time()},
          %{
            project_id: project_id,
            coverage_drift: true,
            db_exportable_issues: get_in(status, ["coverage", "db_exportable_issues"]),
            jsonl_unique_ids: get_in(status, ["coverage", "jsonl_unique_ids"]),
            dirty_count: Map.get(status, "dirty_count")
          }
        )

        {:stop, {:coverage_drift, status}}

      {:error, {:preflight_failed, _project_id, reason}} ->
        TaskProviderTelemetry.emit(
          @error_event,
          %{system_time: System.system_time()},
          %{project_id: project_id, stage: :preflight, reason: inspect(reason)}
        )

        {:stop, {:preflight_failed, reason}}

      {:error, {:file_open_failed, reason}} ->
        TaskProviderTelemetry.emit(
          @error_event,
          %{system_time: System.system_time()},
          %{project_id: project_id, stage: :file_open, reason: inspect(reason)}
        )

        {:stop, {:file_open_failed, reason}}

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
  def handle_continue(:boot_replay, state) do
    if command_router_ready?() do
      state = boot_replay(state)
      state = start_fs_watcher(state)
      schedule_read_more(state.poll_ms)
      {:noreply, state}
    else
      schedule_boot_replay_retry()
      {:noreply, state}
    end
  end

  # Retry of the `:boot_replay` continue, scheduled by
  # `schedule_boot_replay_retry/0` while `CommandRouter` was not yet
  # registered.
  def handle_info(:boot_replay_retry, state) do
    {:noreply, state, {:continue, :boot_replay}}
  end

  @impl true
  def handle_info(:read_more, state) do
    TaskProviderTelemetry.emit(
      @read_more_event,
      %{system_time: System.system_time()},
      %{project_id: state.project_id, read_offset: state.read_offset}
    )

    state = perform_read_more(state)
    schedule_read_more(state.poll_ms)
    {:noreply, state}
  end

  # Fires `@debounce_ms` after the first matching `:file_event` in a
  # burst (see the `debounce_timer: nil` guard below) — coalescing any
  # further events in that window into this single read, since
  # `read_more/2` always reads from `read_offset` to current EOF.
  def handle_info(:debounced_read_more, state) do
    state = perform_read_more(%{state | debounce_timer: nil})
    {:noreply, state}
  end

  # Primary (<1s) trigger (TRD-011): a `file_system` change from OUR
  # subscribed watcher (`fs_watcher_pid` match). Compared by basename,
  # NOT full path equality — on macOS, FSEvents (the `fs_mac` backend)
  # reports its own canonicalized, symlink-resolved path
  # (`/private/var/...`), which never string-equals a `jsonl_path`
  # rooted at the OS's un-resolved `/var/...` (or `/tmp/...`) alias —
  # even though it is the exact same file. This watcher only monitors
  # `jsonl_path`'s own parent directory, and the `fs_watcher_pid`
  # match already scopes the event to that one directory, so a
  # basename match against a file in it is unambiguous.
  def handle_info(
        {:file_event, pid, {path, _events}},
        %__MODULE__{fs_watcher_pid: pid} = state
      ) do
    if Path.basename(path) == Path.basename(state.jsonl_path) do
      schedule_debounced_read(state)
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp command_router_ready? do
    is_pid(Process.whereis(CommandRouter))
  end

  defp schedule_boot_replay_retry do
    Process.send_after(self(), :boot_replay_retry, @boot_replay_retry_ms)
  end

  # No debounce timer pending — start one. A second matching event
  # arriving while one is already pending is a no-op: it will be
  # picked up by that same upcoming read.
  defp schedule_debounced_read(%__MODULE__{debounce_timer: nil} = state) do
    timer_ref = Process.send_after(self(), :debounced_read_more, @debounce_ms)
    {:noreply, %{state | debounce_timer: timer_ref}}
  end

  defp schedule_debounced_read(state) do
    {:noreply, state}
  end

  # Shared by the poll-driven `:read_more` handler and the
  # fs-watch-driven `:debounced_read_more` handler — the lease-guarded
  # read+dispatch pass is identical either way; only the trigger
  # differs (fixed-cadence poll vs. debounced file_event).
  defp perform_read_more(state) do
    {state, _counters} = with_beads_lease(state, fn -> read_more(state, %Counters{}) end)
    state
  end

  @impl true
  def terminate(_reason, state) do
    if is_reference(state.file_handle) do
      :file.close(state.file_handle)
    end

    :ok
  end

  # ---------------------------------------------------------------------
  # Boot replay (delegates loop body to read_more/2)
  # ---------------------------------------------------------------------

  @doc """
  Read the JSONL from offset 0 to current EOF, apply the per-line
  pipeline (via `read_more/2`), then emit `[:watcher, :replay_started]`
  and `[:watcher, :replay_completed]` telemetry with the four counters
  (`lines_processed / lines_imported / lines_suppressed / lines_reconciled`)
  required by TRD §3 Risk-Mitigation (line 607).

  Boot replay and tail mode share `read_more/2` for the loop body
  so the cursor mechanics are identical in both modes.
  """
  @spec boot_replay(t()) :: t()
  def boot_replay(%__MODULE__{} = state) do
    started_at_ms = System.monotonic_time(:millisecond)

    TaskProviderTelemetry.emit(
      @replay_started_event,
      %{system_time: System.system_time()},
      %{project_id: state.project_id, jsonl_path: state.jsonl_path}
    )

    {state, counters} = with_beads_lease(state, fn -> read_more(state, %Counters{}) end)

    completed_at_ms = System.monotonic_time(:millisecond)

    TaskProviderTelemetry.emit(
      @replay_completed_event,
      %{
        system_time: System.system_time(),
        duration_ms: completed_at_ms - started_at_ms
      },
      %{
        project_id: state.project_id,
        read_offset: state.read_offset,
        partial_line_bytes: byte_size(state.partial_line),
        lines_processed: counters.lines_processed,
        lines_imported: counters.lines_imported,
        lines_suppressed: counters.lines_suppressed,
        lines_reconciled: counters.lines_reconciled,
        lines_malformed: counters.lines_malformed,
        lines_transient: counters.lines_transient
      }
    )

    state
  end

  # ----- BeadsDbLease acquisition (REQ-004, architectural risk 2) --------

  # Serializes the read/dispatch pass against a concurrent `br update`
  # (e.g. a RunExecutor-dispatched mutation via `BeadsAdapter`) racing
  # the same `.beads/` database file — both boot-time full-replay and
  # every periodic catch-up tail acquire the same lease `beads_adapter.ex`
  # already wraps every `br` write in, so the two never interleave reads
  # and writes against the SQLite file. A synthetic `run_id`/`task_id`
  # pair (unique per pass) lets the watcher hold the lease without an
  # actual Foreman task — mirrors `BeadsAdapter.create/2`'s
  # `synthetic_run_id` pattern for the same reason (dedupe calls that
  # need to serialize through the lease without a real task-bound run).
  #
  # On lease failure (acquisition timeout, dispatch error), the pass is
  # skipped for this cycle — the next poll retries — rather than
  # crashing the watcher.
  defp with_beads_lease(%__MODULE__{database_path: database_path} = state, fun)
       when is_binary(database_path) and database_path != "" and is_function(fun, 0) do
    synthetic_run_id =
      "watcher:" <> state.project_id <> ":" <> to_string(System.system_time(:nanosecond))

    case BeadsDbLease.with_lease(database_path, synthetic_run_id, synthetic_run_id, fn ->
           {:ok, fun.()}
         end) do
      {:ok, result} ->
        result

      {:error, reason} ->
        TaskProviderTelemetry.emit(
          @error_event,
          %{system_time: System.system_time()},
          %{project_id: state.project_id, stage: :lease_acquire, reason: inspect(reason)}
        )

        {state, %Counters{}}
    end
  end

  # ----- FS watch subscription (architectural risk 3, TRD-011) -----------

  # Starts a `file_system` watcher on the JSONL's parent directory and
  # subscribes the current process — called from `init/1` after
  # `boot_replay/1` completes, so `handle_info/2` starts receiving
  # `{:file_event, pid, {path, events}}` only once the initial
  # replay's own reads are done. This is the primary (<1s) trigger;
  # the periodic `:read_more` poll (`@default_poll_ms`) remains as an
  # eventual-consistency backstop in case a watch event is missed
  # (architecture §7.5 risk 3). A watcher start failure degrades to
  # poll-only rather than crashing boot.
  defp start_fs_watcher(%__MODULE__{jsonl_path: jsonl_path} = state) do
    case FileSystem.start_link(dirs: [Path.dirname(jsonl_path)]) do
      {:ok, pid} ->
        FileSystem.subscribe(pid)
        %{state | fs_watcher_pid: pid}

      :ignore ->
        # `GenServer.on_start()` (FileSystem.start_link/1's own declared
        # spec) includes `:ignore` alongside `{:ok, pid}`/`{:error, _}` —
        # the underlying OS file-watch backend can decline to start
        # without it being an error (e.g. no inotify support/permission
        # in a restricted container). Observed on Linux CI runners; not
        # reproduced on macOS dev environments. Matches the same
        # degrade-to-poll-only contract as the {:error, reason} clause
        # below, just without a reason to report.
        TaskProviderTelemetry.emit(
          @error_event,
          %{system_time: System.system_time()},
          %{project_id: state.project_id, stage: :fs_watcher_start, reason: "ignore"}
        )

        state

      {:error, reason} ->
        TaskProviderTelemetry.emit(
          @error_event,
          %{system_time: System.system_time()},
          %{project_id: state.project_id, stage: :fs_watcher_start, reason: inspect(reason)}
        )

        state
    end
  end

  # ---------------------------------------------------------------------
  # Per-line processing loop body (shared by boot replay and tail mode)
  # ---------------------------------------------------------------------

  @doc """
  Read from `read_offset` to EOF, split on `\n` (globally), and apply
  the 3-way cursor priority across each complete line.

  Scans and reduces ALL complete lines in this read; it does NOT halt at
  the first transient line. Only the FIRST transient complete-line's
  start byte is remembered as the retry cursor (`state.read_offset`);
  every later complete-line in the same read still gets an independent
  terminal-or-transient attempt via `advance_one_line/2` (see
  `apply_3_way_cursor/3`) — an earlier bead this project's workflow
  catalog cannot yet route must not permanently block every bead
  appended after it. On the next poll the read seeks back to that
  retry cursor and re-reads from there, so terminally-processed later
  lines ARE re-scanned; terminal side effects reached through them
  must therefore be safe to repeat (see `current_bead_status/2`'s live
  status check before `block_missing_trd_path/2` mutates).

  The trailing fragment (bytes after the last terminator) is preserved
  in `state.partial_line` only when no line in this read held
  transient — when one did, the held line's own bytes (already stored
  by `advance_one_line/2` via the retry cursor) take precedence and the
  trailing fragment is discarded (it will be re-read on the next poll).

  This is the loop body shared by boot replay (`boot_replay/1`) and
  tail mode (`handle_info(:read_more, ...)`); the TRD spec calls it
  `read_more/1` (TRD-011-TASK action 3, TRD-012-TASK).

  Returns `{state, counters}` so the caller can emit replay / read-more
  telemetry with the four counters
  (`lines_processed / lines_imported / lines_suppressed / lines_reconciled`)
  required by TRD §3 Risk-Mitigation (line 607).
  """
  @spec read_more(t()) :: {t(), counters()}
  def read_more(%__MODULE__{} = state) do
    read_more(state, %Counters{})
  end

  @spec read_more(t(), counters()) :: {t(), counters()}
  def read_more(%__MODULE__{} = state, counters) do
    case read_to_eof(state) do
      {:ok, raw_bytes} ->
        apply_3_way_cursor(state, raw_bytes, counters)

      {:error, reason} ->
        TaskProviderTelemetry.emit(
          @error_event,
          %{system_time: System.system_time()},
          %{project_id: state.project_id, stage: :read, reason: inspect(reason)}
        )

        {state, counters}
    end
  end

  defp read_to_eof(%__MODULE__{file_handle: dev, read_offset: offset}) do
    case :file.position(dev, offset) do
      {:ok, ^offset} -> read_chunk_loop(dev, "")
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_chunk_loop(dev, acc) do
    case :file.read(dev, @read_chunk_bytes) do
      {:ok, chunk} -> read_chunk_loop(dev, acc <> chunk)
      :eof -> {:ok, acc}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_3_way_cursor(state, raw_bytes, counters)
       when is_binary(raw_bytes) and is_struct(counters, Counters) do
    {complete_lines, trailing_fragment} = split_complete_lines(raw_bytes)

    {scanned_state, final_counters, first_transient} =
      Enum.reduce(complete_lines, {state, counters, nil}, fn line, {acc, acc_counters, held} ->
        {acc2, outcome} = advance_one_line(acc, line)
        new_counters = bump_counters(acc_counters, outcome)

        case outcome do
          :transient ->
            # `advance_one_line/2` holds `read_offset` at this line's
            # start byte on :transient (correct for a single line in
            # isolation) but does NOT halt the pass anymore: a bead
            # this project's workflow catalog cannot yet route (or
            # whose dispatch transiently failed) must not permanently
            # block every bead appended after it — one unresolved
            # early bead blocking an entire project's auto-dispatch
            # forever is the defect this replaces. Remember only the
            # FIRST transient line's start byte (the correct retry
            # position — TRD §2.2.6's "first not terminally dispatched
            # line" definition), then keep scanning with a working
            # copy whose `read_offset` is advanced manually past this
            # line so later lines still compute correct dispatch state
            # and get a fair, independent attempt this same pass.
            held = held || {acc2.read_offset, line}
            advanced = %{acc2 | read_offset: acc.read_offset + byte_size(line) + 1}
            {advanced, new_counters, held}

          _ ->
            {acc2, new_counters, held}
        end
      end)

    case first_transient do
      nil ->
        {%{scanned_state | partial_line: trailing_fragment}, final_counters}

      {offset, line} ->
        {%{scanned_state | read_offset: offset, partial_line: line}, final_counters}
    end
  end

  @spec bump_counters(counters(), atom() | {:unknown, term()}) :: counters()
  defp bump_counters(counters, outcome) do
    %Counters{
      lines_processed: counters.lines_processed + 1,
      lines_imported: counters.lines_imported + if(outcome == :imported, do: 1, else: 0),
      lines_suppressed: counters.lines_suppressed + if(outcome == :skipped, do: 1, else: 0),
      lines_reconciled: counters.lines_reconciled + if(outcome == :reconciled, do: 1, else: 0),
      lines_malformed: counters.lines_malformed + if(outcome == :malformed, do: 1, else: 0),
      lines_transient: counters.lines_transient + if(outcome == :transient, do: 1, else: 0)
    }
  end

  @doc """
  Split raw bytes from the JSONL read into complete lines and the
  trailing fragment.

  Returns `{complete_lines, trailing_fragment}` where:

    * `complete_lines` is a list of binaries, each one terminated by
      `\n` in the input (the terminator is NOT included in the
      returned binary — it is implied at `byte_size(line) + 1`).
    * `trailing_fragment` is the bytes after the last `\n`, possibly
      empty (when the input ended on a terminator) or possibly the
      entire input (when the input has no terminator at all).

  Order is preserved on-disk (head-first).

  Uses `:binary.split/3` with `[:global]` so every `\n` in the input
  is treated as a separator; without `[:global]` only the first split
  would happen.
  """
  @spec split_complete_lines(binary()) :: {[binary()], binary()}
  def split_complete_lines(raw_bytes) when is_binary(raw_bytes) do
    case :binary.split(raw_bytes, "\n", [:global]) do
      [] ->
        {[], ""}

      [trailing] ->
        {[], trailing}

      parts ->
        {init, [trailing]} = Enum.split(parts, -1)
        {init, trailing}
    end
  end

  @doc """
  Advance the cursor for one complete line per the 3-way cursor priority.

  Returns `{new_state, outcome}` where `outcome` is one of:

    * `:imported` / `:skipped` / `:reconciled` / `:rejected` — terminal
      advance (`read_offset` moves past `byte_size(line) + 1`).
    * `:malformed` — terminal advance (the line was structurally
      unrecoverable; advancing past it prevents an infinite loop on
      the same byte offset).
    * `:transient` — transient hold (`read_offset` HOLDS at the
      transient-line start byte; `partial_line` is the transient bytes).

  Any other outcome is treated as transient (defensive: preserves the
  single-cursor invariant when the pipeline returns an unexpected atom).
  """
  @spec advance_one_line(t(), binary()) :: {t(), atom()}
  def advance_one_line(%__MODULE__{} = state, line) when is_binary(line) do
    outcome = process_line(state, line)
    line_byte_size = byte_size(line)

    case outcome do
      :imported ->
        {%{state | read_offset: state.read_offset + line_byte_size + 1}, :imported}

      :skipped ->
        {%{state | read_offset: state.read_offset + line_byte_size + 1}, :skipped}

      :reconciled ->
        {%{state | read_offset: state.read_offset + line_byte_size + 1}, :reconciled}

      :rejected ->
        {%{state | read_offset: state.read_offset + line_byte_size + 1}, :rejected}

      :malformed ->
        {%{state | read_offset: state.read_offset + line_byte_size + 1}, :malformed}

      :transient ->
        {%{state | partial_line: line}, :transient}
    end
  end

  @doc """
  Apply the full status-gated parse + dedupe + suppress + select +
  dispatch-and-approve pipeline to one complete JSONL line.

  Steps (in order):

    1. Parse JSON. On parse failure, return `:malformed` (terminal
       advance; the line is structurally unrecoverable and emitting
       `[:watcher, :malformed]` lets operators diagnose data
       corruption without retrying forever).
    2. Check `agent_context.foreman` (AC-022-3). If truthy, emit
       `[:watcher, :skipped]` and return `:skipped` (terminal advance;
       the bead is owned by Foreman and will be reconciled by the
       orphan janitor or downstream workflow).
    3. Check `ProjectionStore.get_task(external_id: bead.id)`
       (AC-022-2). No projected task → proceed. A projected task still
       `status: "open"` (a prior `task.create` succeeded, or was
       already idempotently present, but the matching `task.approve`
       previously failed) → retry approval directly, without a new
       `task.create` dispatch (see step 7's `:imported`/`:transient`
       rule below — nothing else in the system retries `task.approve`,
       so treating this as `:reconciled` would strand the task
       forever). A projected task past `"open"` → emit
       `[:watcher, :reconciled]` and return `:reconciled` (terminal
       advance; the bead has already been imported and approved, and
       the dedupe hit is the safety net for cross-restart recovery and
       operator-vs-watcher races).
    4. Status gate (AC-003-1, AC-003-3). Accept only `status: "open"`;
       any other value (including `draft`, `blocked`, `closed`) emits
       `[:watcher, :status_gate, :skipped, :draft_status]` and returns
       `:skipped` (terminal advance — no task, no bead mutation).
    5. Workflow selection (REQ-001). Resolve `issue_type` via
       `Catalog.type_to_workflow/1`. An unmapped type emits
       `[:watcher, :status_gate, :skipped, :unmapped_type]` and
       returns `:transient` (the cursor holds; the operator updates
       the workflow manifests and the next poll retries).
    6. `trd_path` check (REQ-007, AC-007-1, AC-007-2). Workflows that
       provision an `ImplementationContext` (`implement-trd`,
       `implement-trd-beads`) require a non-empty
       `agent_context.trd_path`. When required but missing/empty, the
       bead is moved to `blocked` with the architecture §8.4 transition
       comment, `[:watcher, :status_gate, :skipped, :missing_trd_path]`
       is emitted, and the line returns `:skipped` (terminal advance;
       no task created).
       Otherwise the resolved `trd_path` (or `nil` when not required)
       flows into the `task.create` payload.
    7. Otherwise, synthesize the deterministic `task.create` envelope
       and dispatch via `CommandGateway.dispatch_system/2` (the
       trusted system path). A return meaning a task now exists
       (`{:ok, _}` or `{:error, {:already_exists, :task, _}}`)
       immediately dispatches the matching `task.approve` (AC-003-2 — a
       single effective create-and-approve step, no separate operator
       action). `:imported` (with `[:watcher, :imported]`) is reported
       only once that `task.approve` also succeeds; a `task.create`
       success followed by a failed `task.approve` instead returns
       `:transient` — the cursor holds, and step 3's dedupe check
       routes the next poll's replay of this line back into a fresh
       approval attempt (the projected task still reads `status:
       "open"`) rather than treating it as reconciled.
       A return meaning the aggregate rejected creation outright before
       any task existed (`{:error, {:invalid_task_status, _}}`,
       `{:error, {:project_archived, _}}`, or
       `{:error, :project_id_required}`) emits `[:watcher, :rejected]`
       and returns `:rejected` (terminal advance — no task was created,
       so there is nothing to approve, and retrying will not change an
       archived project or a rejected status). Any other create return
       emits `[:watcher, :error]` and returns `:transient` (so the
       cursor holds and the line is retried on the next poll).

  Returns one of
  `:imported | :skipped | :reconciled | :rejected | :malformed | :transient`.
  """
  @spec process_line(t(), binary()) :: atom()
  def process_line(state, line) when is_binary(line) do
    TaskProviderTelemetry.emit(
      @line_processed_event,
      %{system_time: System.system_time()},
      %{project_id: state.project_id, line_bytes: byte_size(line)}
    )

    with {:ok, parsed} <- decode_line(line),
         :ok <- check_foreman_tag(state, parsed),
         :ok <- check_prompt(parsed),
         :ok <- check_dedupe(state, parsed),
         :ok <- check_status(state, parsed),
         {:ok, workflow_type} <- select_workflow(state, parsed),
         {:ok, trd_path} <- check_trd_path(state, parsed, workflow_type) do
      dispatch_new_bead(state, parsed, workflow_type, trd_path)
    else
      :skip_foreman ->
        :skipped

      :skip_status ->
        :skipped

      {:error, :unmapped_type} ->
        :transient

      {:error, :missing_trd_path} ->
        :skipped

      :reconcile ->
        :reconciled

      {:retry_approval, bead_id} ->
        finish_approval(state, bead_id, auto_approve_bead(state, bead_id))

      :malformed ->
        TaskProviderTelemetry.emit(
          @malformed_event,
          %{system_time: System.system_time()},
          %{project_id: state.project_id, line_bytes: byte_size(line)}
        )

        :malformed
    end
  end

  # ----- JSON parse -----------------------------------------------------

  defp decode_line(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, parsed} when is_map(parsed) -> {:ok, parsed}
      {:ok, _other} -> :malformed
      {:error, _reason} -> :malformed
    end
  end

  # ----- Foreman-tag suppression (AC-022-3) ------------------------------

  defp check_foreman_tag(state, parsed) when is_map(parsed) do
    case foreman_tag?(parsed) do
      true ->
        bead_id = Map.get(parsed, "id")

        TaskProviderTelemetry.emit(
          @skipped_event,
          %{system_time: System.system_time()},
          %{project_id: state.project_id, bead_id: bead_id}
        )

        :skip_foreman

      false ->
        :ok
    end
  end

  defp foreman_tag?(parsed) when is_map(parsed) do
    agent_context = Map.get(parsed, "agent_context", %{}) || %{}
    is_map(agent_context) and Map.has_key?(agent_context, "foreman")
  end

  # ----- Prompt validation --------------------------------------------
  # `bead_prompt/1` (see `synthesize_task_create_envelope/5`) is the
  # ONLY channel a `command:` phase has for its subject
  # (`{{input.prompt}}`). A bead with neither a usable `title` nor
  # `description` would still pass `id`/`issue_type` validation and
  # reach `task.create` with an empty prompt, silently producing a
  # task no command-phase workflow can act on. Reject it here instead
  # -- checked independently of `bead_prompt/1` itself, since that
  # function assumes a binary `title` and would raise on e.g. a
  # numeric one; a non-binary title is exactly as unusable as a blank
  # one for this purpose.
  defp check_prompt(parsed) when is_map(parsed) do
    title = Map.get(parsed, "title")
    description = Map.get(parsed, "description")

    if blank?(title) and blank?(description) do
      :malformed
    else
      :ok
    end
  end

  defp blank?(value), do: not (is_binary(value) and String.trim(value) != "")

  # ----- ProjectionStore dedupe (AC-022-2) --------------------------------

  defp check_dedupe(state, parsed) when is_map(parsed) do
    case Map.get(parsed, "id") do
      bead_id when is_binary(bead_id) and bead_id != "" ->
        case projection_store().get_task(external_id: bead_id) do
          nil ->
            :ok

          %{status: "open"} ->
            # `task.create` previously succeeded (or was already
            # idempotently present) for this bead, but the task was
            # never approved — `TaskApproved` is the only event that
            # advances a task's projected status past `"open"`. Nothing
            # else in the system retries `task.approve`, so treating
            # this as `:reconcile` here would strand the task forever:
            # every later replay of this same line would hit this exact
            # branch and dedupe it away without ever re-attempting
            # approval. Retry the approval directly instead.
            {:retry_approval, bead_id}

          _existing ->
            TaskProviderTelemetry.emit(
              @reconciled_event,
              %{system_time: System.system_time()},
              %{project_id: state.project_id, bead_id: bead_id}
            )

            :reconcile
        end

      _ ->
        :ok
    end
  end

  # ----- Status gate (AC-003-1, AC-003-2, AC-003-3) -----------------------

  defp check_status(state, parsed) when is_map(parsed) do
    case Map.get(parsed, "status") do
      "open" ->
        :ok

      _other ->
        bead_id = Map.get(parsed, "id")

        TaskProviderTelemetry.emit(
          @status_gate_skipped_draft_status_event,
          %{system_time: System.system_time()},
          %{project_id: state.project_id, bead_id: bead_id}
        )

        :skip_status
    end
  end

  # ----- Workflow selection (REQ-001) -------------------------------------

  defp select_workflow(state, parsed) when is_map(parsed) do
    case Map.get(parsed, "issue_type") do
      issue_type when is_binary(issue_type) and issue_type != "" ->
        resolve_workflow_type(state, parsed, issue_type)

      _missing_or_invalid ->
        :malformed
    end
  end

  defp resolve_workflow_type(state, parsed, issue_type) do
    case workflow_catalog().type_to_workflow(issue_type) do
      {:ok, workflow_type} ->
        {:ok, workflow_type}

      {:error, :unmapped_type} ->
        bead_id = Map.get(parsed, "id")

        TaskProviderTelemetry.emit(
          @status_gate_skipped_unmapped_type_event,
          %{system_time: System.system_time()},
          %{project_id: state.project_id, bead_id: bead_id, issue_type: issue_type}
        )

        {:error, :unmapped_type}
    end
  end

  # ----- trd_path extraction (REQ-007, AC-007-1, AC-007-2) ----------------

  # Workflows that provision an ImplementationContext require `trd_path` —
  # matches the `name:` field in implement-trd.yaml / implement-trd-beads.yaml.
  @trd_path_required_workflows ~w(implement-trd implement-trd-beads)

  defp check_trd_path(state, parsed, workflow_type) when is_map(parsed) do
    if workflow_type in @trd_path_required_workflows do
      case extract_trd_path(parsed) do
        trd_path when is_binary(trd_path) and trd_path != "" ->
          {:ok, trd_path}

        _empty_or_missing ->
          bead_id = Map.get(parsed, "id")
          block_missing_trd_path(state, bead_id)
          {:error, :missing_trd_path}
      end
    else
      {:ok, nil}
    end
  end

  defp extract_trd_path(parsed) do
    case Map.get(parsed, "agent_context") do
      agent_context when is_map(agent_context) -> Map.get(agent_context, "trd_path")
      _other -> nil
    end
  end

  # Architecture §8.4 resolved design question 4 — exact operator-visible
  # transition comment text. `bead_id` is substituted in place of the
  # doc's `<id>` placeholder so the re-run command is copy-paste ready;
  # the trd_path JSON shape stays illustrative since only the operator
  # knows the real path to supply.
  defp block_missing_trd_path(state, bead_id) when is_binary(bead_id) and bead_id != "" do
    # The cursor no longer halts on an earlier held :transient line
    # (see `apply_3_way_cursor/3`), so this line can be re-scanned on a
    # later poll while the earlier line is still unresolved. Without a
    # fresh check, a bead already transitioned to "blocked" by a prior
    # pass would be re-blocked with a duplicate `br update` transition
    # comment on every subsequent poll. Confirm current status live
    # before mutating; skip (no-op, :ok) if it's already moved off
    # "open" — the file's own cached `status` field is exactly the
    # stale value this check exists to not trust.
    case current_bead_status(state, bead_id) do
      {:ok, "open"} -> do_block_missing_trd_path(state, bead_id)
      {:ok, _already_transitioned} -> :ok
      # A `:show` failure (transient runner/CLI error, or output this
      # watcher cannot decode) does not mean the bead is already
      # blocked — attempt the transition rather than silently skip it.
      # `check_trd_path/3` (the sole caller) discards this function's
      # return value and always advances the line as terminal
      # (`:skipped`) regardless, so there is no `:transient` outcome to
      # propagate here without also restructuring that caller; the
      # worst case on a rare runner error is one redundant `br update`,
      # not the every-poll spam this guard exists to prevent.
      {:error, _reason} -> do_block_missing_trd_path(state, bead_id)
    end
  end

  defp block_missing_trd_path(state, _bead_id) do
    # No `id` to target with `br update` — nothing to block. Still emit
    # telemetry so the missing-trd_path outcome is observable; the line
    # advances via :skipped either way (this bead cannot be acted on).
    TaskProviderTelemetry.emit(
      @status_gate_skipped_missing_trd_path_event,
      %{system_time: System.system_time()},
      %{project_id: state.project_id, bead_id: nil}
    )

    :ok
  end

  defp current_bead_status(state, bead_id) do
    request = {:show, %{id: bead_id}}
    project_config = %{database_path: state.database_path}

    case @runner.cmd(request, project_config, timeout_ms: @preflight_timeout_ms) do
      {:ok, %{stdout: stdout}} ->
        case Jason.decode(stdout) do
          {:ok, %{"status" => status}} when is_binary(status) -> {:ok, status}
          {:ok, [%{"status" => status} | _]} when is_binary(status) -> {:ok, status}
          _other -> {:error, :status_undecodable}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_block_missing_trd_path(state, bead_id) do
    comment =
      "Blocked: workflow requires trd_path in agent_context. Re-run: br update #{bead_id} --agent-context '{\"trd_path\":\"docs/TRD/...\"}' --status open"

    request =
      {:update, %{flags: [bead_id, "--status", "blocked", "--transition-comment", comment]}}

    project_config = %{database_path: state.database_path}

    update_result =
      case @runner.cmd(request, project_config, timeout_ms: @preflight_timeout_ms) do
        {:ok, _result} ->
          :ok

        {:error, reason} ->
          TaskProviderTelemetry.emit(
            @error_event,
            %{system_time: System.system_time()},
            %{
              project_id: state.project_id,
              stage: :block_missing_trd_path,
              bead_id: bead_id,
              reason: inspect(reason)
            }
          )

          {:error, reason}
      end

    # `check_trd_path/3` (the sole caller) always advances with
    # `{:error, :missing_trd_path}` regardless of this outcome — a bead
    # with no trd_path is never dispatchable either way, so a failed `br
    # update` doesn't change Foreman's own next action here. It DOES mean
    # the bead's status in Beads itself may still read as its old status
    # rather than "blocked" — `@error_event` above is the observable
    # signal for that divergence; the return value is kept honest rather
    # than hardcoded to `:ok` so a future caller can't be misled about
    # whether the transition actually took effect.
    TaskProviderTelemetry.emit(
      @status_gate_skipped_missing_trd_path_event,
      %{system_time: System.system_time()},
      %{project_id: state.project_id, bead_id: bead_id}
    )

    update_result
  end

  # ----- Dispatch new bead (AC-022-1) -------------------------------------

  defp dispatch_new_bead(state, parsed, workflow_type, trd_path) when is_map(parsed) do
    bead_id = Map.get(parsed, "id")

    if is_binary(bead_id) and bead_id != "" do
      envelope = synthesize_task_create_envelope(state, parsed, bead_id, workflow_type, trd_path)
      # Dispatch is unconditional — every shape (incl. {:exit, _} and
      # retryable ProviderError) reaches classify_dispatch_result/3, which
      # routes anything non-terminal to :transient and holds the cursor.
      result = command_gateway().dispatch_system(envelope, 5_000)
      classify_dispatch_result(state, bead_id, result)
    else
      # Bead with no `id` cannot be dispatched (no external_id). Skip
      # silently with a malformed classification so the cursor advances.
      :malformed
    end
  end

  defp synthesize_task_create_envelope(state, parsed, bead_id, workflow_type, trd_path) do
    task_id = "beads:" <> state.project_id <> ":" <> bead_id

    %{
      command_id: "beads-cmd:" <> state.project_id <> ":" <> bead_id,
      aggregate_id: "task:" <> task_id,
      type: "task.create",
      payload: %{
        task_id: task_id,
        external_id: bead_id,
        title: Map.get(parsed, "title", ""),
        description: Map.get(parsed, "description"),
        # `Task.prompt` is what `Approval.prepare/2`'s `maybe_put_prompt/2`
        # copies into `workflow_snapshot["input"]["prompt"]`, which is the
        # ONLY channel a `command:` phase has for its subject
        # (`{{input.prompt}}` in the manifest's `command:` string — see
        # `RunExecutor.input_prompt/1`). Without this, every bead
        # auto-dispatched by BeadsWatcher to a command-phase workflow
        # (e.g. `fix.yaml`'s `/skill:ensemble-fix-issue {{input.prompt}}
        # --foreman`) renders with an EMPTY argument — the agent has no
        # subject and immediately asks for one instead of doing any work.
        # Falls back to the title alone when there's no description.
        prompt: bead_prompt(parsed),
        priority: Map.get(parsed, "priority", 2),
        task_type: Map.get(parsed, "issue_type", "task"),
        workflow_type: workflow_type,
        trd_path: trd_path,
        project_id: state.project_id
      }
    }
  end

  defp bead_prompt(parsed) do
    fields =
      ["title", "description"]
      |> Enum.map(&Map.get(parsed, &1))
      |> Enum.map(&normalize_prompt_field/1)
      |> Enum.reject(&(&1 == ""))

    Enum.join(fields, "\n\n")
  end

  defp normalize_prompt_field(value) when is_binary(value), do: String.trim(value)
  defp normalize_prompt_field(_non_binary_or_absent), do: ""

  defp classify_dispatch_result(state, bead_id, result) do
    cond do
      task_created_or_existing?(result) ->
        finish_approval(state, bead_id, auto_approve_bead(state, bead_id))

      terminal_rejection?(result) ->
        # No task was created — `validate_status/1`, `validate_project_allows_tasks/1`,
        # and their command-gateway equivalents reject BEFORE any event is
        # appended. Approving a task that does not exist would itself fail,
        # and reporting `:imported` here would tell an operator a bead was
        # brought in when it never was. The line is still terminal (retrying
        # an archived project or an invalid status will not change the
        # outcome), so the cursor still advances — just under a distinct
        # outcome that is never counted as an import.
        TaskProviderTelemetry.emit(
          @rejected_event,
          %{system_time: System.system_time()},
          %{
            project_id: state.project_id,
            bead_id: bead_id,
            result: result
          }
        )

        :rejected

      true ->
        TaskProviderTelemetry.emit(
          @error_event,
          %{system_time: System.system_time()},
          %{
            project_id: state.project_id,
            stage: :dispatch,
            bead_id: bead_id,
            result: result
          }
        )

        :transient
    end
  end

  # A real task now exists under this bead's external_id — either freshly
  # created or already present from a prior attempt — so approving it is
  # meaningful and reporting `:imported` is accurate.
  defp task_created_or_existing?({:ok, _result}), do: true
  defp task_created_or_existing?({:error, {:already_exists, :task, _id}}), do: true
  defp task_created_or_existing?(_other), do: false

  # Terminal (non-retryable) but no task was created. Distinct from
  # `task_created_or_existing?/1` so `classify_dispatch_result/3` never
  # attempts to approve, and never reports `:imported`, a task.create the
  # aggregate refused outright.
  defp terminal_rejection?({:error, {:invalid_task_status, _reason}}), do: true
  defp terminal_rejection?({:error, {:project_archived, _reason}}), do: true
  defp terminal_rejection?({:error, :project_id_required}), do: true
  defp terminal_rejection?(_other), do: false

  # ----- Auto-approval (REQ-003, AC-003-2) --------------------------------

  # Dispatches the matching `task.approve` immediately after a successful
  # `task.create`, via the same trusted `dispatch_system/2` path (never
  # `dispatch_operator/2` — the watcher is system automation, not an
  # operator). From the operator's perspective this is a single effective
  # create-and-approve step: no separate approval action is ever required.
  defp auto_approve_bead(state, bead_id) do
    task_id = "beads:" <> state.project_id <> ":" <> bead_id

    approve_command = %{
      command_id: "beads-cmd:" <> state.project_id <> ":" <> bead_id <> ":auto-approve",
      type: "task.approve",
      aggregate_id: "task:" <> task_id,
      payload: %{task_id: task_id, approved_by: "beads_watcher"}
    }

    case command_gateway().dispatch_system_approval(approve_command, 5_000) do
      {:ok, _result} = ok ->
        TaskProviderTelemetry.emit(
          @dispatch_and_approve_event,
          %{system_time: System.system_time()},
          %{project_id: state.project_id, bead_id: bead_id, task_id: task_id}
        )

        ok

      other ->
        TaskProviderTelemetry.emit(
          @error_event,
          %{system_time: System.system_time()},
          %{
            project_id: state.project_id,
            stage: :auto_approve,
            bead_id: bead_id,
            task_id: task_id,
            result: other
          }
        )

        other
    end
  end

  # `task_created_or_existing?/1` covers both a freshly created task and
  # one already present from a prior `task.create` attempt (idempotent
  # retry) or a prior approval attempt (`check_dedupe/2` routing
  # `{:retry_approval, bead_id}` straight to `finish_approval/3` with no
  # new `task.create` dispatch). Reporting `:imported` is accurate only
  # once approval actually succeeds — `:imported` before then would
  # strand a created-but-unapproved task, since nothing else retries
  # `task.approve` and a later replay's `check_dedupe/2` would otherwise
  # treat "task exists" as fully reconciled (see the moduledoc's
  # workflow-selection paragraph). On failure, hold the cursor with
  # `:transient` instead: `check_dedupe/2` keeps seeing `status: "open"`
  # on this task and routes the next poll's replay of the same line back
  # into a fresh approval attempt rather than `:reconcile`.
  # `auto_approve_bead/2` has already emitted `@error_event` for a
  # failure.
  defp finish_approval(state, bead_id, {:ok, _} = approve_result) do
    TaskProviderTelemetry.emit(
      @imported_event,
      %{system_time: System.system_time()},
      %{
        project_id: state.project_id,
        bead_id: bead_id,
        result: :ok,
        approve_result: approve_result
      }
    )

    :imported
  end

  defp finish_approval(_state, _bead_id, _approve_result), do: :transient

  # ---------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------

  # Resolve the JSONL tail target for `project_id`.
  #
  # `br where --db <database_path> --json` returns a JSON document of the
  # form `{"path", "prefix", "database_path", "jsonl_path"}` per REQ-022.
  # The watcher's tail target is the `"jsonl_path"` key, NOT the
  # `database_path` (the JSONL is the append-only event log under the
  # same `.beads/` directory). The runner response shape is `%{stdout,
  # stderr, exit_code}` per `SystemBrRunner.cmd/3`.
  defp resolve_jsonl_path(project_id, database_path)
       when is_binary(project_id) and is_binary(database_path) do
    request = {:where, %{database_path: database_path}}
    project_config = %{database_path: database_path}

    case @runner.cmd(request, project_config, timeout_ms: @preflight_timeout_ms) do
      {:ok, %{stdout: stdout}} ->
        decode_jsonl_path(project_id, stdout)

      {:ok, other} ->
        {:error, {:unexpected_preflight_response, project_id, other}}

      {:error, reason} ->
        {:error, {:preflight_failed, project_id, reason}}
    end
  end

  defp decode_jsonl_path(project_id, stdout) when is_binary(stdout) do
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
  end

  # Refuse to start the boot-time full-replay over a partial/corrupted
  # snapshot (TRD §7 architectural risk 1). `br sync --status --json`
  # reports `coverage_drift` — true when the SQLite DB and the JSONL
  # export have diverged (e.g. an interrupted `br sync`, a hand-edited
  # JSONL, or a stale export). Returns `:ok` to proceed on `false` OR
  # when the check itself cannot be completed (a missing/erroring `br`
  # binary is a pre-existing operational problem, not a new failure
  # mode this gate should introduce) — only an explicit
  # `coverage_drift: true` refuses the start.
  defp check_coverage_drift(project_id, database_path)
       when is_binary(project_id) and is_binary(database_path) do
    request = {:sync_status, %{flags: ["--status"]}}
    project_config = %{database_path: database_path}

    case @runner.cmd(request, project_config, timeout_ms: @preflight_timeout_ms) do
      {:ok, %{stdout: stdout}} ->
        case Jason.decode(stdout) do
          {:ok, %{"coverage_drift" => true} = status} ->
            {:error, {:coverage_drift, status}}

          # Covers `coverage_drift: false`, a missing `coverage_drift` key,
          # and undecodable `stdout` alike — all three are "the check
          # itself cannot be completed to a definite true" per the policy
          # documented above, not just the outer `{:error, _reason}` case.
          _decoded_or_not ->
            :ok
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp schedule_read_more(poll_ms) when is_integer(poll_ms) and poll_ms > 0 do
    Process.send_after(self(), :read_more, poll_ms)
  end
end
