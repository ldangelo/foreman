# Developer Report: Integrate CASS Memory System for cross-session agent learning

## Approach

Implemented a 3-layer CASS (Cross-Agent Session Search) memory system using SQLite-backed storage and prompt injection. The approach follows the Explorer Report's MVP plan:

1. **Schema & Types** — Added three new tables (`episodes`, `patterns`, `skills`) to the existing SQLite store with `CREATE TABLE IF NOT EXISTS` (fully backward-compatible)
2. **Store Methods** — Implemented full CRUD + query methods for all three memory layers
3. **Learnings Capture** — Modified `agent-worker.ts` pipeline to store episodes after every phase (explorer, developer, qa, reviewer), with outcome tracking and key-learnings extraction from report files
4. **Prompt Injection** — Added optional `memory?: AgentMemory` parameter to `explorerPrompt()` and `developerPrompt()` with formatted context sections

Memory injection is fully opt-in and gracefully degrades: if memory is empty or unavailable, prompts are unchanged from existing behavior.

## Files Changed

- **`src/lib/store.ts`** — Added `Episode`, `Pattern`, `Skill`, and `AgentMemory` interfaces; added 3 new tables to SCHEMA; added 9 new methods: `storeEpisode()`, `getRelevantEpisodes()`, `storePattern()`, `getPatterns()`, `storeSkill()`, `getSkills()`, `queryMemory()`

- **`src/orchestrator/roles.ts`** — Added `import type { AgentMemory, Episode, Pattern } from "../lib/store.js"`; added `formatMemoryContext()` helper that formats episodes/patterns/skills into a human-readable prompt section; updated `explorerPrompt()` and `developerPrompt()` to accept optional `memory?: AgentMemory` and inject the formatted context block

- **`src/orchestrator/agent-worker.ts`** — Added `AgentMemory` import; extended `PhaseResult` interface with `durationMs: number`; added `extractKeyLearnings()` helper to pull summaries from report files; updated `runPipeline()` to: (a) query memory from store at pipeline start, (b) pass memory to `explorerPrompt()` and `developerPrompt()`, (c) call `store.storeEpisode()` after every phase with outcome + cost + duration + learnings

## Tests Added/Modified

- **`src/lib/__tests__/store.memory.test.ts`** *(new — 23 tests)*
  - Episode CRUD: store/retrieve, filtering by project/seed/role, ordering (rowid tiebreaker), limit
  - Pattern upsert: success/failure count incrementing, deduplication, filtering by type and minSuccessCount
  - Skill storage: roles JSON array, confidence defaults, role-based LIKE filtering
  - `queryMemory()`: empty memory, combined results, seedId/role filtering, project isolation

- **`src/orchestrator/__tests__/roles.memory.test.ts`** *(new — 15 tests)*
  - `formatMemoryContext()`: empty memory → empty string, episode formatting (✅/❌ icons, cost, learnings), pattern success-rate calculation, skill confidence display, 300-char truncation
  - `explorerPrompt()` with memory: section included when populated, omitted when empty/undefined, seed context preserved
  - `developerPrompt()` with memory: section included, omitted, combined with feedback

## Decisions & Trade-offs

- **Memory stored in existing SQLite DB**: Reuses `ForemanStore` infrastructure — no new dependencies, WAL mode already enabled for concurrent writes
- **`storePattern()` upserts**: Avoids duplicate pattern rows; increments counts on repeated encounters. Patterns only surface in memory when `success_count >= 1` (from `queryMemory`)
- **Episode ordering uses `rowid DESC` tiebreaker**: Matches existing `getRunsForSeed()` pattern; prevents indeterminate order when multiple episodes share the same `created_at` millisecond
- **Memory injection is opt-in + non-breaking**: All memory parameters are optional; existing call sites continue to work unchanged; `runPipeline` passes `undefined` if store query fails
- **Key learnings extraction**: Simple regex heuristic (looks for Summary/Approach/Test Results sections first, falls back to first 500 chars). Sufficient for MVP; could use LLM extraction later
- **Only patterns with `success_count >= 1` injected**: Prevents noise from first-seen patterns; `storePattern` creates entries immediately so they appear on second confirmation

## Known Limitations

- **No semantic similarity search**: Episodes retrieved by exact `seed_id` or `role` match — no embedding-based similarity. Tasks with similar descriptions but different IDs won't surface each other's learnings until embeddings are added
- **No memory pruning/archiving**: Memory tables will grow indefinitely; old/irrelevant episodes not cleaned up automatically
- **Skills not auto-populated**: The `storeSkill()` and `getSkills()` plumbing is in place, but nothing in the pipeline auto-extracts skills from completed tasks. Skills must be populated manually or via a future "skill extraction" phase
- **`extractKeyLearnings()` is heuristic**: Relies on consistent report formatting; if a report doesn't have a standard heading, falls back to the first 500 chars which may not be informative
