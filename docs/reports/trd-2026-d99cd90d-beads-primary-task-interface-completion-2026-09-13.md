# Completion Verification Report

- TRD file: `docs/TRD/TRD-2026-d99cd90d-beads-primary-task-interface.md`
- TRD slug: `trd-2026-d99cd90d-beads-primary-task-interface`
- Date: 2026-09-13
- Tracking mode: beads (root epic `foreman-31jm`)

## Task Inventory

| ID | Description | Status | Evidence |
|---|---|---|---|
| TRD-001 | Manifest-declared `task_types` field parsing | closed | `foreman-alko` — commit `22eb66edd` |
| TRD-001-TEST | Test collision detection + omitted-field handling | closed | `foreman-camq` — commit `aff1196d` |
| TRD-002 | `Catalog.type_to_workflow` reverse map | closed | `foreman-qeq9` — commit `8de34d4b` |
| TRD-002-TEST | Test hot-reload rebuild + fan-in | closed | `foreman-m7rd` — commit `e065409b` |
| TRD-003 | `Workflow.Catalog.Doctor` type coverage report | closed | `foreman-8d7s` — commit `c1113177` |
| TRD-003-TEST | Test doctor unmapped/full-coverage reporting | closed | `foreman-bpru` — commit `c786f945` |
| TRD-004 | Status gate on `BeadsWatcher.process_line/2` | closed | `foreman-6k5m` — commit `951302f4` |
| TRD-004-TEST | Test status gate accept/reject | closed | `foreman-jmpk` — commit `cc0430b4` |
| TRD-005 | Wire workflow selection into `BeadsWatcher` | closed | `foreman-dt49` — commit `2a43f254` |
| TRD-005-TEST | Test unmapped-type transient hold + telemetry | closed | `foreman-9nuc` — commit `711a8f3d` |
| TRD-006 | `trd_path` extraction + blocked-transition | closed | `foreman-uyt7` — commit `8bfffae1` |
| TRD-006-TEST | Test missing/present `trd_path` handling | closed | `foreman-wsvl` — commit `4e44f961` |
| TRD-007 | Auto-approval (`task.create` + `task.approve`) | closed | `foreman-6pmz` — commit `6d90dcdb` |
| TRD-007-TEST | Test create-and-approve with no operator action | closed | `foreman-cvf5` — commit `6e0695ac` |
| TRD-008 | Regression: full-replay-on-boot under new gates | closed | `foreman-wg6s` — commit `bb333a9f` |
| TRD-008-TEST | Test watcher restart replay | closed | `foreman-n7wy` — commit `b4ccf0dd` |
| TRD-009 | Coverage-drift detection at watcher boot | closed | `foreman-gr1l` — commit `844b04be` |
| TRD-009-TEST | Test refuse-to-start on drift / resume when false | closed | `foreman-p7j0` — commit `05521b0e` |
| TRD-010 | `BeadsDbLease` acquisition during boot/tail | closed | `foreman-5tal` — commit `858a1e12` |
| TRD-010-TEST | Test watcher/RunExecutor lease serialization | closed | `foreman-qwad` — commit `990ee4db` |
| TRD-011 | Filesystem watch (primary) + poll backstop | closed | `foreman-f1wd` — commit `fd20f884` |
| TRD-011-TEST | Test fs-watch trigger + poll backstop | closed | `foreman-9n25` — commit `5fda5303` |
| TRD-012 | Fine-grained telemetry buckets | closed | `foreman-h8ef` — commit `9d54d2b3` |
| TRD-013 | Fix `BeadsAdapter.fail/3` hardcoded `--status open` | closed | `foreman-tyl8` |
| TRD-013-TEST | Test `fail/3` moves bead to blocked, not open | closed | `foreman-iv3t` |
| TRD-014 | `FailureClassifier.classify/1` | closed | `foreman-2lam` |
| TRD-014-TEST | Test classification of every documented error pattern | closed | `foreman-wy1g` |
| TRD-015 | Transient retry loop (1s/5s/15s) on `RunExecutor` dispatch | closed | `foreman-u0se` |
| TRD-015-TEST | Test retry timing + escalation | closed | `foreman-7n8t` |
| TRD-016 | Verify `claim/3`/`complete/3`/`fail/3` call site wiring | closed | `foreman-dx4a` |
| TRD-016-TEST | End-to-end run lifecycle test | closed | `foreman-ge3x` |
| TRD-018 | Delete `task.*` CLI commands entirely | closed | `foreman-1jgf` — commit `0c191fca` |
| TRD-018-TEST | Verify `task.*` removal, `run.*` preserved | closed | `foreman-xu2u` — commit `09847e29` |
| TRD-019 | Restore `implement-trd`/`implement-trd-beads` manifests with `task_types` | closed | `foreman-hy1q` — commit `35f233f5` |
| TRD-019-TEST | Test manifests load and route via `Catalog.type_to_workflow` | closed | `foreman-kdm6` — commit `a5fb9324` |

35/35 task beads closed and live-verified via `br show` (Step 2 cross-check, zero test-gaps: every non-TEST task's paired TEST task is also closed). 4 PR-story beads (`foreman-ibdg` PR1, `foreman-w9us` PR2, `foreman-rylw` PR3, `foreman-eg6v` PR4) closed after independently confirming every child task in their declared scope was closed.

## Requirement Coverage Cross-Check

`docs/PRD/PRD-2026-d99cd90d-beads-primary-task-interface.md` declares REQ-001
through REQ-010 using the `# REQ-NNN: Title` heading convention (em/en-dash
separator) rather than the `**Priority:** Must|Should|Could|Won't` line
convention the completion-verification skill's automated extractor
recognizes. That automated pass resolved every REQ to `priority: null` and
treated the step as informational-only — an extractor/PRD-format mismatch,
not evidence of anything (CodeRabbit review, corrected here rather than left
standing as the reported evidence).

The PRD's own Acceptance Criteria Summary table (lines 33-44) states
priorities explicitly: REQ-001 through REQ-008 are **Must**, REQ-009 is
**Should**, REQ-010 is **Won't (this release)** and out of scope. Checked
manually against the Task Inventory above and the traceability validation
already performed in an earlier phase (`[Satisfies REQ-NNN]` annotations on
every task, zero orphaned annotations):

| REQ | Priority | Satisfying task(s) | Status |
|---|---|---|---|
| REQ-001 | Must | TRD-001, TRD-001-TEST, TRD-002, TRD-002-TEST, TRD-005, TRD-005-TEST | closed |
| REQ-002 | Must | TRD-003, TRD-003-TEST | closed |
| REQ-003 | Must | TRD-004, TRD-004-TEST, TRD-007, TRD-007-TEST, TRD-011, TRD-011-TEST, TRD-012 | closed |
| REQ-004 | Must | TRD-008, TRD-008-TEST, TRD-009, TRD-009-TEST, TRD-010, TRD-010-TEST | closed |
| REQ-005 | Must | TRD-013, TRD-013-TEST, TRD-014, TRD-014-TEST, TRD-015, TRD-015-TEST, TRD-016, TRD-016-TEST | closed |
| REQ-006 | Must | TRD-018, TRD-018-TEST | closed |
| REQ-007 | Must | TRD-006, TRD-006-TEST | closed |
| REQ-008 | Must | TRD-019, TRD-019-TEST | closed |
| REQ-009 | Should | — (no new task required; already satisfied by the existing `TaskProvider` contract, per the TRD's own traceability note) | n/a |
| REQ-010 | Won't (this release) | — (explicitly out of scope) | n/a |

Every Must requirement (REQ-001 through REQ-008) has at least one satisfying
task, and every satisfying task is closed. REQ-009 (Should) required no new
task by design — the TRD's own traceability note states it was already
satisfied by the existing `TaskProvider` contract — so its coverage evidence
is that design statement, not a closed-task list. This manual check is the
actual requirement-coverage evidence for this report; the automated
extractor's `priority: null` result above is noted for transparency but is
not being cited as the gating evidence it initially was.

## Independent Full Test-Suite Execution

Ran `mix test` from the repo root (via `devbox run`) five times across this verification pass, fixing genuine regressions between runs rather than accepting the first red result:

1. **First run**: compile failure (`ForemanServer.TaskProvider.Issue.__struct__/1` missing required keys in a Wave 2 test fixture) blocked the entire suite from compiling. Fixed.
2. **Second run**: 27 failures. Root-caused and fixed 6 independent defects (not test wording — real bugs the Wave 1/2 tracks introduced): `Catalog.resolve_workflow/3` silently dropping `task_types` from every manifest (making `type_to_workflow` permanently empty); `Doctor.format_ascii/1` discarding its computed branch via an unbound `if/else`; a direct `BeadsAdapter` alias in `Doctor` violating the TaskProviders architecture boundary; `ManifestWriter` unconditionally rejecting the new `task_types` top-level list field; and a `run_executor.ex` alias edit that silently deleted the `StepSequencer` alias fix AGENTS.md documents as previously having crashed every multi-phase run.
3. **Third through fifth runs**: progressively fixed stale test assertions that predated or were introduced alongside the above (pre-existing `beads_adapter_fail_test.exs`/`side_channel_capture_test.exs`/`run_executor_test.exs` tests still asserting the `fail/3` `"open"` status literal TRD-013 deliberately changed to `"blocked"`; `beads_supervisors_test.exs`'s mock missing TRD-009's new `:sync_status` boot call; `catalog_test.exs` asserting a bare-string `type_to_workflow` contract against the real `{:ok,_}`/`{:error,_}` tuple contract; and `task_state_transitions_test.exs` calling `claim/3`/`complete/3` instead of the real `claim/4`/`complete/4`, never seeding the real project projection `RunExecutor.resolve_provider/3` requires, asserting fabricated request shapes, and asserting telemetry events `claim`/`complete` never emit).

**Final run**: `3 properties, 2872 tests, 2 failures, 11 excluded` (2870/2872 passing).

The 2 remaining failures — `DispatcherBridgeTest` ("approval → dispatch → run.start bridge") and `RecoveryTest` ("do_detect/1 emits a run.recovery_event for stale non-terminal runs") — were independently investigated, not eliminated:

- Neither test file has any diff against `main` on this branch (`git diff $(git merge-base HEAD main) -- <file>` is empty for both).
- Both pass cleanly and reproducibly in isolation: 3/3 seeded runs (`--seed 1`, `--seed 2`, `--seed 3`) with zero failures when run together in isolation, and individually within the isolated `run_executor_test.exs`/`recovery_test.exs` files.
- They surface only under the full 36-`max_cases`-parallel suite, consistent with the pre-existing, already-documented non-determinism in `AGENTS.md` ("Elixir Test Suite Non-Determinism (2026-09-02)": shared singleton/projection state leaking across async/sync test boundaries, 38-43 failures on identical seed prior to any of this branch's work).

Per this skill's gate algorithm, a nonzero suite exit code is a GAP regardless of attribution, and the calling agent MUST NOT declare completion without an explicit user override. That override was requested and obtained: the user was presented with this exact evidence (isolation reproduction, empty diff, non-determinism precedent) via an explicit choice among "accept as pre-existing", "investigate further", or "block merge until green", and selected **"Accept as pre-existing, proceed."**

## Gap Summary

- Total gaps found: **0** attributable to this branch's implementation.
- Test-suite gap: 2 intermittent, full-suite-load-only failures in files untouched by this branch, verified pre-existing via isolation reproduction and empty git diff against `main`, NOT eliminated. Accepted via explicit user override per the completion-verification gate, not self-certified.

## VERDICT: COMPLETE (INCOMPLETE overridden by explicit user decision — see Gap Summary)
