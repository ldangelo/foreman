Implemented TRD-018 review round 1 fixes.

Changed files:
- packages/foreman_server/lib/foreman_server/inbox.ex
- packages/foreman_server/lib/foreman_server/projection_store.ex
- packages/foreman_server/lib/foreman_server/run_actor.ex
- packages/foreman_server/lib/foreman_server/workflow_interpreter.ex
- packages/foreman_server/test/inbox_test.exs

Commit:
- 017b999d fix: wire Elixir inbox phase hooks

Validation:
- `cd packages/foreman_server && mix format && mix test test/inbox_test.exs` exit 0; 9 tests, 0 failures.
- `cd packages/foreman_server && mix format && mix test && mix compile --warnings-as-errors && cd ../.. && npx tsc --noEmit && node /Users/ldangelo/Development/Fortium/ensemble/packages/development/lib/trd-cli.js parse docs/TRD/TRD-2026-014-elixir-backend-orchestration.md ...` exit 0; 51 tests, 0 failures; compile warnings-as-errors pass; TypeScript pass; TRD parse 52 tasks, warnings [].

Diff summary:
- Wired workflow mail hooks into `RunActor` start/pass/fail lifecycle and `WorkflowInterpreter.execute_phase/3` completed/failed phase events.
- Made inbox projection rebuild/replay pure by passing live/replay mode through `ProjectionStore`; watcher Registry notifications only happen for live appends.
- Removed recursive `String.to_atom` normalization from `Inbox`; replaced external input handling with string/atom whitelisted fetch helpers and fixed `Inbox.list/1` to use one snapshot.
- Added focused inbox tests covering real lifecycle hook firing, failed phase hook firing, rebuild notification suppression, restart replay persistence, terminal run rejection, and invalid duplicate-hook no partial append.

Surprises:
- Existing review output file remained untracked before this run: `subagent-outputs/review-trd-018-maintainability.md`.

Residual risks:
- None known for requested TRD-018 fixes.

Git status after commit/write:
- No staged files.
- Untracked output artifacts under `subagent-outputs/`.
