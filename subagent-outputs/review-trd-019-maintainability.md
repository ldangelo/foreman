## Review

- Correct:
  - Tests pass: `cd packages/foreman_server && mix test` → 56 tests, 0 failures.
  - Format ok: `mix format --check-formatted` → pass.
  - TRD/PRD target verified: REQ-016 / AC-016 requires sentinel/Jira/GitHub ingestion + idempotency (`docs/PRD/...014...md:417-428`, `docs/TRD/...014...md:651-663`).
  - Core module covers direct ingestion: `IntegrationIngestion.ingest/1` normalizes, dedupes, appends event, creates task (`packages/foreman_server/lib/foreman_server/integration_ingestion.ex:8-24`).
  - Tests cover sentinel threshold, Jira/GitHub task creation, duplicate no-op, durable rebuild (`packages/foreman_server/test/integration_ingestion_test.exs:30-120`).

- Fixed:
  - None. Review-only. No edits.

- Blocker:
  - API contract gap. TRD defines `ExternalTriggerCommand` contract (`docs/TRD/TRD-2026-014-elixir-backend-orchestration.md:245-257`), but HTTP router has no ingestion route and `/api/v1/commands` only calls generic `CommandRouter.handle/1` (`packages/foreman_server/lib/foreman_server/http/router.ex:143-169`). `CommandRouter` has no `ExternalTriggerCommand` case; unknown commands become `CommandAccepted` only (`packages/foreman_server/lib/foreman_server/command_router.ex:111-120`). So external integrations cannot exercise the documented server command/API path to create/dedupe tasks. Tests call the module directly, so they miss this.

- Fix now:
  - Add explicit HTTP/API command path for integration ingestion, or map `ExternalTriggerCommand` in `CommandRouter` to `IntegrationIngestion.ingest/1`.
  - Add router tests for authorized request, invalid input, duplicate request, and unsupported source.
  - Make ingestion atomic/idempotent across both events. Current flow appends `IntegrationCommandIngested` before `task.create` (`integration_ingestion.ex:14-15`), and duplicate detection later trusts projection state (`integration_ingestion.ex:63-67`). Crash/error between those steps can leave dedupe recorded without a task.

- Optional:
  - Harden external input types: `occurred_at` and nested `payload` are accepted as-is (`integration_ingestion.ex:50-51`). Validate ISO timestamp/map shape and cap string sizes before future HTTP exposure.
  - Avoid `String.to_atom/1` on JSON payload/metadata in command router (`command_router.ex:148-151`), esp. because HTTP JSON reaches it (`router.ex:143-146`). Use existing atoms or string-key handling.
  - Improve GitHub fallback dedupe. Current fallback dedupes all same `site/external_id/event_type` events (`integration_ingestion.ex:161-163`), which can suppress distinct GitHub events of same type unless caller supplies explicit idempotency key.

- Commands:
  - `cd packages/foreman_server && mix test test/integration_ingestion_test.exs` → 4 tests, 0 failures.
  - `cd packages/foreman_server && mix test` → 56 tests, 0 failures.
  - `cd packages/foreman_server && mix format --check-formatted` → pass.
  - `git status --short` → clean.

Note: Did not write `/subagent-outputs/review-trd-019-maintainability.md`; prompt said no edits.