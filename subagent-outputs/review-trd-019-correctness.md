## Review

- Correct:
  - Sentinel threshold path exists. Below threshold returns error; threshold met creates bug task. Evidence: `integration_ingestion.ex:174-182`, tests `test/integration_ingestion_test.exs:30-57`.
  - Jira/GitHub task projections preserve `source`, `external_id`, `external_link`, `dedupe_key`, `task_type`, `integration_event_type`. Evidence: `command_router.ex:63-76`, `projection_store.ex:189-205`.
  - Duplicate same input is idempotent in normal sequential path. Evidence: `integration_ingestion.ex:63-68`, test `test/integration_ingestion_test.exs:90-104`.
  - Rebuild covered. Evidence: `projection_store.ex:598-611`, test `test/integration_ingestion_test.exs:107-120`.
  - Tests pass.

- Blocker:
  - Documented command/API path not wired for integration ingestion.
    - TRD says integrations normalize into `ExternalTriggerCommand` and relevant command/API path must work: `docs/TRD/TRD-2026-014-elixir-backend-orchestration.md:245-259`, `657-660`.
    - `/api/v1/commands` routes only to `ForemanServer.handle_command` / `CommandRouter`: `http/router.ex:143-147`.
    - `CommandRouter` has no `ExternalTriggerCommand` case; unknown commands become `CommandAccepted` only: `command_router.ex:111-120`.
    - `IntegrationIngestion.ingest/1` is only called by tests; no HTTP/CommandRouter entrypoint found.
    - Impact: external monitors using documented server command API will not create tasks.

- Fix now:
  - Route `ExternalTriggerCommand` through `IntegrationIngestion.ingest/1` from `CommandRouter` or `/api/v1/commands`.
  - Fix fallback dedupe formats:
    - TRD requires GitHub `github:<repo>:<eventId>` and sentinel `sentinel:<project>:<fingerprint>`: `docs/...:262-266`.
    - Impl uses GitHub `repo:external_id:event_type` and generic sentinel `source:external_id:event_type`: `integration_ingestion.ex:154-168`.
    - Risk: same GitHub issue/event type or same sentinel fingerprint across projects dedupes incorrectly.

- Optional:
  - Make duplicate handling robust against concurrent same-key ingestion. Current precheck uses projection snapshot before append: `integration_ingestion.ex:63-68`; append duplicate can return error instead of no-op response.
  - Consider atomicity of two-event ingest. `IntegrationCommandIngested` appends before `TaskCreated`: `integration_ingestion.ex:14-15`, `70-107`. If second append fails, retry sees dedupe and never creates task.

- Commands:
  - `cd packages/foreman_server && mix test test/integration_ingestion_test.exs` — pass, 4 tests.
  - `cd packages/foreman_server && mix test` — pass, 56 tests.
  - `git status --short` — clean.
  - `progress.md` missing.

Note: did not write `subagent-outputs/review-trd-019-correctness.md` because task also said “Do not edit”; no-edit wins for artifact write conflict.