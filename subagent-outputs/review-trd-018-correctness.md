## Review
REJECTED. No edits. Did not write output file due `no edits` vs artifact-write conflict.

### Correct
- Git clean. No current diff.
- `ForemanServer.InboxRegistry` supervised: `packages/foreman_server/lib/foreman_server/application.ex:12`.
- Inbox appends durable events via `EventStore.append`: `inbox.ex:134-143`, `151-160`.
- Active-run validation exists for operator messages: `inbox.ex:47-49`, `166-178`.
- Direct inbox tests pass: `packages/foreman_server/test/inbox_test.exs`.
- Full Elixir package tests pass: 46 tests, 0 failures.

### Blocker
- AC-015-1 not actually wired to phase lifecycle.
  - Req: phase starts/completes/fails + mail hooks configured → messages appended/projected: `docs/PRD/PRD-2026-014-elixir-backend-orchestration.md:413`.
  - Workflow stores mail hooks: `workflow_interpreter.ex:38`.
  - But `start_run/3` only passes `phase_order` + retry config to `RunActor`: `workflow_interpreter.ex:47-53`.
  - `RunActor` appends `PhaseStarted`/`PhaseCompleted` without calling `Inbox.append_phase_mail`: `run_actor.ex:78-85`, `102-108`, `212-224`.
  - `grep` shows `append_phase_mail` only used in `inbox.ex` and tests.
  - Repro command showed inbox stays empty after starting workflow w/ `mail.phase_started`.

- Projection rebuild has watcher side effects.
  - `ProjectionStore.rebuild/1` replays via `reduce_event`: `projection_store.ex:68-70`.
  - Inbox projection calls `notify_inbox_watchers` during reduce: `projection_store.ex:460-465`, `473-482`.
  - This re-sends historical inbox messages to active watchers during rebuild, violating AC-015-3 “new messages arrive” streaming: `docs/PRD/PRD-2026-014-elixir-backend-orchestration.md:415`.
  - Repro command received old `{:inbox_update, ...}` after `EventStore.rebuild_projections/0`.

### Fix worth doing now
- Make rebuild pure. Suppress watcher notifications during rebuild or split apply modes: live apply notifies; replay/rebuild does not.
- Wire mail hooks into actual phase event producers. Likely carry `mail_hooks`/phase config into `RunActor` or centralize post-append hook handling.
- Add tests:
  - workflow/run actor with configured `phase_started`, `phase_completed`, `phase_failed` mail hooks.
  - active watcher + rebuild should not receive replayed historical updates.
  - terminal run rejects operator message.

### Notes
- `Inbox.list/1` calls `ProjectionStore.snapshot()` once for ids and again per message: `inbox.ex:23-28`. Use one snapshot to avoid inconsistent reads.
- `progress.md` absent (`ENOENT`).

### Commands run
- `git status --short && git diff --stat && git diff --name-only` → clean.
- `git show --stat ... 37ce7698 0e926e09 97c268ea` → inspected changed files.
- `grep TRD-018/REQ-015/AC-015` → inspected refs.
- `cd packages/foreman_server && mix test test/inbox_test.exs` → pass, 4 tests.
- `cd packages/foreman_server && mix test` → pass, 46 tests.
- Ad hoc workflow mail-hook smoke → inbox `[]`, confirms no phase-hook wiring.
- Ad hoc rebuild watcher smoke → received old `:inbox_update`, confirms rebuild side effect.