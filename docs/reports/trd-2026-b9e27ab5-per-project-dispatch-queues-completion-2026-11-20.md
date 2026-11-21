# Completion Verification Report: trd-2026-b9e27ab5-per-project-dispatch-queues

- TRD file: docs/TRD/TRD-2026-b9e27ab5-per-project-dispatch-queues.md
- TRD slug: trd-2026-b9e27ab5-per-project-dispatch-queues
- Date: 2026-11-20
- Tracking mode: beads (kata adapter)
- Branch: dispatch-queue (HEAD 51311def)

## Task Inventory

Parser found 34 tasks; an independent grep of the TRD found 34 task-shaped lines (agree). Status below is a live `tracker.show` query, not a cached value.

| ID | Description | Bead | Status |
|----|-------------|------|--------|
| TRD-001 | Add optional `project_id` to the five `RunSlot*` event structs and optional `promoted` to  | est5 | closed |
| TRD-001-TEST | `run_slots_project_scoped_test.exs`: legacy-event decode; stream id; per-project isolation | qtm3 | closed |
| TRD-002 | Change `do_release` to transfer to the head waiter only when `map_size(holders) - 1 < capa | vr5f | closed |
| TRD-002-TEST | Release/promote cases in `run_slots_release_test.exs` (extend the existing file), plus a s | ftd5 | closed |
| TRD-003 | Add system command `run_slots.promote` (one `RunSlotAcquired{promoted: true}` for the head | t5az | closed |
| TRD-003-TEST | `run_slots_promote_test.exs` including a concurrency case (two simultaneous acquires for o | vt52 | closed |
| TRD-004 | Register the new command shapes: `Dispatch` allowlist is unchanged (system only); confirm  | y5jd | closed |
| TRD-004-TEST | Extend `command_allowlist_parity_test.exs` with the three `run_slots.*` types. | 1vt0 | closed |
| TRD-005 | `RunAdmission`: compute `capacity` from the loaded Project (`effective_run_limit/1`), targ | 9v3v | closed |
| TRD-005-TEST | Rewrite `run_admission_slot_gate_test.exs` and `run_admission_project_refusal_test.exs` fo | 2krn | closed |
| TRD-006 | Remove the ceiling from `Project`: delete `run_limit_refusal/2` and the `reject_at_run_lim | d23s | closed |
| TRD-006-TEST | Update `project_run_limit_and_stream_gap_test.exs` and `project_limits_test.exs` for the r | tj06 | closed |
| TRD-007 | `Dispatcher`: resolve the run's project for `terminate_slot/2` (run projection, falling ba | fh3f | closed |
| TRD-007-TEST | Extend `dispatcher_run_limit_readmission_test.exs` and add `dispatcher_slot_rebalance_test | jfbs | closed |
| TRD-008 | `RunLifecycleReconciler`: `dispatch_slot_release/3` takes the run's project and uses `RunS | rvkw | closed |
| TRD-008-TEST | Update `run_lifecycle_reconciler_slot_test.exs`; add a multi-repo-run-holds-one-slot case. | cxy5 | closed |
| TRD-009 | New `Workflow.RunSlotsMigration.run/0` per the Migration section; `BootReconciliation.scan | g045 | closed |
| TRD-009-TEST | `run_slots_migration_test.exs`: seed a legacy stream with holders and ordered waiters acro | yj7j | closed |
| TRD-010 | Remove the global cap: delete `RunSlots.Config.max_concurrent_runs/0`, the `:max_concurren | cs95 | closed |
| TRD-010-TEST | `run_slots_config_test.exs` (rewrite), a boot-warning test using `capture_log`, and a sour | 9e5a | closed |
| TRD-011 | `ProjectionStore`: fold `RunSlot*` events by `project_id` into `run_slots: %{project_id => | azhv | closed |
| TRD-011-TEST | Rewrite `projection_store_queue_status_test.exs` and `projection_store_run_slots_test.exs` | 5yna | closed |
| TRD-012 | `QueueController.index/2`: require `project_id`; absent or blank answers 422 `project_requ | w0z4 | closed |
| TRD-012-TEST | New `queue_controller_test.exs`; run `mcp/tool_inventory_test.exs` to confirm no combined  | n7q5 | closed |
| TRD-013 | Telemetry: add `project_id` and `waiting` to the slot events (`Telemetry.run_slots_*`: acq | h7a1 | closed |
| TRD-013-TEST | Update `telemetry_run_slots_test.exs`. | ykqy | closed |
| TRD-014 | Verification only: confirm the settings validator rejects 0, negatives and over-range (`Ag | rzjg | closed |
| TRD-014-TEST | Extend `project_settings_test.exs` and `project_settings_live_test.exs`. | npc9 | closed |
| TRD-016 | Documentation (constitution section 8, a blocking gate): `docs/user-guide.md` (the project | tjdg | closed |
| TRD-016-TEST | Documentation contract test `docs_per_project_queue_test.exs`: greps the four documents fo | mv5q | closed |
| TRD-017 | Adoption of a waiting run (split from TRD-007). `Dispatcher` handles `ProjectSubjectAdopte | verh | closed |
| TRD-017-TEST | `dispatcher_adoption_requeue_test.exs`. First step of the test: adopt a thread that has a  | dp32 | closed |
| TRD-018 | Fix the stranded-queued-run defect (kata `teak`) in the code this TRD rebuilds. (a) `BootR | 8358 | closed |
| TRD-018-TEST | `boot_reconciliation_queued_waiter_test.exs` and a case in `run_admission_slot_gate_test.e | p1gw | closed |

## Requirement Coverage

| REQ | Priority | Satisfying tasks | Status |
|-----|----------|------------------|--------|
| REQ-001 | Must | 8 task(s) | SATISFIED |
| REQ-002 | Must | 4 task(s) | SATISFIED |
| REQ-003 | Must | 6 task(s) | SATISFIED |
| REQ-004 | Won't | 0 task(s) | informational only (Won't, no task by design) |
| REQ-005 | Must | 5 task(s) | SATISFIED |
| REQ-006 | Must | 4 task(s) | SATISFIED |
| REQ-007 | Must | 9 task(s) | SATISFIED |
| REQ-008 | Must | 4 task(s) | SATISFIED |
| REQ-009 | Must | 6 task(s) | SATISFIED |
| REQ-010 | Must | 4 task(s) | SATISFIED |
| REQ-011 | Must | 2 task(s) | SATISFIED |
| REQ-012 | Should | 2 task(s) | SATISFIED |
| REQ-013 | Must | 4 task(s) | SATISFIED |
| REQ-014 | Should | 2 task(s) | SATISFIED |
| REQ-015 | Must | 2 task(s) | SATISFIED |
| REQ-016 | Must | 2 task(s) | SATISFIED |
| REQ-017 | Must | 5 task(s) | SATISFIED |
| REQ-018 | Must | 4 task(s) | SATISFIED |

## Known coverage limits (from the TRD, not gaps in this verdict)

- PRD AC-017-2 (a deleted project drops its waiting runs): no project-delete command exists, so it has no task. `RunSlots.drop_project/1` is groundwork.
- PRD AC-017-3 (adopting a thread with a queued run): the real adoption path refuses an active subject (`{:error, {:subject_active, status}}`), so the handler is tested with a synthetic event only. A PRD decision is needed.
- PRD AC-004-1 and AC-004-2: REQ-004 is a Won't; its guard test was dropped when the jobsite retirement effort began deleting those modules.

## Gap Summary

Total gaps: 0

An earlier run of this verification on the same day (HEAD 3a88dcd1) found 1 gap, TEST-SUITE-FAILURE: three tests (`PromptInboxProgressTest`, `CatalogTest`, `FullWorkflowLifecycleTest`) failed because commit dd0c239b changed the bundled `fix.yaml` to command phases, one of which ran a command that does not exist (`/enseble:merge-pr`). Commit 51311def restored `fix.yaml` to its pre-dd0c239b content and the gap closed. Task closure and requirement coverage above were re-checked against live tracker state and did not change.

## Test Suite Result

PASS -- `MIX_ENV=test mix test --warnings-as-errors` in packages/foreman_server on a dedicated database, run by the orchestrating session at HEAD 51311def with a clean working tree: 7077 passed (7068 tests, 9 of 9 properties), 10 excluded, exit 0. `npm run test --workspaces` does not apply: the repository has no root package.json.

---

**VERDICT: COMPLETE (0 gaps)**
