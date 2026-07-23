# Developer Report: Overwatch should not nudge polling phases (merge/refinery/etc)

## Approach
Implemented **Option 1 (Targeted Polling-Phase Suppression)** from the task description:
- Added `POLLING_PHASES` constant (`Set<string>`) with values `["merge", "pr-wait", "refinery"]` in both TypeScript and Elixir
- `maybeNudge()` (TypeScript) and `observe_event()` (Elixir) return early when the current phase is a polling phase
- This preserves overwatch's behavior for genuine LLM phases while suppressing spurious nudges for builtin polling phases

## Explorer Plan Followed
- Yes — implemented the preferred Option 1 as described in the task
- Extended scope to include Elixir `Overwatch` module (see Scope Expansions below)

## Files Changed
- `src/orchestrator/heartbeat-manager.ts` — Added `POLLING_PHASES` set and `isPollingPhase()` check at start of `maybeNudge()`
- `src/orchestrator/__tests__/heartbeat-manager.test.ts` — Added `does not send overwatch nudge for polling phases (merge, pr-wait, refinery)` test
- `packages/foreman_server/lib/foreman_server/overwatch.ex` — Added `@polling_phases` module attribute and early-return guard in `observe_event/2` for `WorkerHeartbeat`
- `packages/foreman_server/test/overwatch_test.exs` — Added `does not send nudges for polling phases (merge, pr-wait, refinery)` test
- `docs/user-guide.md` — Documented that polling-only phases are exempt from stale-heartbeat nudges

## Self-Check Evidence
- CodeRabbit finding addressed: both TypeScript and Elixir polling-phase tests now cover "merge", "pr-wait", and "refinery".
- `npx vitest run src/orchestrator/__tests__/heartbeat-manager.test.ts`: pass.
- `cd packages/foreman_server && mix test test/overwatch_test.exs`: 10 tests, 0 failures.
- Documentation: `docs/user-guide.md` documents the polling-phase stale-nudge exemption.

## Acceptance Contract
- **AC1: Overwatch does not send nudges for polling phases (merge, pr-wait, refinery)** — Implemented: `maybeNudge()` and `observe_event()` check `isPollingPhase()` / `@polling_phases` and return early
- **AC2: Overwatch still nudges non-polling phases with genuine stalls** — Unchanged behavior: snapshot comparison logic preserved for non-polling phases
- **AC3: Nudges are capped at overwatchMaxNudges** — Unchanged behavior: logic in `maybeNudge()` preserved
- **AC4: Tests cover polling phase suppression** — Implemented: test cases added in both test files

## Scope Expansions

### `packages/foreman_server/lib/foreman_server/overwatch.ex`
**Justification:** The Elixir `Overwatch` module is a **separate, independent overwatch system** that also sends phase nudges. It watches `WorkerHeartbeat` events from the event store (distinct from the TypeScript `HeartbeatManager`'s `fireHeartbeat()` calls). Both systems can independently send overwatch nudges to operators. Since the task addresses "Overwatch" broadly (not specifically "HeartbeatManager"), both systems require the fix to prevent spurious nudges for polling phases.

### `packages/foreman_server/test/overwatch_test.exs`
**Justification:** Required to test the Elixir overwatch fix. The existing Elixir tests didn't cover polling phase behavior, so a new test case was necessary to verify the fix works correctly in the Elixir system.

### `src/orchestrator/__tests__/heartbeat-manager.test.ts`
**Justification:** Required to test the TypeScript HeartbeatManager fix. The new test case `does not send overwatch nudge for polling phases` directly validates the core behavior change.

### `docs/user-guide.md`
**Justification:** The polling-phase nudge exemption changes operator expectations for when Agent Mail steering nudges should appear, so the user guide now documents the visible behavior.

## QA Handoff
- **TypeScript tests**: `npx vitest run src/orchestrator/__tests__/heartbeat-manager.test.ts`
- **Elixir tests**: `cd packages/foreman_server && mix test test/overwatch_test.exs`
- **Key assertions to verify**:
  - `sendNudge` is NOT called for phases "merge", "pr-wait", and "refinery" even after multiple stale heartbeats
  - `sendNudge` IS called for non-polling phases (e.g., "developer") after stale intervals
  - Existing test `sends overwatch nudge and event after unchanged heartbeat intervals` still passes

## Decisions & Trade-offs
- **Chose Option 1 (Targeted Suppression)** over Option 2 (Explicit Touch) because:
  - Simpler: no need to add `touch()` calls throughout the codebase
  - More explicit: hardcoded list makes polling phases visible and intentional
  - Lower risk: no behavioral changes to non-polling phases
- **Included Elixir Overwatch** because it's an architectural peer that independently handles nudges; partial fix would leave polling phases vulnerable

## Known Limitations
- The `POLLING_PHASES` list is hardcoded; future polling phases require code changes. This matches the task's description of "for now hardcode the set in HeartbeatConfig."
- `refinery` phase is included in the set but may or may not actually poll (based on task description suggesting it "may poll")
