defmodule ForemanServer.TaskProviders.BeadsWatcher do
  @moduledoc """
  Per-project tail of the Beads JSONL stream.

  Each registered project gets one supervised `GenServer` process that:

    * On `init/1`, resolves the JSONL path via the configured `BrRunner`
      implementation (`@runner`, default `SystemBrRunner`, test override
      `BrRunnerMock`), opens the file with `:file.open/2`, runs
      `boot_replay/1` (offset 0 → EOF under the 3-way cursor priority),
      then schedules the first tail-mode `:read_more` via
      `Process.send_after/3`.
    * In tail mode, polls the JSONL on a fixed cadence
      (`Process.send_after(self(), :read_more, poll_ms)`).
    * For each complete line, applies the full pipeline via
      `process_line/2`: parse JSON → check `agent_context.foreman`
      (suppress + `:skipped` per AC-022-3) → check
      `ProjectionStore.get_task(external_id: bead.id)`
      (dedupe + `:reconciled` per AC-022-2) → otherwise synthesize a
      deterministic `task.create` envelope and dispatch via
      `CommandGateway.dispatch_system/2` (`:imported` per AC-022-1).

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
  parse + dedupe + suppress + dispatch pipeline, then captures the
  boot-completion cursor and enters tail mode. The `ProjectionStore`
  dedupe check is the cross-restart safety net — operator beads that
  arrived during downtime are recovered on the next boot's replay.

  ## Opt-in supervision (TRD §2.2.6 item 9)

  The supervisor child is added by `ForemanServer.Application.maybe_beads_watcher_child/0`
  (TRD-014-TASK) and reads `:start_beads_watcher?` (default `false`).
  Per-project process registration is handled by the TRD-014 supervisor
  design — this module's `start_link/1` simply accepts a `:name` opt so
  the supervisor can choose the registration strategy.
  """

  use GenServer

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

  @type t :: %__MODULE__{
          project_id: String.t(),
          jsonl_path: String.t(),
          file_handle: :file.io_device(),
          read_offset: non_neg_integer(),
          partial_line: binary(),
          poll_ms: pos_integer()
        }

  defstruct [:project_id, :jsonl_path, :file_handle, :read_offset, :partial_line, :poll_ms]

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

  @default_poll_ms 1_000
  @preflight_timeout_ms 30_000
  @read_chunk_bytes 64 * 1024

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

    with {:ok, jsonl_path} <- resolve_jsonl_path(project_id, database_path),
         {:ok, file_handle} <- :file.open(jsonl_path, [:read, :binary, :raw]) do
      try do
        initial = %__MODULE__{
          project_id: project_id,
          jsonl_path: jsonl_path,
          file_handle: file_handle,
          read_offset: 0,
          partial_line: "",
          poll_ms: poll_ms
        }

        state = boot_replay(initial)
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
  def handle_info(:read_more, state) do
    TaskProviderTelemetry.emit(
      @read_more_event,
      %{system_time: System.system_time()},
      %{project_id: state.project_id, read_offset: state.read_offset}
    )

    {state, _counters} = read_more(state, %Counters{})
    schedule_read_more(state.poll_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

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

    {state, counters} = read_more(state, %Counters{})

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

  # ---------------------------------------------------------------------
  # Per-line processing loop body (shared by boot replay and tail mode)
  # ---------------------------------------------------------------------

  @doc """
  Read from `read_offset` to EOF, split on `\n` (globally), and apply
  the 3-way cursor priority across each complete line.

  Stops at the FIRST transient complete-line so subsequent lines in
  this read are NOT processed (they will be re-read on the next poll
  because the next poll seeks to the transient-line start byte and
  re-reads from there).

  The trailing fragment (bytes after the last terminator) is preserved
  in `state.partial_line` only when the loop reached EOF without
  stopping at a transient — when the loop stopped at a transient,
  the transient-line bytes (already stored by `advance_one_line/2`)
  take precedence and the trailing fragment is discarded
  (it will be re-read on the next poll).

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

    {advanced_state, final_counters, stopped_at_transient?} =
      Enum.reduce_while(complete_lines, {state, counters, false}, fn line,
                                                                     {acc, acc_counters,
                                                                      _stopped?} ->
        {acc2, outcome} = advance_one_line(acc, line)
        new_counters = bump_counters(acc_counters, outcome)

        case outcome do
          :transient ->
            {:halt, {acc2, new_counters, true}}

          _ ->
            {:cont, {acc2, new_counters, false}}
        end
      end)

    if stopped_at_transient? do
      {advanced_state, final_counters}
    else
      {%{advanced_state | partial_line: trailing_fragment}, final_counters}
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

    * `:imported` / `:skipped` / `:reconciled` — terminal advance
      (`read_offset` moves past `byte_size(line) + 1`).
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

      :malformed ->
        {%{state | read_offset: state.read_offset + line_byte_size + 1}, :malformed}

      :transient ->
        {%{state | partial_line: line}, :transient}
    end
  end

  @doc """
  Apply the parse + dedupe + suppress + dispatch pipeline to one
  complete JSONL line.

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
       (AC-022-2). If a task is already projected with this
       `external_id`, emit `[:watcher, :reconciled]` and return
       `:reconciled` (terminal advance; the bead has already been
       imported and the dedupe hit is the safety net for cross-restart
       recovery and operator-vs-watcher races).
    4. Otherwise, synthesize the deterministic `task.create` envelope
       (per TRD §3 TRD-012-TASK spec, lines 453–) and dispatch via
       `CommandGateway.dispatch_system/2` (the trusted system path).
       On a terminal return, emit `[:watcher, :imported]` and return
       `:imported`. On any other return, emit `[:watcher, :error]`
       and return `:transient` (so the cursor holds and the line is
       retried on the next poll).

  Returns one of `:imported | :skipped | :reconciled | :malformed | :transient`.
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
         :ok <- check_dedupe(state, parsed) do
      dispatch_new_bead(state, parsed)
    else
      :skip_foreman ->
        :skipped

      :reconcile ->
        :reconciled

      :malformed ->
        TaskProviderTelemetry.emit(
          @malformed_event,
          %{system_time: System.system_time()},
          %{project_id: state.project_id, line_bytes: byte_size(line)}
        )

        :malformed
    end
  end

  # ----- Step 1: JSON parse --------------------------------------------

  defp decode_line(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, parsed} when is_map(parsed) -> {:ok, parsed}
      {:ok, _other} -> :malformed
      {:error, _reason} -> :malformed
    end
  end

  # ----- Step 2: Foreman-tag suppression (AC-022-3) --------------------

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

  # ----- Step 3: ProjectionStore dedupe (AC-022-2) ---------------------

  defp check_dedupe(state, parsed) when is_map(parsed) do
    case Map.get(parsed, "id") do
      bead_id when is_binary(bead_id) and bead_id != "" ->
        case projection_store().get_task(external_id: bead_id) do
          nil ->
            :ok

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

  # ----- Step 4: Dispatch new bead (AC-022-1) -------------------------

  defp dispatch_new_bead(state, parsed) when is_map(parsed) do
    bead_id = Map.get(parsed, "id")

    if is_binary(bead_id) and bead_id != "" do
      envelope = synthesize_task_create_envelope(state, parsed, bead_id)
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

  defp synthesize_task_create_envelope(state, parsed, bead_id) do
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
        priority: Map.get(parsed, "priority", 2),
        task_type: Map.get(parsed, "issue_type", "task"),
        project_id: state.project_id
      }
    }
  end

  defp classify_dispatch_result(state, bead_id, result) do
    if terminal_dispatch?(result) do
      TaskProviderTelemetry.emit(
        @imported_event,
        %{system_time: System.system_time()},
        %{project_id: state.project_id, bead_id: bead_id, result: :ok}
      )

      :imported
    else
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

  # TRD §2.2.6 item 7 — EXHAUSTIVE terminal set.
  @spec terminal_dispatch?(term()) :: boolean()
  defp terminal_dispatch?({:ok, _result}), do: true

  defp terminal_dispatch?({:error, {:already_exists, :task, _id}}), do: true
  defp terminal_dispatch?({:error, {:invalid_task_status, _reason}}), do: true
  defp terminal_dispatch?({:error, {:project_archived, _reason}}), do: true
  defp terminal_dispatch?({:error, :project_id_required}), do: true
  defp terminal_dispatch?(_other), do: false

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

  defp schedule_read_more(poll_ms) when is_integer(poll_ms) and poll_ms > 0 do
    Process.send_after(self(), :read_more, poll_ms)
  end
end
