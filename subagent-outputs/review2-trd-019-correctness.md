## Review

- Correct:
  - Envelope-style `ExternalTriggerCommand` now routes via CommandRouter: `command_router.ex:27-32`, `148-154`.
  - HTTP `/api/v1/commands` covers wrapped external trigger tests; focused tests pass.
  - Dedupe fallback formats now match TRD for Jira/GitHub/Sentinel: `integration_ingestion.ex:183-209`.
  - Jira/GitHub require non-empty `external_link`/`url`: `integration_ingestion.ex:163-167`.
  - Dedupe-only state recovery added: `integration_ingestion.ex:77-89`, `28-40`.
  - CommandRouter atom-safety improved: no `String.to_atom`; known-key normalization only: `command_router.ex:179-228`.

- Blocker:
  - TRD-shaped `ExternalTriggerCommand` is still not accepted.
    - TRD contract shows top-level fields, no required `command_id`/`payload`: `docs/TRD/TRD-2026-014-elixir-backend-orchestration.md:245-259`.
    - HTTP requires `command_id` + `command_type`, and only passes `payload`: `http/router.ex:187-199`.
    - CommandRouter ignores top-level `source`/`external_id` for atom commands by reading only `:payload`: `command_router.ex:19-23`.
    - Verified direct TRD-shaped command returns `{:error, {:missing_or_invalid, :source}}`.

- Fix now:
  - Accept/normalize TRD 4.8 shape at HTTP + CommandRouter.
  - For `ExternalTriggerCommand`, merge top-level integration fields with `payload`, or document/update TRD if envelope-only is intended.
  - Add regression tests for top-level JSON contract.

- Optional:
  - Validate Jira/GitHub links as URLs, not just non-empty strings.
  - Consider rejecting arbitrary provided `idempotency_key` values that do not match source-specific dedupe formats.

- Commands:
  - `cd packages/foreman_server && mix test test/integration_ingestion_test.exs test/http_router_test.exs` — pass, 12 tests.
  - `cd packages/foreman_server && mix test` — pass, 61 tests.
  - `mix run` direct TRD-shaped `ExternalTriggerCommand` — returned `{:error, {:missing_or_invalid, :source}}`.
  - `git status --short` — clean.
  - `progress.md` — missing.

Note: did not write `subagent-outputs/review2-trd-019-correctness.md`; task also says “Do not edit,” so no-edit wins.