# Run slots, run logs, stall detection, SigNoz (§18–§20)

> Moved verbatim from `CLAUDE.md`. Section numbers are unchanged; `CLAUDE.md` names the file holding each `§N`, so a reference to a section that is not in this file resolves there.

## 18. Per-project run slots (per-project dispatch queues)

Run concurrency is enforced per project; there is no global run-slot queue and no machine-wide ceiling. Total concurrency is the sum of per-project limits (TRD-2026-b9e27ab5).

- **Stream key.** `run_slots:<project_id>`, built by the one function `ForemanServer.Aggregates.RunSlots.stream_id/1`; `CommandRouter.aggregate_module_for/1` routes the `run_slots:` prefix. The literal `run_slots:global` appears in no production code except `Workflow.RunSlotsMigration`, which reads it once at boot.
- **Capacity source.** The project's `max_concurrent_runs` setting, else `config :foreman_server, :max_concurrent_runs_per_project` (default 3), recorded on the event, never read during replay. Admission and rebalance read it at dispatch time through `Project.effective_run_limit/1` (`RunAdmission.project_capacity/1`, which loads the project aggregate); `RunSlots.release_command/3` instead reads `ProjectionStore.project_settings/1`, a projection that can lag a `project.update` until it is folded.
- **Release promotes only below capacity.** A release transfers to the head waiter only while `holders - 1 < capacity`; otherwise it plain-releases and the waiter stays queued, so lowering a limit below the running count never starts a run. A raised limit or `ProjectUpdated`/`ProjectReactivated` rebalances through `run_slots.promote` (`Workflow.Dispatcher`).
- **Promotion re-reads the task.** A promoted run starts only while its task is still startable; a task that was closed or failed while its run waited for a slot is skipped — the slot is released and the waiter removed, never a run for a dead task (`Workflow.Dispatcher.start_promoted_run/2`). A `blocked` task is deliberately startable (`Aggregates.Task` accepts `blocked -> open`), so its queued run starts at promotion instead of being dropped. Task status changes move only the status, never `acknowledged_run_id`, so the check happens at slot handoff rather than at approval time.
- **Migration of the legacy stream.** At boot `RunSlotsMigration.run/0` reads `run_slots:global` without appending to it: live holders are adopted by their run's project (`run_slots.acquire` `force: true`, command id `run-slots:adopt:<run_id>`, counted even above the limit; nothing running is stopped), live waiters are queued in legacy order (`enqueue_only: true`), then `run_slots.promote` fills free capacity. Command ids are deterministic, so a second pass is a no-op.
- **System-only commands.** `run_slots.acquire|release|remove_waiter|promote` stay out of every operator allowlist (`CommandGateway`), like the other slot and lease commands.
- **Retired global setting.** `config :foreman_server, :max_concurrent_runs` is ignored; `RunSlotsMigration.warn_retired_config/0` logs one warning at boot when it is still set.
- **Read side.** `GET /api/queue` requires `project_id` (422 `project_required`) and `ProjectLimits` carries `running_runs` / `waiting_runs`.

Known limits (documented, not fixed in this slice):

- **In-flight admission slot-leak window.** If dispatch fails transiently after a slot was acquired and the task stays `in_progress`, the slot is held without a live run until a reconciler (`RunLifecycleReconciler`, `BootReconciliation`) releases it; until then it counts against the project's limit.
- **AC-017-3 is unreachable.** Adopting a queued run into another project is refused by the Project aggregate (it treats the subject as active), so a waiting run never moves queues by `project.adopt`; see the TRD's Known Gaps.

## 19. Durable worker run logs and MCP run status

`foreman_run_status` is a bounded DTO built from `ProjectionStore.run/1` and
`ProjectionStore.phases_for_run/1`; do not rebuild it from logs or raw event
streams, and keep `foreman_run_get`'s full projection shape distinct. A run id
with no run projection yet falls back to `ProjectionStore.pending_run/1`: a run
waiting for a slot or deferred by an admission refusal answers `queued` or
`deferred` (with the refusal in `reason`), never NOT_FOUND. Both carry
`provider_session_id` (latest) and `provider_sessions` (ordered
`{worker_id, provider, model, provider_session_id}` list), folded from the
`WorkerSessionBound` worker event that `JidoHarnessWorker` emits before
`WorkerExited` (`nil` / `[]` when the provider reported none). They also carry
`usage` (a `ForemanServer.Usage`: input/output/cache-read/cache-write/total tokens and
`cost_usd`, each `null` when the provider did not report it), the sum of the
`UsageRecorded` worker events; cross-run rollups arrive with E14.

`current_phase` (the `PhaseStatus` DTO, `MCP.Tools.PhaseStatus`) carries the phase
entry's `run_id`, `task_id`, `input_artifacts` (`[%{index, source_phase, path,
sha256}]`), `execution_profile`, `prior_worktree_discarded` and `context`
(`PhaseContextRecorded`: the `sha256`, `bytes`, `sections`, `truncated` and
`redactions` of the standing-context text the launch delivered; its
`redaction_scope` is `project_context_sections`, so the count covers those
sections only). The run DTO carries `recovery`, the latest `RunRecoveryAttempted`
record. All are `null` when nothing was recorded. See §13.2.

`foreman_run_get_logs` is backed by `ProjectionStore`, not console `Logger`
output or ad hoc files. Production worker output must enter the system only as
`WorkerProtocol.emit(:worker_stdout | :worker_stderr, ...)` events on
`worker:<run_id>:<worker_id>` streams. The projection returns empty success for
known runs with no captured output and `:run_not_found` for unknown runs; never
substitute `{:ok, []}` for an unknown run. There is deliberately no
store-unavailable failure — the projection is the `ProjectionStore` GenServer's
own state, so for a known run the read cannot fail, and declaring failures that
cannot occur misdescribes the contract. Redact and control-character-normalize
output before event persistence.

`foreman_inbox_get` reads the per-run operator inbox projection; `foreman_inbox_send` is the write-gated MCP progress-note tool. It dispatches public `inbox.send` through `CommandGateway` only when `allow_workflow_writes: true`, requires `run_id` plus a 1-2,000 character body, permits only safe metadata keys (`phase_id`, `worker_id`, `session_id`, `severity`), and must not carry secrets, prompts, large logs, or command output. Inbox progress complements logs/events/activity; it does not replace them. `foreman_task_add_comment` is the sibling write-gated MCP Work Log tool: it takes `run_id`, `workflow_name`, `phase_name`, and `description`, resolves the provider task server-side, writes through `TaskProvider.comment/3`, and must not accept raw provider ids/bodies. Bundled prompts tell agents to continue work if progress or Work Log tools are denied or unavailable. Built-in `prd`/`fix` command phases receive the same guidance via worker `system_prompt`; slash-command prompt bytes stay unchanged.

**stdout and stderr arrive on different `Jido.Harness` events, and this is the
one thing to check when a channel comes back empty.** stdout text rides
`:output_text_delta` / `:output_text_final` / `:command_output_delta` with a
string-keyed `%{"text" => _}` payload. stderr does NOT: the harness turns
`ProcessEvent{type: :stderr}` into `Event{type: :provider_event}` carrying
`%{"stream" => "stderr", "data" => _}` (`adapters/cli_stream.ex:37-38`,
`session/transports/pi_rpc.ex:138-140`). Selecting only the three text types and
then looking for a `"stream"` key on them — which is never there — made
`WorkerStderr` unreachable while every layer above still advertised
stdout/stderr capture. `jido_harness_worker_log_capture_test.exs` pins both
shapes against the dep source so an upgrade cannot silently re-empty the
channel.

**Retention is bounded on two axes, and both are load-bearing.** Entry count
(5,000/run) does not bound memory, because a log line has no intrinsic size
limit and a run may have many workers; bytes (1 MiB/run) does. This is a bound
on the resident READ MODEL and is distinct from `WorkerLogPolicy`'s bound on how
many events are durably WRITTEN — different resources, not a duplicated
boundary. Every eviction is accounted in `omitted_entries` / `omitted_bytes`, so
a truncated read can never present itself as complete.

## Phase stall detection

`stall_detection` is explicit phase metadata, never inferred from phase names. Normalize it through `ForemanServer.Workflow.StallPolicy`; valid scopes are agent/no-output and messaging/no-progress. `RunExecutor` copies normalized policy onto `phase.start`/`PhaseStarted`, `ProjectionStore.stall_candidates/1` is the bounded detector read, and `ForemanServer.StallDetector` persists stalls through `run.report_stall` only. Do not write projection state directly from the detector. Worker heartbeats do not advance phase output activity; stdout/stderr, assistant messages, tool completions, worker start/exit, and phase lifecycle do.

## 20. SigNoz operational-log bridge

`ForemanServer.Observability.OtelLogBridge` installs an additional Erlang
`:logger` handler (never replaces the default console handler) that exports
redacted operational logs to SigNoz over OTLP/HTTP. It is deliberately
separate from the Langfuse LLM-trace path (`jido_otel`/`opentelemetry_exporter`,
§7 above) — different destination, different payload shape, different
on/off switch.

Config (`:foreman_server, :signoz_logs`) is parsed once, in
`packages/foreman_server/config/config.exs`, from four env vars:
`FOREMAN_SIGNOZ_LOGS_ENABLED`, `FOREMAN_SIGNOZ_OTLP_ENDPOINT`,
`FOREMAN_SIGNOZ_OTLP_HEADERS` (comma-separated `key=value` pairs), and
`FOREMAN_SIGNOZ_LOG_LEVEL`. `prod.exs` adds no override — one boundary for
every `MIX_ENV`. Malformed input (unrecognized level, malformed header
pair, or credential headers paired with a non-`https://` endpoint) raises
at config load instead of silently coercing to a default. `config/test.exs`
forces `enabled: false` regardless of the operator's shell env, so `mix
test` never installs the real exporter; tests that need the bridge call
`OtelLogBridge.install/1` directly with a `{:capture, pid}` exporter.

Two security properties are enforced at the export boundary
(`OtelLogBridge.export_to_otel/2`, not just at config-parse time, since
`install/1` is a public function callable with an arbitrary config map):
configured headers are refused for any non-`https://` endpoint (CWE-319),
and the underlying `:httpc.request/4` call sets `autoredirect: false` so a
3xx response can never replay those headers against a different or
less-secure origin.

The blocking `:httpc` POST runs off the logging client process via
`Task.Supervisor.start_child/2` against `ForemanServer.Observability.OtelLogExportSupervisor`
(started under `ForemanServer.Application`, `max_children: 50`); config/payload
validation stays synchronous so `export/2` still reports precondition errors
(missing endpoint, insecure headers, unavailable OTLP protobuf module) to its
caller immediately. A rejected `{:error, :max_children}` emits
`Telemetry.signoz_log_export_overload/1` and drops the record instead of
accumulating unbounded work.

`ForemanServer.Observability.Redactor` and `LogMetadata` are the redaction
boundary: metadata is whitelist-filtered (unknown keys dropped, not
passed through), and log bodies — including structured Erlang `:report`
terms (crash/progress reports) — are walked recursively for sensitive keys
before they are ever inspected into text, then regex-scrubbed again as a
second pass over value-shaped secrets (DB URLs, auth headers, `NAME=value`
secrets, home-directory paths).
