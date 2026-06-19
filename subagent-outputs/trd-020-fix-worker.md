Implemented TRD-020 review fixes only.

Changed files:
- packages/foreman_server/README.md
- packages/foreman_server/lib/foreman_server/debug_views.ex
- packages/foreman_server/lib/foreman_server/http/router.ex
- packages/foreman_server/lib/foreman_server/worker_protocol.ex
- packages/foreman_server/test/debug_views_test.exs
- packages/foreman_server/test/http_router_test.exs

Commit:
- 3125f93d fix: harden Elixir debug views

Validation:
- `cd packages/foreman_server && mix format && mix test && mix compile --warnings-as-errors && cd ../.. && npx tsc --noEmit && node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md ...` exit 0.
- Mix: 71 tests, 0 failures.
- Compile warnings-as-errors: pass.
- TypeScript: pass.
- TRD parser: 52 tasks, warnings [].

Diff summary:
- Added DebugViews recursive sanitization for compact/raw/report/debug data: common secret keys and inline secret patterns are redacted, large strings are truncated.
- Made `/api/v1/runs/:run_id/logs` reject invalid `view` values with 400 while preserving compact default and `view=raw`.
- Preserved worker `assistant_message.message` in durable event payloads so compact logs render non-blank message-only assistant events.
- Strengthened tests for redaction/truncation, raw metadata redaction, assistant `message`, HTTP auth/raw/compact/invalid-view/report/debug endpoints, and post-purge restart/replay durability.
- Updated package README with authenticated endpoint paths and redaction/truncation contract.

Residual risks:
- Existing untracked review artifact predates this run: `subagent-outputs/review-trd-020-maintainability.md`.
- This run writes `subagent-outputs/trd-020-fix-worker.md` as requested; it remains untracked.
