# Developer Report: Add 'foreman seed' command for natural-language issue creation

## Approach

Implemented a new `foreman seed` CLI command that accepts a natural-language description (inline or from a file) and uses the Claude Code CLI to parse it into one or more structured issue tickets, then creates them as seeds via `SeedsClient`.

The implementation follows the established patterns in the codebase:
- Command definition follows `plan.ts` / `init.ts` patterns (Commander.js, chalk, ora spinners)
- LLM integration follows `decomposer-llm.ts` (execFileSync → Claude Code CLI → JSON parsing)
- JSON repair logic (`repairTruncatedJson`, `scanJsonNesting`) is replicated from `decomposer-llm.ts` to handle truncated/malformed Claude responses

Dependencies are resolved in a two-pass approach: all seeds are created first (pass 1), then `addDependency` calls are made using the title→id map (pass 2). This avoids needing a topological sort and handles the constraint that seeds must exist before deps can be set.

## Files Changed

- **src/cli/commands/seed.ts** — New file implementing the `seed` command. Contains:
  - `seedCommand` (Commander.js Command) with options: `--type`, `--priority`, `--parent`, `--dry-run`, `--no-llm`, `--model`
  - `parseWithClaude()` — calls Claude Code CLI with a structured system prompt and parses the JSON response into `ParsedIssue[]`
  - `normaliseIssue()` — validates/coerces LLM output fields (type, priority enums, string lengths)
  - `parseLlmResponse()` — strips markdown fences, finds JSON start, handles truncated JSON repair
  - `findClaude()` — locates the claude binary (same pattern as decomposer-llm.ts)
  - JSON repair utilities (`scanJsonNesting`, `repairTruncatedJson`) replicated from decomposer-llm.ts

- **src/cli/index.ts** — Added `import { seedCommand }` and `program.addCommand(seedCommand)`

- **src/cli/__tests__/commands.test.ts** — Updated help test from "7 commands" to "8 commands" and added "seed" to the expected command list

## Tests Added/Modified

- **src/cli/__tests__/seed.test.ts** — New test file covering:
  - CLI smoke tests (via spawned tsx process): `seed --help`, missing argument error, init check, `--dry-run --no-llm`, file input with `--dry-run --no-llm`
  - Unit tests (direct module import, always passing): command name/description, expected options (`--type`, `--priority`, `--parent`, `--dry-run`, `--no-llm`, `--model`), required argument definition
  - 3 unit tests pass cleanly; CLI process-spawn tests require a functional `tsx` binary which is not present in the worktree's `node_modules` (pre-existing infrastructure issue also affecting existing `commands.test.ts`)

## Decisions & Trade-offs

1. **Claude Code CLI vs SDK query()**: Used CLI approach (matching `decomposer-llm.ts`) rather than `query()` from the Agent SDK. This is simpler, consistent with existing patterns, and appropriate for a lightweight one-shot parsing task.

2. **`--no-llm` flag**: Added as an escape hatch for environments without Claude CLI, or for simple single-issue creation. Commander.js `--no-X` pattern sets `opts.llm = false` when passed.

3. **Two-pass dependency creation**: Create all seeds first, then wire dependencies. Simpler than topological sort and handles all cases (including mutual/invalid deps gracefully by just skipping unresolved titles).

4. **JSON repair**: Copied the `repairTruncatedJson` / `scanJsonNesting` utilities directly rather than extracting to a shared module — keeping scope minimal and consistent with existing approach in `decomposer-llm.ts`.

5. **Priority normalisation**: Claude is instructed to output P0-P4 format. The `normaliseIssue()` function defaults unrecognised priorities to "P2" rather than failing, matching the lenient validation style in `decomposer-llm.ts`.

## Known Limitations

- **No shared Claude utilities**: `findClaude`, `repairTruncatedJson`, and `scanJsonNesting` are duplicated from `decomposer-llm.ts`. A future refactor could extract these to `src/lib/claude.ts`. Deferred to keep this PR focused.
- **No confirmation prompt**: For large batch inputs (e.g. 15 issues), the command creates all seeds without asking for confirmation. `--dry-run` provides the preview; an interactive confirmation could be added later.
- **Dependency resolution by title**: Dependencies must exactly match the title of another issue in the same response. If Claude uses slightly different phrasing, deps are silently skipped. A fuzzy-match could improve this.
- **No progress display during create**: The spinner shows count but doesn't stream individual seed IDs until all are done.
