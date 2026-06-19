## Review

- Correct:
  - Repo clean. No current diff after `017b999d`; HEAD `05b7f309` only adds subagent output files.
  - AC-015 refs confirmed: `docs/PRD/PRD-2026-014-elixir-backend-orchestration.md:413-415`.
  - AC-015-2 covered: operator msg queued/delivered in `packages/foreman_server/test/inbox_test.exs:78-99`.
  - AC-015-3 covered incl no replay on rebuild: `inbox_test.exs:102-137`; impl gates watcher notify to live mode in `projection_store.ex:678-681`.
  - Restart/replay covered for inbox msg + delivery status: `inbox_test.exs:140-161`.
  - Missing/inactive run failure covered before inbox side effects: `inbox_test.exs:164-177`.

- Blocker:
  - AC-015-1 not proven for real workflow mail config.
  - Defaults/docs use `mail.onStart/onComplete/onFail`: `src/defaults/workflows/default.yaml:36-39`.
  - Parser normalizes those to `:on_start/:on_complete`: `workflow_interpreter.ex:233-237`.
  - Inbox only recognizes `phase_started/phase_completed/phase_failed`: `inbox.ex:6-10`, `inbox.ex:134-142`.
  - Tests bypass real YAML shape by injecting fixture keys `phase_started/phase_completed/phase_failed`: `inbox_test.exs:28-32`, fixture `inbox-mail-hooks.json:4-8`.
  - Result: tests prove synthetic hook shape, not production/default configured mail hooks required by AC-015-1.

- Fix worth doing now:
  - Add test using `WorkflowInterpreter.load_yaml/1` or default workflow-shaped mail:
    - `mail: onStart: true`, `onComplete: true`, `onFail: developer`
    - start/pass/fail real `RunActor`
    - assert inbox messages appear.
  - Then normalize workflow mail config to inbox hook config, or update documented/default config if phase_* is intended.

- Note:
  - `progress.md` absent.
  - Did not write `subagent-outputs/review2-trd-018-tests.md`; explicit no-edit instruction wins over artifact-write request.
  - Optional: add assertions that `EventStore.stream("inbox:<run>")` contains `InboxMessageAppended`/`InboxDeliveryUpdated` for lifecycle path.

Commands run:
- `git status --short --branch && git diff --stat && git diff --name-only` → clean.
- `git show --stat --name-only 017b999d` → inspected changed files.
- `cd packages/foreman_server && mix test test/inbox_test.exs` → pass, 9 tests.
- `cd packages/foreman_server && mix test` → pass, 51 tests.
- `cd packages/foreman_server && mix compile --warnings-as-errors` → pass.
- `npx tsc --noEmit` → pass.