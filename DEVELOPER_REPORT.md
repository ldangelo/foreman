# Developer Report: Add 'foreman seed' command for natural-language issue creation

## Approach

This iteration addressed all five review feedback items (two WARNINGs, three NOTEs) from the previous review cycle.  No new functionality was added; every change is a targeted fix or improvement to existing code.

## Files Changed

### `src/lib/seeds.ts`
- **Fix [WARNING]**: Added `if (opts?.parent) args.push("--parent", opts.parent);` in `SeedsClient.create()`.  Previously the `parent` field was accepted in the type signature but silently discarded, so every seed created with `--parent` ended up as a top-level issue instead of a child.

### `src/cli/commands/seed.ts`
- **Fix [WARNING]**: In the dependency-wiring second pass, when a dependency title cannot be resolved to a created seed ID, a `createSpinner.warn(...)` message is now emitted for each unresolved dependency instead of silently dropping it.
- **Fix [NOTE]**: In `--no-llm` mode with `inputText.length > 200`, the `description` field is now set to `inputText.slice(200)` (the text after the title prefix) rather than the full `inputText`, eliminating the duplicate prefix in description.
- **Fix [NOTE]**: On partial creation failure the error handler now prints all already-created seeds (`id — title`) before exiting, helping the user clean up any orphaned issues.
- **Fix [NOTE]**: The `which claude` fallback in `findClaude()` now augments `PATH` with `/opt/homebrew/bin`, consistent with the env passed to `execFileSync` when actually invoking Claude.  Previously Claude installed only via Homebrew could be missed by the fallback even though the executable was accessible.
- **Export internal helpers**: `normaliseIssue`, `parseLlmResponse`, and `repairTruncatedJson` are now exported (they were previously private).  This is purely for testability and does not change runtime behaviour.

## Tests Added/Modified

### `src/lib/__tests__/seeds-client.test.ts` (new file)
Covers `SeedsClient.create()` argument construction using `vi.hoisted` + `vi.mock("node:child_process")` so no real binary is needed:
- Verifies `--parent` IS included in args when `parent` option is provided.
- Verifies `--parent` is NOT included when `parent` is absent.
- Verifies `--type`, `--priority`, `--description`, `--labels` are passed correctly.
- Verifies all options can be combined in a single call.

### `src/cli/__tests__/seed.test.ts` (extended)
Added three new `describe` blocks that test the now-exported helpers:

**`parseLlmResponse`** (6 tests):
- Parses plain JSON, markdown-fenced JSON, leading-text JSON.
- Falls back to JSON-repair for truncated input.
- Throws on completely unparseable input.

**`normaliseIssue`** (9 tests):
- Default `type` and `priority`.
- Invalid values fall back to defaults.
- Title truncation at 200 chars, coercion to string.
- `dependencies` and `labels` array handling.

**`repairTruncatedJson`** (4 tests):
- No-op on already-valid JSON.
- Closes unclosed object/array.
- Handles truncation inside a string value.
- Removes trailing commas.

**`--no-llm description slice behaviour`** (2 conditional CLI tests):
- Input > 200 chars: dry-run output contains the remainder text (not the full input repeated).
- Input exactly 200 chars: no separate description line in output.

## Decisions & Trade-offs

- **Exporting helpers**: Exporting `normaliseIssue`, `parseLlmResponse`, and `repairTruncatedJson` adds a small surface to the module's public API, but the testing value outweighs the cost.  All three are implementation details that consumers are unlikely to call directly.
- **`createSpinner.warn` for unresolved deps**: Using the spinner's warn method keeps the progress indicator intact and prints a clearly-prefixed warning line.  An alternative would be to collect all warnings and print them after `createSpinner.succeed`, but inline warning maintains the chronological flow.
- **`which` fallback PATH augmentation**: The fix exactly mirrors what is already done when invoking Claude (`/opt/homebrew/bin:${process.env.PATH}`), so no new env logic is introduced.

## Known Limitations

- The `--no-llm` description slice tests are conditional on `sd` being installed; they only assert on the output when `exitCode === 0`.
- `SeedsClient.create` tests mock at the `node:child_process` level, which means they test the full argument-building path but do not exercise the JSON-parsing of the response.
