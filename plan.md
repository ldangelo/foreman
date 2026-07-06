# Implementation Plan

## Goal
Migrate the broken local-store tests and remaining local-store production paths to real PostgresStore/PostgresAdapter coverage using Testcontainers, without restoring sqlite or adding test-only fakes.

## Tasks
1. **Confirm and freeze the target direction**: Do not restore sqlite/better-sqlite3 and do not make `ForemanStore` functional again.
   - File: `src/lib/store.ts`
   - Changes: Keep this as type/interface compatibility only, or replace usages so runtime no longer depends on its no-op DB behavior.
   - Acceptance: No `better-sqlite3` dependency in `package.json`; no tests require `ForemanStore` to persist rows.

2. **Harden the Postgres Testcontainers harness**: Make the existing helper reusable by all migrated tests.
   - File: `src/test-support/postgres-testcontainer.ts`
   - Changes: Add helpers to create an isolated project per test, truncate project-scoped tables between tests, and expose `{ adapter, store, project }` using `PostgresAdapter` + `PostgresStore`.
   - Acceptance: Helper starts `postgres:16-alpine`, runs `npm run db:migrate`, initializes `PoolManager`, and can create/read a project via `PostgresAdapter`.

3. **Add missing PostgresStore compatibility methods used by existing tests/commands**: Fill current no-op gaps that were hidden by local `ForemanStore` tests.
   - File: `src/lib/postgres-store.ts`
   - Changes: Implement real Postgres-backed versions of methods currently stubbed or incomplete, starting with `getCosts`, `getCostBreakdown`, `getPhaseMetrics`, `getSuccessRate`, `getPendingBeadWrites`, `markBeadWriteProcessed`, merge strategy/config accessors, and any method directly used by failing tests.
   - File: `src/lib/db/postgres-adapter.ts`
   - Changes: Add focused query methods where `PostgresStore` cannot reuse existing adapter methods cleanly, e.g. list costs by project/run, list/dequeue bead-write queue entries, merge strategy config CRUD.
   - Acceptance: New/updated PostgresStore integration tests verify persisted rows, not in-memory objects or mocks.

4. **Create a production Postgres task-store wrapper for NativeTaskStore coverage**: Replace sync local `NativeTaskStore` test dependency with async Postgres behavior.
   - File: `src/lib/postgres-task-store.ts` (or extend `PostgresAdapter` if smaller)
   - Changes: Provide async equivalents for `create`, `approve`, `ready`, `list`, `get`, `claim`, `update`, `close`, `resetToReady`, dependency add/list/remove, cycle detection, blocked-task reevaluation.
   - File: `src/lib/db/postgres-adapter.ts`
   - Changes: Reuse existing task/dependency methods; add missing status-transition semantics and typed errors matching `TaskNotFoundError`, `InvalidStatusTransitionError`, `CircularDependencyError` where production expects them.
   - Acceptance: Native task lifecycle tests pass against Testcontainers and exercise Postgres tables `tasks` + `task_dependencies`.

5. **Rewrite `task-store` tests to Postgres**: Convert the largest failure group first.
   - File: `src/lib/__tests__/task-store.test.ts`
   - Changes: Replace `new ForemanStore(...).getDb()` setup with Testcontainers project fixture and async Postgres task wrapper/adapter calls; mark tests `async`; keep assertions/behavior the same where Postgres semantics should match.
   - Acceptance: `npx vitest run src/lib/__tests__/task-store.test.ts --reporter=dot` passes.
   - Reason for test changes: The old tests instantiate a local sync store that production no longer supports; they must target the production Postgres task path.

6. **Rewrite `store` surface tests to PostgresStore**: Convert general store tests from `ForemanStore` to `PostgresStore`.
   - File: `src/lib/__tests__/store.test.ts`
   - Changes: Use Testcontainers fixture; replace sync calls with `await`; remove file-path sqlite assertions (`.foreman/foreman.db` exists, two sqlite handles share data) and replace with production Postgres assertions (same `project_id` store instances share persisted data).
   - Acceptance: `npx vitest run src/lib/__tests__/store.test.ts --reporter=dot` passes.
   - Reason for test changes: File-backed local DB behavior is intentionally removed and no longer represents production.

7. **Rewrite store-adjacent library tests to PostgresStore**: Convert smaller failing store groups after Tasks 3 and 6.
   - Files: `src/lib/__tests__/mail.test.ts`, `src/lib/__tests__/bead-write-queue.test.ts`, `src/lib/__tests__/store-metrics.test.ts`, `src/lib/__tests__/merge-strategy-store.test.ts`, `src/lib/__tests__/native-task-client.test.ts`
   - Changes: Use Testcontainers fixture and production Postgres classes; update only setup/awaiting and expectations that asserted local sqlite/file behavior.
   - Acceptance: Each file passes individually with `npx vitest run <file> --reporter=dot`.
   - Reason for test changes: These tests currently validate local `ForemanStore` persistence or no-op-broken behavior, not the production Postgres path.

8. **Fix registered-project Postgres initialization in CLI commands**: Ensure commands initialize `PoolManager` before creating task clients/stores/adapters.
   - Files: `src/cli/commands/reset.ts`, `src/cli/commands/retry.ts`, `src/cli/commands/stop.ts`, `src/cli/commands/attach.ts`, `src/cli/commands/inbox.ts`, `src/cli/commands/purge-logs.ts`, `src/cli/commands/purge-zombie-runs.ts`, `src/cli/commands/task.ts`, `src/cli/commands/doctor.ts`
   - Changes: Call `ensureCliPostgresPool(projectPath)` immediately after resolving a registered project and before any `createTaskClient`, `PostgresStore.forProject`, `PostgresAdapter`, or `ProjectRegistry({ pg })` use.
   - Acceptance: `foreman reset --bead foreman-b91dc --project foreman --dry-run` no longer throws `PoolManager not initialised`; command tests no longer fail for Postgres init order.

9. **Rewrite CLI tests that task local ForemanStore state**: Migrate command fixtures to registered Postgres project fixtures.
   - Files: `src/cli/__tests__/task.test.ts`, `src/cli/__tests__/attach.test.ts`, `src/cli/__tests__/attach-follow.test.ts`, `src/cli/__tests__/retry.test.ts`, `src/cli/__tests__/stop.test.ts`, `src/cli/__tests__/inbox.test.ts`, `src/cli/__tests__/purge-logs.test.ts`, `src/cli/__tests__/purge-zombie-runs.test.ts`, `src/cli/__tests__/doctor.test.ts`, `src/cli/__tests__/doctor-native-mode.test.ts`, `src/cli/__tests__/task-project-resolution.test.ts`, `src/cli/commands/__tests__/task-project-resolution.test.ts`
   - Changes: Replace temp `ForemanStore` setup with Testcontainers registered project setup or explicit mocks at process-boundary tests; use real `PostgresStore` for state assertions.
   - Acceptance: Each listed file passes individually; no test asserts `.foreman/foreman.db` or unregistered local persistence.
   - Reason for test changes: CLI production path for this repo is registered Postgres; local sync DB setup is obsolete.

10. **Rewrite orchestrator tests that require DB persistence**: Convert only tests that instantiate `ForemanStore.forProject` or `NativeTaskStore`; leave pure mocked store unit tests alone.
   - Files: `src/orchestrator/__tests__/bead-writer-drain.test.ts`, `src/orchestrator/__tests__/task-backend-ops-enqueue.test.ts`, `src/orchestrator/__tests__/doctor.test.ts`, `src/orchestrator/__tests__/doctor-native-task-store.test.ts`, `src/orchestrator/__tests__/task-backend-ops.test.ts`, `src/orchestrator/__tests__/worker-spawn.test.ts`, `src/orchestrator/__tests__/dispatcher-native-integration.test.ts`
   - Changes: Use Testcontainers project fixture and `PostgresStore`/`PostgresAdapter`; update dispatcher/test helpers to accept `IStore`/Postgres-compatible interfaces instead of concrete `ForemanStore` where needed.
   - Acceptance: Listed files pass individually; bead writer tests verify rows in Postgres `bead_write_queue`.
   - Reason for test changes: These tests currently task/query a disabled local DB, causing null/undefined failures.

11. **Retire or quarantine obsolete local-store-only assertions**: Remove tests whose only purpose was sqlite/local file behavior, not Foreman behavior.
   - Files: `src/lib/__tests__/store.test.ts`, `src/orchestrator/__tests__/doctor.test.ts`, any test section mentioning `.foreman/foreman.db`, readonly sqlite handles, local/global sqlite migration, or sqlite lock/contention.
   - Changes: Delete or replace those assertions with Postgres registry/project behavior checks.
   - Acceptance: No tests fail solely because a local DB file is absent.
   - Reason for test changes: These assertions conflict with the explicit Postgres-only requirement.

12. **Clean production local fallback paths**: Remove remaining code that silently falls back to no-op `ForemanStore` for commands expected to be Postgres-only.
   - Files: `src/cli/commands/project-task-support.ts`, `src/lib/task-client-factory.ts`, `src/lib/native-task-client.ts`, command files listed in Task 8.
   - Changes: For production registered-project mode, always use `PostgresStore`/`PostgresAdapter`; for unregistered mode, either fail fast with a clear `foreman init`/project registration message or use beads-only paths that do not touch `ForemanStore` persistence.
   - Acceptance: Grep shows no command uses `ForemanStore` for registered projects; unregistered command behavior is explicit and tested.

13. **Run targeted validation in dependency order**: Validate smallest batches before full suite.
   - File: none
   - Changes: Run these commands after implementation:
     - `npx vitest run src/lib/__tests__/task-store.test.ts --reporter=dot`
     - `npx vitest run src/lib/__tests__/store.test.ts --reporter=dot`
     - `npx vitest run src/lib/__tests__/mail.test.ts src/lib/__tests__/bead-write-queue.test.ts src/lib/__tests__/store-metrics.test.ts src/lib/__tests__/merge-strategy-store.test.ts --reporter=dot`
     - `npx vitest run src/cli/__tests__/task.test.ts src/cli/__tests__/retry.test.ts src/cli/__tests__/stop.test.ts --reporter=dot`
     - `npx vitest run src/orchestrator/__tests__/bead-writer-drain.test.ts src/orchestrator/__tests__/task-backend-ops-enqueue.test.ts --reporter=dot`
   - Acceptance: Failures decrease from 25 files / 312 tests to 0 in the converted groups.

14. **Run final validation**: Verify build and full test suite.
   - File: none
   - Changes: Run `npx tsc --noEmit`, `npm run build`, and `npm test -- --reporter=dot`.
   - Acceptance: Build/typecheck pass; all tests pass or only unrelated pre-existing non-store failures remain with documented evidence.

## Files to Modify
- `src/test-support/postgres-testcontainer.ts` - make the real Postgres test fixture reusable for project/store setup and cleanup.
- `src/lib/postgres-store.ts` - implement missing real store methods currently stubbed/no-op.
- `src/lib/db/postgres-adapter.ts` - add focused Postgres queries for costs, metrics, bead-write queue, merge strategy/config, and task lifecycle gaps.
- `src/lib/postgres-task-store.ts` - production-capable async native task wrapper, if keeping task-store semantics clearer than expanding adapter directly.
- `src/lib/__tests__/task-store.test.ts` - migrate from local sync NativeTaskStore to Postgres task path.
- `src/lib/__tests__/store.test.ts` - migrate from ForemanStore/local file tests to PostgresStore tests.
- `src/lib/__tests__/mail.test.ts` - migrate mail persistence tests to PostgresStore/PostgresMailClient.
- `src/lib/__tests__/bead-write-queue.test.ts` - migrate bead write queue tests to Postgres rows.
- `src/lib/__tests__/store-metrics.test.ts` - migrate metric aggregation tests to PostgresStore/Adapter.
- `src/lib/__tests__/merge-strategy-store.test.ts` - migrate merge strategy config tests to Postgres implementation.
- `src/lib/__tests__/native-task-client.test.ts` - ensure registered-project NativeTaskClient tests use real Postgres adapter where integration-level.
- `src/cli/commands/reset.ts` - initialize Postgres pool before registered task client/store use.
- `src/cli/commands/retry.ts` - same init-order and registered-store cleanup.
- `src/cli/commands/stop.ts` - same init-order and registered-store cleanup.
- `src/cli/commands/attach.ts` - same init-order and registered-store cleanup.
- `src/cli/commands/inbox.ts` - same init-order and registered-store cleanup.
- `src/cli/commands/purge-logs.ts` - same init-order and registered-store cleanup.
- `src/cli/commands/purge-zombie-runs.ts` - same init-order and registered-store cleanup.
- `src/cli/commands/task.ts` - same init-order and registered-store cleanup.
- `src/cli/commands/doctor.ts` - same init-order and registered-store cleanup.
- `src/cli/__tests__/task.test.ts` - migrate local DB setup to registered Postgres fixture.
- `src/cli/__tests__/attach.test.ts` - migrate local DB setup to registered Postgres fixture.
- `src/cli/__tests__/attach-follow.test.ts` - migrate local DB setup to registered Postgres fixture.
- `src/cli/__tests__/retry.test.ts` - migrate local DB setup to registered Postgres fixture.
- `src/cli/__tests__/stop.test.ts` - migrate local DB setup to registered Postgres fixture.
- `src/cli/__tests__/inbox.test.ts` - migrate local DB setup to registered Postgres fixture.
- `src/cli/__tests__/purge-logs.test.ts` - migrate local DB setup to registered Postgres fixture.
- `src/cli/__tests__/purge-zombie-runs.test.ts` - migrate local DB setup to registered Postgres fixture.
- `src/cli/__tests__/doctor.test.ts` - replace local/global sqlite doctor scenarios with Postgres scenarios or remove obsolete assertions.
- `src/cli/__tests__/doctor-native-mode.test.ts` - migrate native task setup to Postgres.
- `src/cli/__tests__/task-project-resolution.test.ts` - adjust project resolution fixtures to registered Postgres path.
- `src/cli/commands/__tests__/task-project-resolution.test.ts` - same as above.
- `src/orchestrator/__tests__/bead-writer-drain.test.ts` - migrate queue setup/assertions to Postgres.
- `src/orchestrator/__tests__/task-backend-ops-enqueue.test.ts` - migrate queue setup/assertions to Postgres.
- `src/orchestrator/__tests__/doctor.test.ts` - replace local sqlite store scenarios with Postgres equivalents or remove obsolete sections.
- `src/orchestrator/__tests__/doctor-native-task-store.test.ts` - migrate native task setup to Postgres.
- `src/orchestrator/__tests__/task-backend-ops.test.ts` - migrate DB-backed portions to Postgres.
- `src/orchestrator/__tests__/worker-spawn.test.ts` - migrate DB setup to PostgresStore.
- `src/orchestrator/__tests__/dispatcher-native-integration.test.ts` - update misleading in-memory/local setup to Testcontainers Postgres.
- `package.json` - keep `testcontainers` and `@testcontainers/postgresql` as dev dependencies.
- `package-lock.json` - lock Testcontainers dev dependencies.

## New Files
- `src/test-support/postgres-testcontainer.ts` - shared Testcontainers Postgres fixture and cleanup utilities.
- `src/lib/postgres-task-store.ts` - optional production async native task-store wrapper if adapter-only changes become too large.
- `src/lib/__tests__/postgres-store-testcontainer.integration.test.ts` - production PostgresStore/PostgresAdapter smoke/integration coverage.

## Dependencies
- Task 2 depends on Testcontainers dev dependencies already being present in `package.json`/`package-lock.json`.
- Tasks 5-10 depend on Task 2 fixture helpers.
- Tasks 5 and 7 depend on Task 3 missing `PostgresStore` methods.
- Task 5 depends on Task 4 if a separate `PostgresTaskStore` wrapper is chosen.
- Task 9 depends on Task 8 command init-order fixes.
- Task 12 should happen after Tasks 8-10 expose which local fallback paths are still needed.
- Task 14 depends on all migrated test groups passing individually.

## Risks
- Testcontainers requires Docker; CI/local environments must have Docker available or these tests need a documented skip path for non-Docker lanes.
- Converting many sync tests to async is mechanical but broad; risk is accidental behavior changes in assertions. Keep each file conversion isolated and run it immediately.
- `PostgresStore` currently has several stubbed methods; tests may reveal real production gaps beyond the known 312 failures.
- Some old tests assert sqlite-specific behavior (`.foreman/foreman.db`, readonly sqlite handle, local/global DB migration). Those must be removed/replaced, not preserved.
- A synchronous wrapper around Postgres would be a hidden fake/anti-pattern; avoid it even if it appears to minimize test edits.
- Do not use sqlite as a temporary restore. It would make tests pass against non-production storage and violate the stated Postgres-only requirement.
- If unregistered/local beads mode must remain supported, clarify its expected storage behavior; otherwise fail fast instead of silently using no-op `ForemanStore`.
