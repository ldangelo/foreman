# Explorer Report: Add 'foreman seed' command for natural-language issue creation

## Summary
The task is to implement a new CLI command `foreman seed` that accepts natural-language descriptions and creates one or more structured seed (issue) entries in the seeds database. This command will use Claude Code to interpret unstructured user input and generate properly-formatted issues with titles, descriptions, types, priorities, and dependencies.

## Relevant Files

### CLI Structure
- **src/cli/index.ts** (lines 1-36) — Command registration hub
  - Uses Commander.js for CLI structure
  - Currently registers 10 commands (init, plan, decompose, run, status, merge, pr, monitor, reset, attach, doctor)
  - Must add seedCommand to program.addCommand()
  - Must also import seedCommand from ./commands/seed.js (new file)

- **src/cli/commands/init.ts** (reference implementation)
  - Shows pattern for a simple command with options
  - Uses chalk for colored output, ora for spinners
  - Validates prerequisites before executing main logic
  - Error handling with process.exit(1)

- **src/cli/commands/status.ts** (reference for option parsing)
  - Shows how to handle flags and options
  - Demonstrates integration with store, seeds, and display formatting

- **src/cli/commands/plan.ts** (reference for user input)
  - Takes a description as argument (lines 16-18)
  - Can accept file path or inline text (lines 53-60)
  - Shows pattern for reading files and passing to processing

### Seeds Integration
- **src/lib/seeds.ts** (lines 1-256)
  - **SeedsClient class** — wrapper around `sd` CLI tool
  - Key methods for seed creation:
    - `create()` (lines 134-157) — creates a new seed with options for type, priority, parent, description, labels
    - Returns full Seed object after creation
    - Options: `{ type?, priority?, parent?, description?, labels? }`
  - Other useful methods: `list()`, `ready()`, `show()`, `update()`, `close()`, `addDependency()`
  - Types:
    - `Seed` interface (lines 17-27) — basic seed structure with id, title, type, priority, status, etc.
    - `SeedDetail` interface (lines 29-36) — extended with description, notes, acceptance, design, dependencies, children

### Claude SDK Integration (Pattern)
- **src/orchestrator/decomposer-llm.ts** (lines 1-102 for the pattern)
  - Demonstrates how to use Claude Code for natural language processing
  - Key pattern:
    1. Load/build a system prompt that defines output format
    2. Use `execFileSync()` to call Claude CLI with structured prompt
    3. Parse JSON response from Claude
    4. Validate and return structured data
  - System prompt emphasizes: "Your ENTIRE response must be a single JSON object. No text before or after."
  - Claude invocation (lines 40-61):
    ```typescript
    const args = [
      "--permission-mode", "bypassPermissions",
      "--print",
      "--output-format", "text",
      "--max-turns", "1",
      "--system-prompt", systemPrompt,
      "-", // read from stdin
    ];
    execFileSync(claudePath, args, { input: prompt, encoding: "utf-8" })
    ```
  - Response parsing (lines 108-142) handles markdown fences, truncation, and JSON repair

- **src/orchestrator/dispatcher.ts** (lines 1-50)
  - Shows SDK-based query pattern (imports `query` from "@anthropic-ai/claude-agent-sdk")
  - Uses `maxBudgetUsd` for cost control (line 26: PLAN_STEP_MAX_BUDGET_USD = 3.00)
  - Not recommended for this task (seeds command should be lightweight, CLI tool is simpler)

### Store Integration
- **src/lib/store.ts** — SQLite state management
  - ForemanStore class manages projects, runs, costs, events
  - Not necessary for `seed` command (works with sd directly, not through foreman runs)

### Types
- **src/orchestrator/types.ts**
  - `Priority` (line 13): "critical" | "high" | "medium" | "low"
  - `IssueType` (line 12): "task" | "spike" | "test" | "decision"
  - Note: seeds also support "bug", "feature", "epic", "chore" (from CLAUDE.md:79)

### Testing
- **src/cli/__tests__/commands.test.ts** (lines 1-119)
  - Smoke test pattern: spawn CLI via tsx, capture stdout/stderr/exitCode
  - Helper function `run()` (lines 20-35) wraps execFileAsync
  - Tests check for expected output strings and exit codes
  - Current test (line 53) checks for 7 commands — will need update to check for 8 after adding seed

## Architecture & Patterns

### Command Implementation Pattern
1. **Argument/Option Definition** (Commander.js):
   - `.argument()` for positional arguments (e.g., description text)
   - `.option()` for flags (e.g., `--type`, `--priority`)
   - `.action()` callback receives parsed options as object

2. **Validation Gate**:
   - Check prerequisites (e.g., seeds initialized)
   - Exit with helpful error if missing
   - Example: (init.ts:20-32) checks for `sd` CLI installation

3. **Main Logic**:
   - Use SeedsClient for seed operations
   - Integrate with Claude Code for natural language parsing (optional, if Claude SDK needed)
   - Format and display results

4. **Error Handling**:
   - Wrap in try-catch
   - Use chalk for colored output (red for errors)
   - Print helpful context about what failed
   - `process.exit(1)` on error, no explicit return on success

### Natural Language Processing Strategy

For parsing natural language into structured seeds, two approaches:

**Approach A: Claude Code CLI (Lightweight, Recommended)**
- Similar to decomposer-llm.ts pattern
- Send prompt to Claude Code with JSON output format
- Parse JSON response
- Example prompt structure:
  ```
  Parse this issue description into a JSON object with:
  {
    "issues": [
      {
        "title": "...",
        "description": "...",
        "type": "task|bug|feature|epic|chore|decision",
        "priority": "P0|P1|P2|P3|P4",
        "dependencies": ["other issue title", ...]
      }
    ]
  }
  ```

**Approach B: Claude Agent SDK with query()**
- Use SDK's query() method (from @anthropic-ai/claude-agent-sdk)
- More controlled but more heavyweight
- Pattern shown in dispatcher.ts:101-110
- Useful if command should support follow-up interactions

**Recommendation**: Use Approach A (Claude Code CLI) for consistency with decomposer-llm.ts and simplicity.

## Dependencies

### External (NPM)
- **chalk** — colored console output (already used by all commands)
- **ora** — spinners/progress (already used by init.ts)
- **commander** — CLI framework (already used)
- **@anthropic-ai/claude-agent-sdk** — optional, if using query() instead of Claude Code CLI

### Internal
- **src/lib/seeds.ts:SeedsClient** — required to create/manage seeds
- **src/lib/git.ts** — optional, if command needs to verify git repo status
- **src/orchestrator/types.ts** — type definitions for Priority, IssueType (optional imports)

### External Dependencies (Runtime)
- **sd CLI** (`~/.bun/bin/sd`) — required, installed via foreman init
- **Claude CLI** (`claude` command) — only if using Claude Code for NLP (optional)

## Existing Tests

### Current Test Coverage
- **src/cli/__tests__/commands.test.ts** (lines 53-106)
  - Line 53: `--help` test checks for 7 commands (init, plan, decompose, run, status, merge, monitor)
  - Will need to add "seed" to expected commands list
  - Tests use `run()` helper that spawns CLI process

- **src/lib/__tests__/seeds.test.ts** (lines 1-91)
  - Tests `unwrapSdResponse()` function
  - Tests parsing of sd JSON output
  - Can be extended to test SeedsClient.create() if needed

### No Existing Tests For
- Seed creation command itself (will be new test)
- Claude Code integration for NLP (decomposer-llm.ts has no tests)
- Natural language parsing logic

## Recommended Approach

### Command Definition (seed.ts)
**File**: `src/cli/commands/seed.ts` (new file)

```typescript
import { Command } from "commander";
import chalk from "chalk";
import ora from "ora";
import { SeedsClient } from "../../lib/seeds.js";

export const seedCommand = new Command("seed")
  .description("Create seeds from natural language description")
  .argument("<description>", "Natural language description (or path to file)")
  .option("--type <type>", "Force issue type (task|bug|feature|epic|chore|decision)")
  .option("--priority <priority>", "Force priority (P0-P4)")
  .option("--parent <id>", "Parent seed ID (for hierarchical relationships)")
  .option("--dry-run", "Show what would be created without creating seeds")
  .option("--model <model>", "Claude model to use for parsing")
  .action(async (description, opts) => {
    // 1. Validate seeds is initialized
    // 2. Read description from file if path provided
    // 3. Call Claude Code to parse natural language
    // 4. Validate response structure
    // 5. Create seeds via SeedsClient
    // 6. Display results
  });
```

### Implementation Steps
1. **Parse input** (lines similar to plan.ts:52-60)
   - Check if description is a file path
   - If so, read file; otherwise use as-is

2. **Prepare Claude prompt** (like decomposer-llm.ts:15-36)
   - System prompt emphasizing JSON-only output
   - Inject user description
   - Define output schema with issues array

3. **Call Claude Code** (like decomposer-llm.ts:38-65)
   - Use `execFileSync()` approach for simplicity
   - Handle timeout (60-120 seconds should be enough)
   - Catch errors with helpful messages

4. **Parse & Validate response** (like decomposer-llm.ts:108-142)
   - Strip markdown fences
   - JSON.parse
   - Validate structure (issues array, required fields)
   - Handle malformed responses gracefully

5. **Create seeds** (lines ~180-220)
   - Loop through parsed issues
   - Call `seedsClient.create()` for each
   - Handle dependencies (might need to create seeds first, then add deps)

6. **Display results**
   - Show created seed IDs and titles
   - List any warnings (skipped items, etc.)
   - Suggest next steps

### Command Registration
In **src/cli/index.ts**:
1. Import: `import { seedCommand } from "./commands/seed.js";`
2. Register: `program.addCommand(seedCommand);`
3. Update test expectation (line 59 in commands.test.ts): change `["init", "plan", ...]` array

### New Test File
**src/cli/__tests__/seed.test.ts**
- Test parsing file vs. inline text
- Test dry-run flag
- Test error handling (invalid descriptions, Claude failures)
- Test seed creation (mock SeedsClient)

## Potential Pitfalls & Edge Cases

1. **Claude Code availability**
   - Command depends on Claude CLI being in PATH
   - Should check availability upfront (like init.ts:20-32)
   - Provide helpful install instructions if missing

2. **Timeout / Large Descriptions**
   - Very long PRDs/descriptions might exceed Claude's context
   - Should warn user if input > ~5000 chars
   - Set reasonable timeout (60-120 seconds)

3. **JSON Parsing from Claude**
   - Claude may include markdown fences, explanations, etc.
   - Response parser must be robust (see decomposer-llm.ts:108-142)
   - Handle truncated JSON responses

4. **Dependencies & Hierarchies**
   - Natural language might mention "depends on X" — need to resolve by title
   - May need to create seeds in dependency order (topological sort)
   - Or create all first, then add deps in a second pass

5. **Seed Type Mapping**
   - User might say "bug" or "issue" — need semantic mapping to sd types
   - Options: "task", "bug", "feature", "epic", "chore", "decision", "spike" (with kind:spike label)
   - Document expected types in help text

6. **Empty/Vague Descriptions**
   - Claude might fail to parse very vague input
   - Should return zero or one seed rather than erroring
   - Could ask user for clarification (but that breaks CLI paradigm)

7. **Priority Format**
   - User might say "high", "medium", "low" — need to map to P0-P4
   - Or Claude might output "high" — need to normalize
   - Document expected format in system prompt

8. **Already-Initialized Project Requirement**
   - Command requires `sd init` to have run (`.seeds/` exists)
   - Should validate with `seedsClient.ensureSdInstalled()` and `.isInitialized()`
   - Fail gracefully with instruction to run `foreman init`

## Next Steps for Developer

1. Create `src/cli/commands/seed.ts` with command skeleton
2. Integrate SeedsClient for seed creation
3. Add Claude Code integration for NLP (copy pattern from decomposer-llm.ts)
4. Write comprehensive prompt template (system + user instruction)
5. Implement JSON parsing & validation
6. Create seeds from parsed issues
7. Update `src/cli/index.ts` to register seedCommand
8. Write tests (unit + CLI smoke test)
9. Update help text expectations in commands.test.ts
10. Manual testing with various natural language inputs

## References

- **Similar Pattern**: `src/orchestrator/decomposer-llm.ts` — natural language parsing with Claude
- **Command Pattern**: `src/cli/commands/plan.ts` — file/text input handling
- **Error Handling**: `src/cli/commands/init.ts` — validation, error messages, spinners
- **Seeds API**: `src/lib/seeds.ts:SeedsClient` — seed creation and management
- **CLI Tests**: `src/cli/__tests__/commands.test.ts` — how to test CLI commands
- **PRD**: `docs/PRD.md` — Foreman architecture and design decisions
