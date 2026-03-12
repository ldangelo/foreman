# Code Review: Add 'foreman seed' command for natural-language issue creation

## Verdict: FAIL

## Summary

The implementation is well-structured and follows existing codebase patterns closely. The command skeleton, Claude integration, JSON repair logic, and two-pass dependency wiring are all solid. However there are two WARNING-level bugs: the `--parent` option is silently ignored because `SeedsClient.create()` accepts `parent` in its opts but never passes it to the `sd` CLI args, and unresolved cross-issue dependencies are silently dropped with no user notification. There are also minor issues around partial-failure handling and a `--no-llm` description redundancy worth noting.

## Issues

- **[WARNING]** `src/lib/seeds.ts:144-150` — `SeedsClient.create()` accepts `opts.parent` in its type signature but never appends `--parent` to the `sd create` args. The `seed.ts` command passes `parent: opts.parent` at line 149, but the parent relationship is silently discarded. Every seed created with `--parent` will be a top-level issue instead of a child. The fix is to add `if (opts?.parent) args.push("--parent", opts.parent);` in `seeds.ts` (or at minimum document that `parent` is not yet wired).

- **[WARNING]** `src/cli/commands/seed.ts:163-168` — When an LLM-returned dependency title does not exactly match the title of another issue in the same batch (e.g. minor wording difference, truncation), the dependency is silently dropped. The user sees "Created 5 seed(s)" but the dependency graph is incomplete with no indication of which deps were lost. A warning message should be emitted for each unresolved dependency title.

- **[NOTE]** `src/cli/commands/seed.ts:86-87` — In `--no-llm` mode, when `inputText.length > 200`, `title` is the first 200 characters and `description` is the full text (including those same first 200 characters). The description field thus duplicates the title prefix. This is a minor UX issue; `description` could be set to `inputText.slice(200)` or the full text is acceptable depending on how `sd` renders the fields.

- **[NOTE]** `src/cli/commands/seed.ts:144-178` — If seed creation fails partway through (e.g., issue 3 of 5 fails), the seeds created so far are left in an unlinked orphan state with no rollback and no list of already-created IDs in the error output. Printing `createdSeeds` on partial failure would help users clean up.

- **[NOTE]** `src/cli/commands/seed.ts:329-350` — `findClaude()` augments `PATH` with `/opt/homebrew/bin` inside the `execFileSync` env (line 246) but the final `which claude` fallback at line 345 runs without that augmented PATH. If Claude is installed in Homebrew and not in the shell's default PATH, the `which` fallback would fail even though the Homebrew candidate at line 330 would have worked — but that path is only tried if it passes the `test -x` check. The inconsistency is low-risk but worth noting.

## Positive Notes

- The two-pass approach (create all seeds first, then add dependencies) correctly handles forward-references and avoids ordering issues.
- `parseLlmResponse()` and `repairTruncatedJson()` are robust: they strip markdown fences, handle leading non-JSON text, and attempt JSON repair on truncated responses — consistent with the pattern in `decomposer-llm.ts`.
- `normaliseIssue()` provides sensible defaults (`"task"`, `"P2"`) and validates both type and priority against allowlists, preventing invalid values from reaching `sd`.
- The `--no-llm` escape hatch is a practical and well-executed addition that avoids Claude dependency for simple cases.
- Prerequisites are checked cleanly with `ensureSdInstalled()` and `isInitialized()` before any work begins, matching the pattern in other commands.
- Command registration, import, and the `commands.test.ts` update (7→8 commands, `findTsx()` helper) are all correct and complete.
- TypeScript compiles cleanly; all 8 new tests pass.
