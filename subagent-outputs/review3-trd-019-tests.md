## Review
APPROVED.

- Correct:
  - AC-016-1 covered. Sentinel below/at threshold creates bug task. Evidence: `integration_ingestion_test.exs:30-62`; impl `integration_ingestion.ex:216-224`, `:173`.
  - AC-016-2 covered. Jira/GitHub create tasks w/ links + dedupe keys. Evidence: `integration_ingestion_test.exs:64-92`; impl `integration_ingestion.ex:163-209`.
  - AC-016-3 covered. Duplicate direct ingest preserves event/task counts and no runs. Evidence: `integration_ingestion_test.exs:167-182`; impl `integration_ingestion.ex:77-90`, `:42-43`.
  - API contract covered for top-level + envelope `ExternalTriggerCommand`. Evidence: `command_router.ex:9-16`, `:28-36`, `:161-167`; HTTP accepts top-level shape `http/router.ex:187-190`; tests `integration_ingestion_test.exs:95-165`, `http_router_test.exs:60-126`.
  - Durable rebuild covered. Evidence: `integration_ingestion_test.exs:256-269`; projection applies integration dedupe `projection_store.ex:598-610`.

- Fixed:
  - None. Review-only. No edits.

- Blocker:
  - None found.

- Fix worth doing now:
  - None required for AC-016-1/2/3 or API contract.

- Optional:
  - Add HTTP duplicate assertions for unchanged `EventStore.all()` and task count. Current HTTP checks same `task_id` only. `http_router_test.exs:81-91`, `:115-125`.
  - Add sentinel via HTTP/`ExternalTriggerCommand` boundary. Current sentinel coverage is direct ingest. `integration_ingestion_test.exs:30-62`.
  - Add `external.trigger` alias regression if alias is public API. Impl supports it; tests only use `ExternalTriggerCommand`.

- Commands:
  - `cd packages/foreman_server && mix test test/integration_ingestion_test.exs test/http_router_test.exs` → pass, 14 tests.
  - `cd packages/foreman_server && mix test && mix compile --warnings-as-errors` → pass, 63 tests.
  - `npx tsc --noEmit` → pass.
  - `node .../trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md` → pass, warnings `[]`.
  - `git diff --check 7bc0d086^..HEAD` → pass.
  - `git status --short` → clean.
  - `progress.md` read failed: file missing.

Note: did not write `subagent-outputs/review3-trd-019-tests.md`; task also said no edits, so no-edit won.