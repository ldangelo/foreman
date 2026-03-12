# Developer Report: Unify agent status display between status and run commands

## Approach

Addressed three follow-up issues noted in the previous code review of the status/run display unification PR. All changes are in the worktree for seed foreman-d76c.

## Files Changed

- `src/cli/watch-ui.ts` — Added `currentPhase` pipeline-phase display to `renderAgentCard` (the expanded card view). The Phase row (colour-coded by role: cyan=explorer, green=developer, yellow=qa, magenta=reviewer, blue=finalize) is inserted between the Turns and Tools rows. This mirrors what `status.ts` used to render inline before the unification, restoring the feature for multi-phase pipeline runs in both `foreman run` and `foreman status`.

- `src/cli/commands/status.ts` — Fixed the trailing blank line cosmetic issue. The loop now only emits a separator `console.log()` between cards (not after the last one), eliminating the dangling blank line when a single agent is active.

- `src/cli/__tests__/status-display.test.ts` — Replaced dead-code tests (`parsePipelinePhase` and `formatAgentActivity` re-implementations that mirrored logic removed from production) with real tests exercising the exported `renderAgentCard` function from `watch-ui.ts`. 17 tests covering: all five pipeline phases, phase omission when not set, Tools row alongside Phase row, lastToolCall annotation, tool breakdown bar chart, files changed listing, `+N more` truncation, and initializing/pending states.

## Tests Added/Modified

- `src/cli/__tests__/status-display.test.ts` — Full replacement. Old file re-implemented and tested `parsePipelinePhase()` and `formatAgentActivity()` (dead code no longer in production). New file directly imports and tests `renderAgentCard` from `watch-ui.ts`:
  - `renderAgentCard — currentPhase display` (8 tests)
  - `renderAgentCard — tool breakdown` (4 tests)
  - `renderAgentCard — files changed` (3 tests)
  - `renderAgentCard — pending / initializing states` (2 tests)

All 17 tests pass; TypeScript compiles cleanly with `tsc --noEmit`.

## Decisions & Trade-offs

- **Phase row placement**: Inserted Phase between Turns and Tools (rather than after Tools) so the most semantically important pipeline info appears near the top of the card, before the tool breakdown detail.
- **Phase colours**: Reused the same colour scheme that `status.ts` used inline before the unification (`chalk.cyan/green/yellow/magenta/blue`), keeping visual consistency.
- **Trailing blank line fix**: Changed the loop from an unconditional `console.log()` after every card to a conditional separator only between cards. This is the minimal change; an alternative would have been to build all card strings into an array and `join("\n\n")`, but the current approach is clearer.

## Known Limitations

- The worktree's `renderAgentCard` is a simpler (non-interactive) version compared to the main repo, which has expand/collapse and per-run indexing. This PR addresses issues in the worktree version only; the main repo's more advanced features are separate work.
