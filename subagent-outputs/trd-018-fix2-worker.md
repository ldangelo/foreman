Implemented TRD-018 review round 2 fix only.

Changed files:
- packages/foreman_server/lib/foreman_server/inbox.ex
- packages/foreman_server/test/inbox_test.exs

Commit:
- 2760771e fix: map workflow mail hooks to inbox

Validation:
- `cd packages/foreman_server && mix format && mix test` exit 0; 52 tests, 0 failures.
- `cd packages/foreman_server && mix compile --warnings-as-errors` exit 0; compiled cleanly.
- `npx tsc --noEmit` exit 0; no output.
- `node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md` exit 0; TRD parse ok, 52 tasks, warnings [].

Diff summary:
- Added safe hook alias lookup in `ForemanServer.Inbox` so `onStart`/`on_start`, `onComplete`/`on_complete`, and `onFail`/`on_fail` map to `PhaseStarted`/`PhaseCompleted`/`PhaseFailed` inbox hooks.
- Added binary recipient normalization so default `onFail: developer` emits a failure inbox message addressed to `developer`.
- Added focused `WorkflowInterpreter.load_yaml/1` test using real workflow-shaped mail config and real `RunActor` start/pass/fail lifecycle.
- Kept no unsafe string-to-atom normalization in Inbox.

Residual risks:
- None known for this scoped fix.

Git status after commit/write:
- No staged files.
- Untracked subagent output artifacts under `subagent-outputs/`.
