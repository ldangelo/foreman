# Code Review: Integrate CASS Memory System for cross-session agent learning

## Verdict: PASS

## Summary

The CASS Memory integration is well-implemented and architecturally sound. The three-layer memory schema (episodes, patterns, skills) is added cleanly to the existing SQLite store with proper migrations. Memory capture is wired throughout the pipeline in `runPipeline()`, prompt injection is guarded against empty memory, and all new store methods use parameterized queries. The implementation is backward compatible and non-fatal on memory query failure. Two issues are noted below: a minor episode duplication for the QA success path, and an incomplete episode capture in the review-triggered developer retry — both are low-severity and non-blocking given the additive, non-critical nature of the memory system.

## Issues

- **[NOTE]** `src/orchestrator/agent-worker.ts:600,605` — The QA success path stores the QA episode twice for the same run. `store.logEvent` is called at line 600 (before the verdict is known), then `store.storeEpisode` is called at line 605 after `parseVerdict`. On a QA success this results in one episode row — correct. However on a QA failure the episode is also stored at line 605 (`qaVerdict === "fail" ? "failure" : "success"`) and then the loop continues back to run Developer again, which will run a new QA phase and store another episode for the same retry cycle. This is by design but may accumulate episode rows faster than expected for seeds with many retries. Not a correctness bug, just worth being aware of.

- **[NOTE]** `src/orchestrator/agent-worker.ts:663-666` — In the review-triggered retry block, the QA phase result after review feedback does not call `store.storeEpisode()` for QA (only `store.logEvent`), and a failed developer retry in that block has no `storeEpisode` call at all. This is asymmetric with the main dev/QA loop, meaning review-retry learnings are partially missing from memory. Since episodes are supplementary context (not correctness-critical), this is a minor gap rather than a bug.

- **[NOTE]** `src/lib/store.ts:759` — `getSkills` uses a LIKE query with the role name interpolated into the pattern: `` `%"${role}"%` ``. Role values come from the `AgentRole` union type (`"lead" | "explorer" | "developer" | "qa" | "reviewer" | "worker"`), none of which contain SQL LIKE wildcard characters (`%` or `_`), so this is safe in practice. If the role parameter were ever sourced from user input, this would be a SQL injection risk. Worth a comment noting the assumption.

- **[NOTE]** `src/lib/store.ts` — No SQL indices are created on the new memory tables despite the Explorer report specifically calling them out as important for query performance (`project_id`, `seed_id`, `role`, `created_at`). For small datasets this won't matter, but as episodes accumulate the `getRelevantEpisodes` query will do a full table scan. Consider adding `CREATE INDEX IF NOT EXISTS` statements in the schema for `episodes(project_id, created_at)` and `patterns(project_id, success_count)`.

- **[NOTE]** `src/orchestrator/roles.ts:10` — `Episode` and `Pattern` are imported but `Episode` is not directly used in `roles.ts` (it's used via `AgentMemory.episodes` which is typed as `Episode[]` from the `AgentMemory` interface). The `Pattern` import is similarly only used implicitly. TypeScript may not flag this since the types flow through `AgentMemory`, but the imports could be trimmed to just `AgentMemory`.

## Positive Notes

- All new SQL queries use parameterized statements — no injection risk in the store methods.
- Memory query failure is wrapped in a try/catch and is non-fatal — existing runs are not affected.
- The guard `if (!hasMemory) memory = undefined` prevents injecting empty memory blocks into prompts, which is the correct behavior.
- `storePattern` implements a proper read-modify-write upsert for counting, keeping the patterns table from growing unboundedly.
- `queryMemory` enforces project isolation for all three memory types — cross-project contamination is not possible.
- `extractKeyLearnings` gracefully handles missing sections and has a sensible fallback to the report body.
- Test coverage is thorough: 23 store tests cover all edge cases for episodes, patterns, skills, and `queryMemory`; 15 roles tests cover `formatMemoryContext` and both updated prompt functions.
- TypeScript compiles cleanly and the `durationMs` extension to `PhaseResult` is clean.
- The implementation correctly limits `queryMemory` patterns to `minSuccessCount >= 1`, avoiding untested pattern suggestions.
