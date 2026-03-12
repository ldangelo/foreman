# Developer Report: Integrate CASS Memory System for cross-session agent learning

## Approach

The CASS Memory System (episodes, patterns, skills) was already implemented in a prior iteration. This pass addresses all reviewer notes from that implementation — fixing an asymmetric episode-storage gap in the review-triggered retry block, adding SQL indices for query performance, adding a safety comment on the LIKE query in `getSkills`, and trimming unused imports from `roles.ts`. Comprehensive tests were also added for the memory subsystem.

## Files Changed

- `src/orchestrator/roles.ts` — Removed unused `Episode` and `Pattern` type imports; only `AgentMemory` is referenced directly in this file (the others are reachable through the interface's typed arrays but don't need an explicit import here).

- `src/lib/store.ts` — Added four `CREATE INDEX IF NOT EXISTS` statements in the schema for the three memory tables (`episodes`, `patterns`, `skills`), covering the columns used in the most common query filters (`project_id`, `created_at`, `seed_id`, `role`, `success_count`, `confidence_score`). Also added an inline safety comment above the `LIKE` pattern in `getSkills` documenting that the `role` parameter must only ever be an `AgentRole` union value (which contains no SQL wildcard characters).

- `src/orchestrator/agent-worker.ts` — Fixed the asymmetry noted in the review-triggered retry block (lines 663-666). The QA phase result (both success and failure outcomes) now calls `store.storeEpisode`, consistent with the main dev/QA loop. A failed developer run in that block now also calls `store.storeEpisode` with the failure outcome. The failure-path `storeEpisode` also mirrors the corresponding calls in the main loop.

## Tests Added/Modified

- `src/lib/__tests__/store.test.ts` — Added four new `describe` blocks covering the entire memory subsystem:
  - **episodes**: store/retrieve, project filter, role filter, limit param, optional fields
  - **patterns**: new pattern, success upsert, failure upsert, minSuccessCount filter, patternType filter
  - **skills**: store/retrieve, role filter, "all skills" path, confidence ordering
  - **queryMemory**: combined result, zero-success patterns excluded, empty project

- `src/orchestrator/__tests__/roles.test.ts` — Added `formatMemoryContext` describe block:
  - Empty memory returns `""`, ✅/❌ icons, episode learnings, pattern success-rate %, skill confidence %, memory injection into `explorerPrompt`, absence of memory block in `developerPrompt` when undefined.

Total: 65 tests passing (up from 30 + 10 = 40 before).

## Decisions & Trade-offs

- **Indices**: Added indices on `(project_id, created_at)`, `(project_id, seed_id, role)` for episodes, `(project_id, success_count)` for patterns, and `(project_id, confidence_score)` for skills. These are the exact columns used by `getRelevantEpisodes`, `getPatterns`, and `getSkills`. `CREATE INDEX IF NOT EXISTS` is idempotent so safe to add in the base schema rather than as a MIGRATIONS entry.

- **storeEpisode in review-retry block**: The QA episode is now stored unconditionally (regardless of `qaResult.success`, i.e. SDK success vs budget-exceeded). This matches the main loop behaviour and means even budget-exceeded QA runs contribute a failure episode, which is useful learning signal. The verdict is derived from the report file to set the outcome correctly.

- **No change to the NOTE about duplicate QA episodes** (lines 600/605): This is by design — one `logEvent` and one `storeEpisode` per QA run. The reviewer confirmed it is "not a correctness bug".

## Known Limitations

- SQL indices are defined in the base schema string rather than as MIGRATIONS entries. This means existing databases will pick them up on the next `ForemanStore` constructor call (because `CREATE INDEX IF NOT EXISTS` is idempotent and runs in `exec(SCHEMA)`). No migration entry needed.
- Pattern deduplication relies on an exact string match for `pattern_description`. Future improvement could use semantic similarity, but that is out of scope for this task.
