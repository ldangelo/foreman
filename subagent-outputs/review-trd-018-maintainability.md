## Review

REJECTED.

- Correct:
  - Git status clean. No current diff.
  - TRD/PRD refs found:
    - `docs/PRD/PRD-2026-014-elixir-backend-orchestration.md:404-415`
    - `docs/TRD/TRD-2026-014-elixir-backend-orchestration.md:632-647`
  - Inbox projection basics exist:
    - `InboxMessageAppended` / `InboxDeliveryUpdated` projection in `packages/foreman_server/lib/foreman_server/projection_store.ex:460-487`
    - Registry-backed watch notification in `projection_store.ex:578-584`
    - app supervision starts duplicate-key registry in `application.ex:10-18`
  - Tests pass:
    - `cd packages/foreman_server && mix test test/inbox_test.exs` → 4 tests, 0 failures
    - `cd packages/foreman_server && mix test` → 46 tests, 0 failures
    - `mix format --check-formatted` → passed

- Fixed:
  - None. Review-only. No edits.

- Blocker:
  - AC-015-1 not wired into production phase paths.
    - Requirement: phase starts/completes/fails + configured mail hooks append inbox events. See PRD `docs/PRD/PRD-2026-014-elixir-backend-orchestration.md:413`.
    - `WorkflowInterpreter` stores hooks at `workflow_interpreter.ex:38`, but `start_run/3` passes only `phase_order` + retries to `RunActor` at `workflow_interpreter.ex:46-53`.
    - `execute_phase/3` appends `PhaseCompleted` / `PhaseFailed` at `workflow_interpreter.ex:59-105`, with no `Inbox.append_phase_mail/3`.
    - `RunActor` appends `PhaseStarted`, `PhaseCompleted`, `PhaseFailed` at `run_actor.ex:105-147` and `run_actor.ex:212-220`, with no inbox hook call.
    - `rg append_phase_mail packages/foreman_server` shows only `inbox.ex` and direct unit test usage (`test/inbox_test.exs:28`).
    - Result: direct Inbox API works, but configured phase hooks do not fire from actual phase transitions.

- Blocker:
  - Inbox boundary atomizes arbitrary input keys.
    - `Inbox.send_operator_message/1`, `update_delivery/1`, and hook handling call `atomize_keys` at `inbox.ex:34-45` and `inbox.ex:68-69`.
    - `atomize_keys` recursively calls `String.to_atom/1` on all string keys at `inbox.ex:198-206`.
    - Future HTTP/CLI JSON payloads can create unbounded atoms. VM risk. Contract risk.
    - Fix: use whitelisted key normalization or dual string/atom fetch helpers. Do not recursively atomize arbitrary `delivery`, hook, or body maps.

- Note:
  - Partial side effects possible in multi-hook append.
    - `append_hook_messages/3` appends each message inside `Enum.map`, then checks for errors after at `inbox.ex:84-108`.
    - If a later append fails idempotency (`event_store.ex:108-118`), earlier inbox events remain while function returns error.
    - This conflicts with TRD invalid-input/no-side-effect expectation at `docs/TRD/TRD-2026-014-elixir-backend-orchestration.md:636-639`.
    - Fix now: prevalidate configs/message IDs before append.

- Note:
  - `Inbox.list/1` takes multiple snapshots (`inbox.ex:23-28`). Simpler/safer: bind one snapshot and read from it.

- Note:
  - Did not write `/subagent-outputs/review-trd-018-maintainability.md`. Task also said “Do not edit”; no-edit wins for artifact writes.

- Commands run:
  - `git status --short && git diff --stat && git diff --name-only`
  - `git show --stat --oneline 37ce7698`
  - `git show --stat --oneline 0e926e09`
  - `rg -n "append_phase_mail" packages/foreman_server`
  - `cd packages/foreman_server && mix test test/inbox_test.exs`
  - `cd packages/foreman_server && mix format --check-formatted`
  - `cd packages/foreman_server && mix test`