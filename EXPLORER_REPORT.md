# Explorer Report: Integrate CASS Memory System for cross-session agent learning

## Executive Summary

Foreman currently has no cross-session learning mechanism. Each task runs in isolation with no knowledge transfer from past runs on the same codebase. CASS (Cross-Agent Session Search) would enable agents to:
1. **Search** across 11+ past session histories for similar problems
2. **Learn** from successful patterns and strategies that worked before
3. **Adapt** using a 3-layer cognitive architecture (episodic, working, procedural)

The codebase is well-structured for this integration, requiring changes primarily to:
- Prompt generation (`roles.ts`) — inject memory context into agent instructions
- Store schema (`store.ts`) — add memory tables (episodes, patterns, skills)
- Agent worker (`agent-worker.ts`) — capture learnings after each phase
- Dispatcher (`dispatcher.ts`) — query memory when spawning agents

---

## Relevant Files

### Core Agent Execution
- **`src/orchestrator/agent-worker.ts`** (728 lines)
  - Main worker process spawned per task. Runs the SDK `query()` call.
  - Currently tracks: session IDs (line 164-169), progress (line 110-128), costs, tool usage
  - **Why relevant**: Must capture agent outputs and learnings after each phase to populate memory
  - **Change scope**: Add memory capture after `runPhase()` (line 310-399) completes, store successful patterns

- **`src/orchestrator/roles.ts`** (283 lines)
  - Defines role-specific prompts (`explorerPrompt`, `developerPrompt`, `qaPrompt`, `reviewerPrompt`)
  - Each prompt has role, model, maxBudgetUsd, and reportFile definition (lines 21-46)
  - **Why relevant**: Need to inject memory context into each prompt to give agents access to past learnings
  - **Change scope**: Modify prompt templates to accept `previousEpisodes`, `successfulPatterns`, and `applicableSkills` parameters

### Database & State Management
- **`src/lib/store.ts`** (510 lines)
  - SQLite database with `projects`, `runs`, `costs`, `events` tables
  - `ForemanStore` class provides methods to query runs (line 309-320), retrieve progress (line 335-347), log events (line 397-414)
  - **Why relevant**: Must add new tables for CASS memory (episodes, patterns, skills) and methods to query/store them
  - **Change scope**:
    - Add 3 new tables: `episodes` (episodic memory), `patterns` (working memory), `skills` (procedural memory)
    - Add methods: `storeEpisode()`, `getRelevantEpisodes()`, `storePattern()`, `getPatterns()`, `storeSkill()`, `getSkills()`
    - Index by codebase path and task type for efficient similarity search

### Task Dispatch & Configuration
- **`src/orchestrator/dispatcher.ts`** (550+ lines)
  - Spawns agents via `spawnAgent()` (line 468+) and `resumeAgent()` (line 520+)
  - Creates `WorkerConfig` (line 34-48 in agent-worker.ts) passed to worker process
  - Calls `explorerPrompt()`, `developerPrompt()` etc. to build agent instructions
  - **Why relevant**: Integration point where memory should be queried and injected into config
  - **Change scope**:
    - Before spawning agents, query relevant memory
    - Pass memory context in `WorkerConfig` or inject into prompts
    - Modify `spawnAgent()` to retrieve applicable episodes/patterns/skills before building prompts

### Prompt Templates
- **`src/orchestrator/templates.ts`** (46 lines)
  - Generates `TASK.md` written to worktree (used by all agents)
  - Simple template with seed ID, title, description, model, team info
  - **Why relevant**: Could augment TASK.md to include memory context (similar past tasks, successful approaches)
  - **Change scope**: Optional enhancement to show agents "Here are 3 similar tasks solved before and what worked"

### Agent Configuration Interface
- **`src/orchestrator/types.ts`** (152 lines)
  - Defines `AgentRole`, `ModelSelection`, `SeedInfo`, `DispatchedTask`, etc.
  - `WorkerConfig` interface lives in agent-worker.ts (line 34-48)
  - **Why relevant**: May need to extend `SeedInfo` or create new config type to carry memory
  - **Change scope**: Add optional `memory?: AgentMemory` field to `WorkerConfig` type

---

## Architecture & Patterns

### Current Session/Memory Model
1. **Single-session isolation**: Each task gets its own worktree and SDK session
2. **Session tracking**: SDK session ID stored in `session_key` (format: `foreman:sdk:<model>:<runId>:session-<sessionId>`)
3. **No cross-session visibility**: Agents can't see past runs or learnings
4. **State persistence**: Only SQLite database and git worktree isolation
5. **Inter-agent communication**: Via report files (EXPLORER_REPORT.md, DEVELOPER_REPORT.md, QA_REPORT.md, REVIEW.md)

### Pipeline Orchestration
- **Pipeline phases**: Explorer → Developer ⇄ QA → Reviewer → Finalize (line 521-650 in agent-worker.ts)
- **Phase decision gates**: QA/Reviewer verdicts trigger retry loops (line 537-625)
- **Report rotation**: Old reports timestamped before new phase starts (line 407-423)
- **Naming conventions**: CamelCase for functions, SCREAMING_SNAKE for constants

### Error Handling & Retry Patterns
- **Rate limit detection**: Checks for "hit your limit" or "rate limit" strings (line 223-225, 267)
- **Stuck vs Failed**: Rate limits → "stuck" status (resumable), other errors → "failed" (line 227-230)
- **Max retries**: MAX_DEV_RETRIES = 2 for Dev ⇄ QA loop (line 495)
- **Feedback propagation**: QA/Review issues passed back to Developer via feedbackContext (line 571-608)

### Database Patterns
- **JSONL-style**: Events stored as JSON strings (line 403-407 in store.ts)
- **Normalization**: Runs linked to projects via foreign key (line 252-253)
- **Idempotent migrations**: ALTER TABLE statements wrapped in try-catch (line 152-159)
- **Prepared statements**: All queries use parameterized format to prevent injection

---

## Dependencies

### Internal Dependencies
- **agent-worker.ts** imports:
  - `query()` from `@anthropic-ai/claude-agent-sdk` (core SDK)
  - `ROLE_CONFIGS`, prompt functions from `./roles.js`
  - `ForemanStore` from `../lib/store.js`
  - `createWorktree()` from `../lib/git.js`

- **dispatcher.ts** imports:
  - `SeedsClient` from `../lib/seeds.js` (task tracking)
  - `ForemanStore` from `../lib/store.js`
  - `createWorktree()` from `../lib/git.js`
  - `workerAgentMd` from `./templates.js`
  - Type definitions from `./types.js`

- **roles.ts** is imported by:
  - `agent-worker.ts` (all prompt functions and role configs)
  - Tests in `__tests__/roles.test.ts`

- **store.ts** is imported by:
  - `agent-worker.ts` for tracking runs and progress
  - `dispatcher.ts` for recording dispatch events
  - CLI commands for metrics and monitoring

### External Dependencies
- **@anthropic-ai/claude-agent-sdk** (v0.2.72): Core agent runtime
- **better-sqlite3** (v12.6.2): SQLite adapter
- **chalk** (v5.6.2): Terminal colors (for CLI output)
- **commander** (v14.0.3): CLI argument parsing

### What Depends on This Code
- CLI commands in `src/cli/commands/`:
  - `run.ts` — calls `dispatcher.dispatch()`
  - `monitor.ts` — polls `store.getActiveRuns()` and `store.getRunProgress()`
  - `merge.ts` — reads completed runs from store
- Dashboard (watches `store` for real-time updates)
- Test suite (`src/orchestrator/__tests__/*.test.ts`)

---

## Existing Tests

### Agent Worker Tests
- **`src/orchestrator/__tests__/agent-worker.test.ts`** (3.6 KB)
  - Tests detached worker process spawning via `spawnWorker()`
  - Mocks SDK and filesystem operations
  - **Coverage**: Session tracking, config file generation, error handling

- **`src/orchestrator/__tests__/agent-worker-team.test.ts`** (7.2 KB)
  - Tests pipeline orchestration (Explorer → Developer → QA → Reviewer)
  - Mocks phase execution and report file parsing
  - **Coverage**: Phase retry loops, verdict parsing, issue extraction

- **`src/orchestrator/__tests__/worker-spawn.test.ts`** (4.0 KB)
  - Tests detached process spawning mechanics
  - Mocks `spawn()` and file I/O
  - **Coverage**: Process isolation, env vars, cleanup

### Role & Prompt Tests
- **`src/orchestrator/__tests__/roles.test.ts`** (144 lines)
  - Tests prompt template generation
  - Tests verdict parsing (`parseVerdict()`)
  - Tests issue extraction (`extractIssues()`)
  - Tests that feedback context is included in developer prompts (line 77-81)
  - **Coverage**: All 4 role prompts, report parsing, feedback flow

### Dispatcher Tests
- **`src/orchestrator/__tests__/dispatcher.test.ts`** (2.4 KB)
  - Tests seed selection and agent spawning
  - Mocks seeds and store
  - **Coverage**: Ready seed selection, duplicate prevention, agent limits

### Store Tests
- **`src/lib/__tests__/store.test.ts`** (present in file list)
  - Should test run creation, querying, progress tracking, events
  - **Location**: Not provided in read, but referenced in file list

---

## Recommended Approach

### Phase 1: Design Memory Schema (Week 1)
1. **Episodic Memory** — Complete past executions
   - Table: `episodes`
   - Columns: `id`, `run_id`, `project_id`, `seed_id`, `task_title`, `task_description`, `role`, `outcome` (pass/fail), `duration_ms`, `cost_usd`, `key_learnings`, `created_at`
   - Index by: `project_id`, `seed_id`, `role`, `outcome`

2. **Working Memory** — Successful patterns in current codebase
   - Table: `patterns`
   - Columns: `id`, `project_id`, `pattern_type` (e.g., "file-location", "testing-approach", "error-recovery"), `pattern_description`, `success_count`, `failure_count`, `first_seen`, `last_used`, `created_at`
   - Index by: `project_id`, `pattern_type`

3. **Procedural Memory** — Learned skills/strategies
   - Table: `skills`
   - Columns: `id`, `project_id`, `skill_name`, `skill_description`, `applicable_to_roles` (JSON array), `success_examples` (JSON), `confidence_score` (0-100), `created_at`
   - Index by: `project_id`, `skill_name`

### Phase 2: Extend Store (Week 1-2)
1. **Add migrations** to `src/lib/store.ts`:
   ```typescript
   ALTER TABLE runs ADD COLUMN learnings TEXT DEFAULT NULL;
   ALTER TABLE runs ADD COLUMN patterns_applied TEXT DEFAULT NULL;
   CREATE TABLE episodes (...);
   CREATE TABLE patterns (...);
   CREATE TABLE skills (...);
   ```

2. **Add store methods**:
   - `storeEpisode(runId, projectId, seedId, taskTitle, description, role, outcome, learnings)`
   - `getEpisodesBySeed(seedId, projectId)` — past runs on same seed
   - `getEpisodesByRole(role, projectId)` — past runs by same role
   - `getEpisodesByOutcome(projectId, outcome)` — successful/failed episodes
   - `storePattern(projectId, patternType, description, outcome)`
   - `getPatternsByType(projectId, patternType)`
   - `storeSkill(projectId, skillName, description, roles, examples)`
   - `getSkillsByRole(projectId, role)`

3. **Add type definitions** to `src/lib/store.ts`:
   ```typescript
   export interface Episode { ... }
   export interface Pattern { ... }
   export interface Skill { ... }
   export interface AgentMemory {
     episodes: Episode[];
     patterns: Pattern[];
     skills: Skill[];
   }
   ```

### Phase 3: Capture Learnings (Week 2)
1. **Modify `agent-worker.ts`**:
   - After each `runPhase()` completes (line 310-399), extract learnings from phase result
   - Parse report files for key insights
   - Call `store.storeEpisode()` to persist what we learned
   - Track patterns applied during phase

2. **Modify `runPhase()` return type**:
   - Extend `PhaseResult` to include `learnings: string` and `patternsApplied: string[]`
   - Extract from report files before returning

3. **Extend `RunProgress` in store.ts**:
   - Add optional `learnings?: string` field to capture phase learnings in real-time

### Phase 4: Inject Memory into Prompts (Week 2-3)
1. **Modify `roles.ts` prompt functions**:
   - Add optional `memory?: AgentMemory` parameter to each prompt function
   - Prepend "## Past Similar Tasks" section with relevant episodes
   - Add "## Learned Patterns That Work Here" section
   - Add "## Applicable Skills from Similar Roles" section

2. **Example new prompt section** (in `explorerPrompt()`):
   ```
   ## Past Learnings

   ### Similar Tasks You've Explored Before
   - ${memory.episodes.map(e => `- **${e.task_title}**: ${e.key_learnings}`).join('\n')}

   ### Patterns That Have Worked in This Codebase
   - ${memory.patterns.map(p => `- ${p.pattern_description} (success rate: ${p.success_count}/${p.success_count+p.failure_count})`).join('\n')}
   ```

3. **Update dispatcher to pass memory**:
   - Before calling `runPhase()`, query relevant memory
   - Pass memory context to prompt generation functions
   - Store as part of `WorkerConfig` or inline in prompts

### Phase 5: Wire Dispatcher to Memory (Week 3)
1. **Modify `dispatcher.ts` `spawnAgent()`**:
   - Query store for relevant episodes, patterns, skills before building prompts
   - Filter by project, seed type, role
   - Rank by relevance (recency, success rate)
   - Pass top 3-5 of each type to prompt functions

2. **Create helper function** `queryMemory(store, projectId, seedId, role)`:
   - Returns `AgentMemory` object with filtered episodes/patterns/skills

3. **Update `WorkerConfig` interface**:
   - Add optional `memory?: AgentMemory` field
   - Serialize to JSON when writing config file

### Phase 6: Testing & Validation (Week 3-4)
1. **Add memory-related tests** to `__tests__/`:
   - `store.memory.test.ts` — test store memory methods
   - `roles.memory.test.ts` — test prompt injection with memory
   - `dispatcher.memory.test.ts` — test memory query and passing

2. **Integration test**:
   - Run two related tasks in sequence
   - Verify first task's learnings appear in second task's prompt

3. **Regression tests**:
   - Verify agents still work without memory (graceful fallback)
   - Verify memory doesn't break existing role configs

---

## Potential Pitfalls & Mitigations

### 1. **Memory Pollution** — Irrelevant past learnings confuse agents
   - **Mitigation**: Implement semantic similarity search (task description embeddings) rather than keyword matching
   - **Fallback**: Start simple with keyword-based filtering, upgrade to embeddings later
   - **Test**: Unit tests with intentionally dissimilar tasks to ensure filtering works

### 2. **Hallucinated Patterns** — Store learns false patterns if first few runs happen to succeed by luck
   - **Mitigation**: Only store patterns after 3+ confirmations; track success rate (not just count)
   - **Fallback**: Set confidence threshold (e.g., only suggest patterns with >70% success rate)

### 3. **Performance Degradation** — Memory queries slow down agent startup
   - **Mitigation**: Add indices on (project_id, created_at), keep memory tables smaller by archiving old entries
   - **Fallback**: Cache memory for a project in memory for 1 hour, reload on cache miss

### 4. **Schema Backward Compatibility** — Old runs don't have learnings/patterns fields
   - **Mitigation**: Use `DEFAULT NULL` for new columns, test with existing runs gracefully
   - **Fallback**: Provide migration script to backfill reasonable defaults

### 5. **SQLite Write Contention** — Multiple agents writing to memory tables simultaneously
   - **Mitigation**: Use `PRAGMA journal_mode = WAL` (already enabled in store.ts line 148)
   - **Fallback**: Batch writes to memory tables (collect learnings in memory, flush every N seconds)

### 6. **Over-reliance on Memory** — Agents become "lazy" and copy past solutions verbatim instead of adapting
   - **Mitigation**: Frame memory as "context" not "answer"; inject at beginning of prompt, not end
   - **Test**: Code review verdicts should flag "doesn't match new requirement" if solution is copy-pasted

---

## Implementation Order

### Must-Have (MVP)
1. **Store Schema** — Add 3 memory tables to schema.ts (with migrations)
2. **Store Methods** — Implement `storeEpisode()`, `getEpisodesBySeed()`, basic memory querying
3. **Learnings Capture** — Modify `agent-worker.ts` to extract and store learnings after each phase
4. **Prompt Injection** — Modify `explorerPrompt()` and `developerPrompt()` to accept and use memory

### Nice-to-Have (Phase 2)
5. **Memory Ranking** — Rank episodes/patterns by relevance (success rate, recency)
6. **Skill Library** — Detect and store generalizable skills across roles
7. **Similarity Search** — Implement semantic matching (embeddings) for better memory recall
8. **Memory Dashboard** — UI to inspect what agents have learned from past runs

### Post-Launch
9. **Meta-Learning** — Track which patterns work best per codebase type
10. **Skill Transfer** — Apply skills learned in one repo to similar repos
11. **Agent Autonomy** — Allow agents to suggest new memory entries (e.g., "I discovered a pattern")

---

## Files to Create

No new files strictly required for MVP, but useful to add:

1. **`src/lib/memory.ts`** — Optional: Centralized memory management (wrapper around store memory methods)
2. **`src/orchestrator/__tests__/memory.test.ts`** — Test memory storage and retrieval
3. **Migration** — SQL file documenting schema changes (optional if using inline migrations)

---

## Summary

The CASS Memory integration is **architecturally feasible** and **low-risk** because:
- ✅ Clean separation: Store is isolated in `src/lib/store.ts`
- ✅ Agent isolation: Agents already sandboxed in worktrees, adding context won't affect isolation
- ✅ Backward compatible: New memory fields are optional (DEFAULT NULL)
- ✅ Extensible: 3-layer memory model aligns with agent roles (Explorer ↔ episodic, Developer ↔ working, Reviewer ↔ procedural)

**Critical path**: Store schema + learnings capture + prompt injection = 2-3 weeks.
**Highest impact**: Agents learning which patterns work in each codebase (patterns table + developer prompt injection).
