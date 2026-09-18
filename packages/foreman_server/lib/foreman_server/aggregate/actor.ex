defmodule ForemanServer.Aggregate.Actor do
  import Bitwise

  @moduledoc """
  Supervised GenServer that holds aggregate state and stream version.

  The Actor retains `{module_state, version}` where `version` is the stream
  length at the time state was computed — captured BEFORE `handle_command` is called.
  This prevents external appends (while parked) from shifting the append baseline.

  ## Event spec vs persistence

  - `handle_command` returns `{:ok, event_spec}` where `event_spec` is a map:
      `%{stream_id: "...", event_type: "...", payload: %{...}}`
    Or `{:ok, nil}` for no-op commands.
  - Actor normalizes `event_spec` → `%EventData{}` for `append_to_stream`.
  - After append confirmed, Actor calls `apply_event(state, event_spec)`.
    The aggregate uses `Aggregate.event_type/1` and `Aggregate.event_payload/1`
    to extract from the spec map — these helpers also accept `RecordedEvent` structs
    for normal replay via `Aggregate.load/1`.

  ## Actor ↔ CommandRouter protocol

  1. Actor receives `{:command, cmd}` from caller.
  2. Actor captures `expected_version` — BEFORE `handle_command`.
  3. Actor calls `aggregate_module.handle_command(current_state, cmd)`.
  4. Actor generates a correlation `ref = make_ref()` and sends
     `{:append, aggregate_id, event_data_list, expected_version, ref, self()}` to CommandRouter.
  5. Actor waits in selective `receive` for `{:append_ok, ^ref, count}` or `{:error, ^ref, reason}`.
     Using `^ref` ensures only the matching reply satisfies the receive;
     stale/foreign replies remain queued and are handled later.
  6. CommandRouter appends events and replies with the same `ref`.
  7. Actor applies confirmed events and:
     - On success: bumps version by 1, returns `{:reply, {:ok, event_spec}, new_state}`
     - On conflict/error: version unchanged, returns `{:reply, {:error, reason}, old_state}`
  """

  alias ForemanServer.{Aggregate, CommandRouter, TaskProvider, Telemetry}
  alias EventStore.EventData
  alias ForemanServer.EventStore

  use GenServer

  # -------------------------------------------------------------------------
  # Client
  # -------------------------------------------------------------------------

  @spec start_link(module, aggregate_id :: String.t()) :: GenServer.on_start()
  def start_link(aggregate_module, aggregate_id) do
    GenServer.start_link(__MODULE__, {aggregate_module, aggregate_id}, name: via(aggregate_id))
  end

  @doc "Return the aggregate module's current in-memory state."
  @spec get_state(pid) :: any()
  def get_state(pid), do: GenServer.call(pid, :get_state)

  @doc "Registry key for an aggregate actor."
  def via(aggregate_id) do
    {:via, Registry, {ForemanServer.AggregateRegistry, aggregate_id}}
  end

  # -------------------------------------------------------------------------
  # Callbacks
  # -------------------------------------------------------------------------

  @impl true
  def init({aggregate_module, aggregate_id}) do
    # Aggregate may implement load/1; if not, use the default Aggregate.load/2
    # (replays stream_forward through apply_event).
    {module_state, version} =
      if function_exported?(aggregate_module, :load, 1) do
        aggregate_module.load(aggregate_id)
      else
        Aggregate.load(aggregate_module, aggregate_id)
      end

    Telemetry.aggregate_rehydrated(version)

    Phoenix.PubSub.broadcast(
      ForemanServer.PubSub,
      "debug:aggregates",
      {:actor_loaded, aggregate_id}
    )

    track_presence(aggregate_id, aggregate_module, version)

    state = %{
      aggregate_module: aggregate_module,
      aggregate_id: aggregate_id,
      module_state: module_state,
      version: version,
      # CLOSE-ONLY-ONCE guarantee: the cache is consulted before any
      # `BeadsAdapter.complete/3` call; once cleared, no subsequent close
      # is issued for the same logical `command_id`. The cache is
      # process-local and does NOT survive a crash (AC-024-3) — rehydration
      # starts with an empty map and the orphan janitor absorbs stragglers.
      in_flight_beads: %{}
    }

    {:ok, state}
  end

  defp track_presence(aggregate_id, aggregate_module, version) do
    ForemanServerWeb.Presence.track(self(), "debug:aggregates", aggregate_id, %{
      aggregate_id: aggregate_id,
      module: inspect(aggregate_module),
      version: version
    })
  end

  defp update_presence(aggregate_id, aggregate_module, version) do
    ForemanServerWeb.Presence.update(self(), "debug:aggregates", aggregate_id, fn _meta ->
      %{
        aggregate_id: aggregate_id,
        module: inspect(aggregate_module),
        version: version
      }
    end)
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state.module_state, state}
  end

  # Bounded retries on stream-version conflict (TRD-008 AC-005-3).
  # On :wrong_expected_version the actor reloads state + version from the
  # event store, re-decides the command against the fresh state, and retries
  # the append with the new version. The deterministic event_id propagates
  # through every retry, so any partial-success → conflict → retry sequence
  # collapses to exactly-once in the event store.
  @max_conflict_retries 3

  @impl true
  def handle_call({:command, cmd}, _from, state) do
    aggregate_id = state.aggregate_id
    event_id = event_id_for(aggregate_id, cmd)

    # Only commands with a deterministic event_id can be idempotent.
    # Commands without one bypass the lookup entirely so a transient read
    # error can never reject a valid non-idempotent command, and we avoid
    # scanning long streams for nothing.
    case event_id do
      nil ->
        do_dispatch(state, cmd, state.version, @max_conflict_retries)

      binary when is_binary(binary) ->
        case find_event_by_id(aggregate_id, event_id) do
          {:ok, event_spec} ->
            {:reply, {:ok, event_spec}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}

          :not_found ->
            do_dispatch(state, cmd, state.version, @max_conflict_retries)
        end
    end
  end

  # Dispatch loop with bounded conflict recovery.
  #
  # Stage 1 — `aggregate_module.handle_command/2` produces the
  # stage-1 event_spec from current state.
  #
  # Stage 2/3 — `resolve_enriched_event_spec/3` runs the per-project
  # synchronous hook (gated to TaskCreated events on projects with a
  # configured :create provider): it calls `provider.create/2` and
  # re-decides with the resulting `bead_id` populated as
  # `payload.external_id`. The `state` returned by the resolver carries
  # the in-flight cache so transient stream-version conflicts preserve
  # the bead handle (TRD-008 compensation path).
  #
  # Stage 4 — `append_and_commit/7` does the existing normalize /
  # append / ack / retry / commit dance. `do_commit/4` clears the
  defp do_dispatch(state, cmd, expected_version, retries_left) do
    aggregate_id = state.aggregate_id
    event_id = event_id_for(aggregate_id, cmd)

    case state.aggregate_module.handle_command(state.module_state, cmd) do
      {:ok, nil} ->
        {:reply, {:ok, nil}, state}

      {:ok, stage1_event_spec} when is_map(stage1_event_spec) ->
        case resolve_enriched_event_spec(state, cmd, stage1_event_spec, retries_left) do
          {:ok, event_spec, state_with_cache} ->
            append_and_commit(
              state_with_cache,
              aggregate_id,
              event_id,
              event_spec,
              expected_version,
              retries_left,
              cmd
            )

          {:error, reason, state_with_cache} ->
            {:reply, {:error, reason}, state_with_cache}
        end

      {:error, _reason} = error when retries_left < @max_conflict_retries ->
        # AC-020-3 post-reload outer rejection (e.g. :phase_terminal).
        # The rehydrated state rejected the original command before
        # enrichment ran — compensate the bead cached from the prior
        # attempt's stage 2 success and propagate the error to caller.
        compensate_and_reply(state, cmd, error, "foreman-compensation:re-decision-rejected")

      {:error, _reason} = error ->
        {:reply, error, state}

      {:error, _reason, _details} = error when retries_left < @max_conflict_retries ->
        compensate_and_reply(state, cmd, error, "foreman-compensation:re-decision-rejected")

      {:error, _reason, _details} = error ->
        {:reply, error, state}
    end
  end

  # TRD-008 AC-020-3 post-reload compensation helper. Calls
  # `compensate_for_conflict/3` and returns a `{:reply, error, state}`
  # tuple — preserving the existing `do_dispatch` contract.
  defp compensate_and_reply(state, cmd, error, transition_comment) do
    new_state = compensate_for_conflict(state, cmd, transition_comment)
    {:reply, error, new_state}
  end

  # -------------------------------------------------------------------------
  # TRD-007 synchronous hook: per-project bead creation
  # -------------------------------------------------------------------------
  #
  # Gate fires ONLY for stage-1 `event_type == "TaskCreated"` events on
  # commands carrying a `project_id` payload field. Other command types
  # (project, run, phase, etc.) and stage-1 events that aren't
  # TaskCreated go straight to the legacy no-op branch with the
  # stage-1 event_spec unchanged.
  #
  # Returns one of:
  #   `{:ok, event_spec, state}` — fully resolved. `state` carries the
  #     in-flight cache (populated when stage 2 succeeded).
  #   `{:error, reason, state}` — stage 2 failed OR stage 3 re-decision
  #     rejected. When stage 2 succeeded but stage 3 failed, `state`
  #     carries the cached bead_id so TRD-008 compensation can `br
  #     close` it. When stage 2 failed, `state` is unchanged (no cache
  defp resolve_enriched_event_spec(state, cmd, stage1_event_spec, retries_left) do
    cond do
      not task_create_event?(stage1_event_spec) ->
        {:ok, stage1_event_spec, state}

      external_id = Aggregate.get(cmd.payload || %{}, :external_id) ->
        emit_watcher_import_skip_telemetry(cmd, external_id)
        {:ok, stage1_event_spec, state}

      provider_tracked?(cmd.payload || %{}) == false ->
        # An ad-hoc task (`provider_tracked: false` on `task.create`)
        # carries no tracker record by design — see the
        # "unify-work-dispatch" plan's "Decisions already fixed" section:
        # it must create no Beads/tracker issue. Route straight to the
        # legacy no-op branch, same as "no provider registered".
        {:ok, stage1_event_spec, state}

      project_id = Aggregate.get(cmd.payload || %{}, :project_id) ->
        route_and_enrich(state, cmd, project_id, stage1_event_spec, retries_left)

      true ->
        {:ok, stage1_event_spec, state}
    end
  end

  defp provider_tracked?(payload) do
    case Aggregate.get(payload, :provider_tracked, true) do
      false -> false
      _ -> true
    end
  end

  defp task_create_event?(%{event_type: "TaskCreated"}), do: true
  defp task_create_event?(_), do: false

  # Per-project gate via the routing boundary, not `project_config/1`.
  # PRD AC-020-1: the gate must call `Registry.route(:create,
  # %{project_id: id})` to resolve the provider polymorphically.
  # `project_config/1` is internal to `BeadsAdapter.create/2` for DB
  # config and is not the gate.
  defp route_and_enrich(state, cmd, project_id, stage1_event_spec, retries_left) do
    case TaskProvider.Registry.route(:create, %{project_id: project_id}) do
      {:ok, provider} ->
        enrich_via_provider(state, cmd, provider, stage1_event_spec, retries_left)

      {:error, _reason} ->
        # AC-020-4: no provider registered for this project, or the
        # provider's capability set does not include :create. Legacy
        # no-op branch — stage-1 event_spec proceeds unchanged.
        {:ok, stage1_event_spec, state}
    end
  end

  # Cache hit: the same command_id has already populated the cache
  # (previous attempt succeeded at stage 2 but failed later). Skip
  # stage 2 and re-run handle_command with the cached bead_id so the
  # event spec carries `payload.external_id`.
  #
  # Stage-2 success path: call provider.create, populate cache, then
  # fall through to `enrich_with_cached_bead_id/4` with the new
  # bead_id to run stage 3.
  defp enrich_via_provider(state, cmd, provider, stage1_event_spec, retries_left) do
    case Map.get(state.in_flight_beads, cmd.command_id) do
      nil ->
        stage2_then_stage3(state, cmd, provider, stage1_event_spec)

      cached_bead_id ->
        Telemetry.execute(
          [:foreman_server, :aggregate, :in_flight_beads, :reused],
          %{},
          %{
            command_id: cmd.command_id,
            aggregate_id: state.aggregate_id,
            bead_id: cached_bead_id
          }
        )

        enrich_with_cached_bead_id(state, cmd, cached_bead_id, retries_left)
    end
  end

  # Stage 2: invoke `provider.create/2`. On success, populate
  # `state.in_flight_beads[cmd.command_id] = bead_id` and proceed to
  # stage 3 (re-decide with bead_id in payload.external_id).
  #
  # On stage-2 failure, return `{:error, reason, state}` WITHOUT
  # populating the cache — there is no bead to compensate for.
  defp stage2_then_stage3(state, cmd, provider, _stage1_event_spec) do
    payload = cmd.payload || %{}
    project_id = Aggregate.get(payload, :project_id)

    attrs = %{
      task_id: Aggregate.get(payload, :task_id),
      command_id: cmd.command_id,
      title: Aggregate.get(payload, :title),
      description: Aggregate.get(payload, :description),
      priority: Aggregate.get(payload, :priority),
      task_type: Aggregate.get(payload, :task_type),
      dedupe_key: Aggregate.get(payload, :dedupe_key)
    }

    case provider.create(project_id, attrs) do
      {:ok, %{id: bead_id}} when is_binary(bead_id) ->
        new_state = %{
          state
          | in_flight_beads: Map.put(state.in_flight_beads, cmd.command_id, bead_id)
        }

        Telemetry.execute(
          [:foreman_server, :aggregate, :in_flight_beads, :populated],
          %{},
          %{command_id: cmd.command_id, aggregate_id: state.aggregate_id, bead_id: bead_id}
        )

        enrich_with_cached_bead_id(new_state, cmd, bead_id, @max_conflict_retries)

      {:error, reason} ->
        # AC-020-5: emit the actor-level failure telemetry BEFORE
        # returning the error tuple. The adapter's internal
        # `[:beads_adapter, :create, :error]` event is a separate
        # concern — the actor must surface its own event so
        # observers can correlate a TaskCreated failure with the
        # specific command/task/project triplet.
        emit_create_failure_telemetry(cmd, reason, payload)
        {:error, reason, state}
    end
  end

  # Stage 3: re-run `aggregate_module.handle_command/2` with the
  # `bead_id` pre-populated as `payload.external_id`. The aggregate
  # mirrors this field into the event_spec payload (AC-020-6) so the
  # persisted TaskCreated event carries the bead linkage.
  defp enrich_with_cached_bead_id(state, cmd, bead_id, retries_left) do
    payload = cmd.payload || %{}
    enriched_payload = Map.put(payload, :external_id, bead_id)
    enriched_cmd = %{cmd | payload: enriched_payload}

    case state.aggregate_module.handle_command(state.module_state, enriched_cmd) do
      {:ok, enriched_event_spec} when is_map(enriched_event_spec) ->
        {:ok, enriched_event_spec, state}

      {:error, reason} when retries_left < @max_conflict_retries ->
        # AC-020-3 inner post-reload rejection: a stream-version conflict
        # already triggered `reload_after_conflict/1`, and the rehydrated
        # aggregate rejected the enriched command. The bead cache survives
        # only to enable this compensation — close it and propagate.
        new_state =
          compensate_for_conflict(state, cmd, "foreman-compensation:re-decision-rejected")

        {:error, reason, new_state}

      {:error, reason} ->
        # Initial stage 3 rejection (not yet post-reload). Cache is kept
        # so Trigger 1 (bounded-retry exhaustion in `append_and_commit/7`)
        # can close the orphaned bead if a stream-version conflict follows.
        {:error, reason, state}
    end
  end

  # AC-020-5: actor-level failure telemetry for the per-project
  # synchronous hook. The metadata fields are exactly the PRD
  # contract: `command_id`, `code`, `retryable?`, `task_id`,
  # `project_id`. Generic (non-ProviderError) reasons fall back to
  # `{nil, false}` so the event still fires with useful metadata.
  defp emit_create_failure_telemetry(cmd, reason, payload) do
    {code, retryable?} = extract_failure_code_and_retryable(reason)

    Telemetry.execute(
      [:foreman_server, :task_provider, :beads, :create, :failure],
      %{},
      %{
        command_id: cmd.command_id,
        code: code,
        retryable?: retryable?,
        task_id: Aggregate.get(payload, :task_id),
        project_id: Aggregate.get(payload, :project_id)
      }
    )
  end

  defp extract_failure_code_and_retryable(%{code: code, retryable?: retryable?})
       when is_atom(code) or is_binary(code),
       do: {code, !!retryable?}

  defp extract_failure_code_and_retryable(%{code: code}) when is_atom(code) or is_binary(code),
    do: {code, false}

  defp extract_failure_code_and_retryable(_), do: {nil, false}

  # Watcher-import branch telemetry: command reached the actor with a
  # pre-populated `external_id` (the watcher already created the bead
  # before dispatching the command). We skip br create and use the
  # stage-1 event_spec as-is.
  defp emit_watcher_import_skip_telemetry(cmd, bead_id) do
    payload = cmd.payload || %{}

    Telemetry.execute(
      [:foreman_server, :task_provider, :beads, :create, :skipped_watcher_import],
      %{},
      %{
        command_id: cmd.command_id,
        bead_id: bead_id,
        task_id: Aggregate.get(payload, :task_id),
        project_id: Aggregate.get(payload, :project_id)
      }
    )
  end

  # Stage 4: the existing normalize / append / ack / retry / commit
  # dance, extracted from `do_dispatch/4` so the synchronous hook can
  # run between stage 1 and stage 4.
  defp append_and_commit(
         state,
         aggregate_id,
         event_id,
         event_spec,
         expected_version,
         retries_left,
         cmd
       ) do
    event_data = normalize_to_event_data(event_spec, event_id)
    ref = make_ref()

    send(
      CommandRouter,
      {:append, aggregate_id, [event_data], expected_version, ref, self()}
    )

    receive do
      {:append_ok, ^ref, _event_count, append_latency_ms} ->
        do_commit(state, event_spec, append_latency_ms, cmd)

      {:append_ok, ^ref, _event_count} ->
        do_commit(state, event_spec, 0, cmd)

      {:error, ^ref, :duplicate_event, append_latency_ms}
      when not is_nil(event_id) ->
        handle_duplicate_event(state, aggregate_id, event_id, append_latency_ms)

      {:error, ^ref, :duplicate_event} when not is_nil(event_id) ->
        handle_duplicate_event(state, aggregate_id, event_id, 0)

      {:error, ^ref, :wrong_expected_version, append_latency_ms}
      when retries_left > 0 ->
        case reload_after_conflict(state) do
          {:ok, %{state: rehydrated, version: new_version}} ->
            do_dispatch(rehydrated, cmd, new_version, retries_left - 1)

          {:error, reason} ->
            {:reply, {:telemetry, {:error, reason}, %{append_latency_ms: append_latency_ms}},
             state}
        end

      {:error, ^ref, :wrong_expected_version, append_latency_ms} ->
        # AC-020-3 Trigger 1 — bounded-retry exhaustion. After three
        # stream-version conflicts the actor gives up; close the
        # orphaned Beads bead via subprocess I/O and surface the error.
        compensated_state =
          compensate_for_conflict(
            state,
            cmd,
            "foreman-compensation:append-conflict-retry-exhausted"
          )

        {:reply,
         {:telemetry, {:error, {:wrong_expected_version, state.version}},
          %{append_latency_ms: append_latency_ms}}, compensated_state}

      {:error, ^ref, :wrong_expected_version} ->
        compensated_state =
          compensate_for_conflict(
            state,
            cmd,
            "foreman-compensation:append-conflict-retry-exhausted"
          )

        {:reply,
         {:telemetry, {:error, {:wrong_expected_version, state.version}},
          %{append_latency_ms: 0}}, compensated_state}

      {:error, ^ref, reason, append_latency_ms} ->
        {:reply, {:telemetry, {:error, reason}, %{append_latency_ms: append_latency_ms}}, state}

      {:error, ^ref, reason} ->
        {:reply, {:telemetry, {:error, reason}, %{append_latency_ms: 0}}, state}
    end
  end

  # Compute deterministic event_id for a command. nil when no command_id.
  defp event_id_for(aggregate_id, cmd) do
    case cmd do
      %{command_id: command_id} when is_binary(command_id) ->
        derive_event_id(aggregate_id, command_id)

      _ ->
        nil
    end
  end

  # Apply confirmed event to actor state, bump version, and clear the
  # in-flight cache entry on terminal success (AC-024-2). The cache is
  # only cleared when the actor reaches the terminal-success branch of
  # the append/ack protocol — transient `:wrong_expected_version`
  # retries preserve the cache so TRD-008 compensation can `br close`
  # the bead if retries are exhausted.
  defp do_commit(state, event_spec, append_latency_ms, cmd) do
    new_module_state = state.aggregate_module.apply_event(state.module_state, event_spec)
    new_version = state.version + 1
    update_presence(state.aggregate_id, state.aggregate_module, new_version)

    cleared_state = clear_cache_on_success(state, cmd)

    {:reply,
     {:telemetry, {:ok, to_string_keys(event_spec)}, %{append_latency_ms: append_latency_ms}},
     %{cleared_state | module_state: new_module_state, version: new_version}}
  end

  # Drop the cache entry for `cmd.command_id`. Only runs on terminal
  # success; transient retries and stage-2 successes (without
  # commit) never call this. `cmd.command_id` is the cache key by
  # construction (see `stage2_then_stage3/4`).
  defp clear_cache_on_success(state, cmd) do
    case cmd do
      %{command_id: command_id} when is_binary(command_id) ->
        %{state | in_flight_beads: Map.delete(state.in_flight_beads, command_id)}

      _ ->
        state
    end
  end

  # TRD-008 AC-020-3 compensation helper.
  #
  # Called on bounded-retry exhaustion (`append_and_commit/7` retries_left
  # == 0 branch) and on post-reload re-decision rejection (Trigger 2 in
  # `do_dispatch/4` outer branches and `enrich_with_cached_bead_id/4`
  # inner post-reload branch). Looks up `state.in_flight_beads[command_id]`,
  # resolves the project's Beads database path via
  # `TaskProvider.Registry.project_config/1`, calls
  # `BeadsAdapter.complete/3` with a map-shaped `completion_token` carrying
  # the canonical `transition_comment`, and emits telemetry.
  #
  # CLOSE-ONLY-ONCE: if the cache has no entry for `command_id` the
  # function returns the unchanged state (no close issued, no telemetry).
  # This guards against double-close if REQ-023's orphan janitor runs
  # concurrently. After a successful close (or even on subprocess
  # failure) the cache entry is cleared so the next attempt sees a
  # clean slate.
  defp compensate_for_conflict(state, cmd, transition_comment) do
    command_id = Map.get(cmd, :command_id)
    payload = Map.get(cmd, :payload, %{})
    project_id = Aggregate.get(payload, :project_id)

    case Map.get(state.in_flight_beads, command_id) do
      nil ->
        # CLOSE-ONLY-ONCE: nothing to close, or already compensated by
        # a prior invocation. Also covers commands that never went through
        # stage-2 enrichment (e.g. phase.complete): no :command_id, so the
        # error propagates unchanged.
        state

      bead_id when is_binary(project_id) ->
        result = run_beads_complete(project_id, bead_id, transition_comment)
        emit_compensation_telemetry(state, command_id, bead_id, transition_comment, result)
        %{state | in_flight_beads: Map.delete(state.in_flight_beads, command_id)}

      _bead_id ->
        # No project_id to resolve a database path — nothing safe to do.
        # Clear the cache entry so a subsequent retry doesn't loop on a
        # stub bead handle.
        %{state | in_flight_beads: Map.delete(state.in_flight_beads, command_id)}
    end
  end

  defp run_beads_complete(project_id, bead_id, transition_comment) do
    case TaskProvider.Registry.project_config(project_id) do
      {:ok, %{config: %{database_path: db_path}}}
      when is_binary(db_path) and db_path != "" ->
        ForemanServer.TaskProviders.BeadsAdapter.complete(
          bead_id,
          %{transition_comment: transition_comment},
          %{database_path: db_path}
        )

      _ ->
        {:error, :missing_project_config}
    end
  end

  defp emit_compensation_telemetry(state, command_id, bead_id, reason, {:ok, _issue}) do
    Telemetry.execute(
      [:foreman_server, :task_provider, :beads, :create, :compensated],
      %{},
      %{
        command_id: command_id,
        aggregate_id: state.aggregate_id,
        bead_id: bead_id,
        reason: reason
      }
    )
  end

  defp emit_compensation_telemetry(state, command_id, bead_id, reason, {:error, reason_inspect}) do
    Telemetry.execute(
      [:foreman_server, :task_provider, :beads, :create, :compensate_failure],
      %{},
      %{
        command_id: command_id,
        aggregate_id: state.aggregate_id,
        bead_id: bead_id,
        reason: reason,
        close_error: inspect(reason_inspect)
      }
    )
  end

  # Re-read state + version from the event store after a stream-version conflict.
  defp reload_after_conflict(state) do
    {module_state, version} =
      if function_exported?(state.aggregate_module, :load, 1) do
        state.aggregate_module.load(state.aggregate_id)
      else
        ForemanServer.Aggregate.load(state.aggregate_module, state.aggregate_id)
      end

    rehydrated = %{state | module_state: module_state, version: version}

    # Keep Presence consistent with the actor's actual state. Without this,
    # observability would stay at the pre-conflict version even though the
    # in-memory state has moved forward — so dashboards and debug queries
    # would lie about the actor's true position in the stream.
    update_presence(rehydrated.aggregate_id, rehydrated.aggregate_module, version)

    {:ok, %{state: rehydrated, version: version}}
  rescue
    e -> {:error, {:reload_failed, e}}
  end

  # -------------------------------------------------------------------------
  # Internal
  # -------------------------------------------------------------------------

  # Convert event_spec map to %EventData{} for append.
  # When event_id is provided (commands with command_id), it is set on the
  # %EventData{} so EventStore uses it as the persisted event_id — enabling
  # database-level deduplication via the events_pkey unique constraint.
  defp normalize_to_event_data(
         %{stream_id: _stream_id, event_type: event_type, payload: payload},
         event_id
       ) do
    %EventData{event_id: event_id, event_type: event_type, data: payload}
  end

  # Typed event struct — convert to EventData for storage (used by aggregates
  # like RunSlots that return typed event structs from handle_command).
  defp normalize_to_event_data(%_{} = struct, event_id) do
    module = struct.__struct__

    # Derive event_type from module name:
    #   ForemanServer.Events.RunSlotAcquired → "RunSlotAcquired"
    event_type =
      module
      |> Module.split()
      |> List.last()

    payload = to_string_keys(struct)
    %EventData{event_id: event_id, event_type: event_type, data: payload}
  end

  # -------------------------------------------------------------------------
  # Helpers: event_spec format conversion for caller-facing returns
  # -------------------------------------------------------------------------

  # Recursively convert atom-keyed maps to string-keyed maps (for event_spec).
  defp to_string_keys(%{__struct__: _} = struct) do
    struct
    |> Map.from_struct()
    |> to_string_keys()
  end

  defp to_string_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {k, v}, acc when is_atom(k) ->
        Map.put(acc, Atom.to_string(k), to_string_keys(v))

      {k, v}, acc when is_binary(k) ->
        Map.put(acc, k, to_string_keys(v))
    end)
  end

  defp to_string_keys(other), do: other
  # Convert a stored %RecordedEvent{} to an event_spec map with string keys.
  # Used for returning existing events on duplicate idempotent hits.
  #
  # `recorded.data` is the raw Elixir term that was passed to
  # `TermOrJsonSerializer.serialize/1` at append time. Because that
  # serializer uses `:erlang.term_to_binary/1`, atom keys survive the
  # round-trip into Postgres and come back as atoms. Apply
  # `to_string_keys/1` so the duplicate-dispatch path returns the same
  # shape as the fresh-dispatch path (`do_commit/4` returns
  # `to_string_keys(event_spec)`), keeping the idempotent contract
  # symmetric with the original.
  defp recorded_event_to_event_spec(recorded) do
    %{
      "stream_id" => recorded.stream_uuid,
      "event_type" => recorded.event_type,
      "payload" => to_string_keys(recorded.data)
    }
  end

  # -------------------------------------------------------------------------
  # AC2: Deterministic event_id and idempotency
  # -------------------------------------------------------------------------

  # Derive a deterministic event_id from {aggregate_id, command_id}.
  # Uses SHA-256 to produce a valid 32-hex-char UUID string.
  # The same {aggregate_id, command_id} always produces the same event_id.
  defp derive_event_id(aggregate_id, command_id) do
    # NUL-delimited input guarantees that distinct (aggregate_id, command_id)
    # pairs cannot collide through concatenation. For example,
    # `{"ab", "c"}` and `{"a", "bc"}` produce different SHA-256 digests.
    <<first16::binary-size(16), _::binary>> =
      :crypto.hash(:sha256, aggregate_id <> "\0" <> command_id)

    <<b0::8, b1::8, b2::8, b3::8, b4::8, b5::8, b6::8, b7::8, b8::8, b9::8, b10::8, b11::8,
      b12::8, b13::8, b14::8,
      b15::8>> =
      first16

    b6 = bor(band(b6, 0x0F), 0x40)
    b8 = bor(band(b8, 0x3F), 0x80)

    Elixir.EventStore.UUID.binary_to_string!(
      <<b0::8, b1::8, b2::8, b3::8, b4::8, b5::8, b6::8, b7::8, b8::8, b9::8, b10::8, b11::8,
        b12::8, b13::8, b14::8, b15::8>>
    )
  end

  # Page through the stream looking for an event with the given event_id.
  # Returns `{:ok, event_spec}` when found, `:not_found` when the stream
  # has been exhausted without a match, or `{:error, reason}` if the read
  # fails (in which case the caller MUST NOT decide or append).
  @stream_page_size 100
  defp find_event_by_id(stream_id, event_id) do
    find_event_by_id(stream_id, event_id, 0)
  end

  defp find_event_by_id(stream_id, event_id, start_version) do
    case EventStore.read_stream_forward(stream_id, start_version, @stream_page_size) do
      {:ok, []} ->
        :not_found

      {:ok, events} ->
        case Enum.find(events, fn %Elixir.EventStore.RecordedEvent{event_id: id} ->
               id == event_id
             end) do
          nil -> find_event_by_id(stream_id, event_id, start_version + length(events))
          recorded -> {:ok, recorded_event_to_event_spec(recorded)}
        end

      {:error, :stream_not_found} ->
        :not_found

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Synchronous helper used by the duplicate_event receive branches.
  # Returns the original persisted event_spec when found, or
  # `{:error, reason}` otherwise. By definition of `:duplicate_event`
  # the persisted event must exist; a missing or read-error is reported
  # so the actor does not pretend a successful commit and HTTP callers
  # see the failure with the original event type/resource preserved.
  defp lookup_persisted_event_spec(aggregate_id, event_id) do
    case find_event_by_id(aggregate_id, event_id) do
      {:ok, _spec} = ok -> ok
      :not_found -> {:error, :not_found}
      {:error, _reason} = err -> err
    end
  end

  # Resolve a duplicate-event response. By definition the persisted event
  # already exists, so we look it up, reload the aggregate to the stream's
  # authoritative version, and return the original spec. The reload is
  # required because :duplicate_event proves the stream contains an
  # append this actor never confirmed or applied — leaving in-memory
  # state stale would violate event-log-as-source-of-truth and cause
  # the next command (before any future conflict) to use a wrong
  # expected_version. If the reload fails, we surface the failure
  # rather than fabricating success.
  defp handle_duplicate_event(state, aggregate_id, event_id, append_latency_ms) do
    with {:ok, persisted} <- lookup_persisted_event_spec(aggregate_id, event_id),
         {:ok, %{state: rehydrated}} <- reload_after_conflict(state) do
      {:reply, {:telemetry, {:ok, persisted}, %{append_latency_ms: append_latency_ms}},
       rehydrated}
    else
      {:error, reason} ->
        {:reply, {:telemetry, {:error, reason}, %{append_latency_ms: append_latency_ms}}, state}
    end
  end
end
