Review-only honored. Did not write `subagent-outputs/review2-trd-023-tests.md` because prompt also says “Do not edit.”

## Review

- Correct:
  - Atomic validation is now before side effects: `MigrationImporter.import/1` validates before `execute_import/3` appends events. `packages/foreman_server/lib/foreman_server/migration_importer.ex:14-21`, `303-329`.
  - No-side-effect tests cover invalid direct import and malformed later records, then successful retry. `packages/foreman_server/test/migration_importer_test.exs:86-107`.
  - Completed retry idempotency covered: no duplicate events on same migration id. `migration_importer_test.exs:109-118`; impl checks completed import at `migration_importer.ex:19-21`, `460-472`.
  - Invalid record/status/duplicate coverage exists. `migration_importer_test.exs:121-149`; validators at `migration_importer.ex:341-356`, `411-432`.
  - CLI import server dispatch covered: `foreman import --to-elixir --file` sends `migration.import` w/ payload + metadata. `src/cli/__tests__/import-server.test.ts:63-81`; impl at `src/cli/commands/import.ts:58-84`.
  - Legacy coexistence covers PRD command list + enable/complete gating + spawn delegation + missing bin + unsupported command. `src/cli/__tests__/legacy-coexistence.test.ts:26-82`; impl at `src/cli/legacy-coexistence.ts:4-80`.
  - Legacy AC list matches TRD/PRD: `docs/TRD/TRD-2026-014-elixir-backend-orchestration.md:1012-1014`, `docs/PRD/PRD-2026-014-elixir-backend-orchestration.md:478-480`.

- Fixed:
  - None applied. Review-only.

- Blocker:
  - None.

- Fixes worth doing now:
  - Add table cases for duplicate `tasks`, `workflows`, `inbox_messages`, plus invalid `config`. Code validates them, but tests only duplicate projects/runs and invalid project/status. Evidence: code `migration_importer.ex:320-328`, `359-363`; tests `migration_importer_test.exs:121-149`.
  - Add one invalid HTTP/CommandRouter no-side-effect test. Current boundary test is success-only. TRD asks command/API invalid path fails before side effects. Evidence: TRD `docs/TRD/...:730-731`; current HTTP success `migration_importer_test.exs:182-203`.

- Optional:
  - Add CLI negative tests for `--no-auto-start`, server not running, non-ok server response, and default command id. Current CLI test covers happy dispatch only. `src/cli/__tests__/import-server.test.ts:63-81`.
  - Add process-level legacy delegation smoke through CLI entrypoint. Current tests cover pure helper behavior.

- Note:
  - `progress.md` missing (`ENOENT`). `plan.md` appears unrelated/stale Postgres/local-store plan, so review anchored to TRD/PRD + actual TRD-023 files.

- Commands:
  - `cd packages/foreman_server && mix test test/migration_importer_test.exs` → pass, 8 tests.
  - `npx vitest run src/cli/__tests__/import-server.test.ts src/cli/__tests__/legacy-coexistence.test.ts --reporter=dot` → pass, 2 files / 6 tests.
  - `cd packages/foreman_server && mix test` → pass, 101 tests.
  - `npx tsc --noEmit` → pass.
  - `git status --short` → clean.