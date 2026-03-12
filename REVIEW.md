# Code Review: Interactive expandable agent status with summary/detail toggle

## Verdict: FAIL

## Summary
The implementation is well-structured and largely correct — `renderAgentCardSummary`, the `isExpanded` parameter on `renderAgentCard`, the `expandedRunIds` Set threading through `renderWatchDisplay`, and the stdin raw-mode keyboard handler in `watchRunsInk` are all solidly built. Backward compatibility is preserved and test coverage is thorough (73 tests, all passing). However, there is one significant UX defect: key presses have up to a 3-second delay before the visual toggle takes effect, making the feature feel broken in interactive use. For a feature whose entire purpose is interactive expand/collapse, this must be fixed before shipping.

## Issues

- **[WARNING]** `src/cli/watch-ui.ts:276-302` — **Key presses give no immediate visual feedback.** `handleKeyInput` mutates `expandedRunIds` but the screen is only re-rendered inside the `while` loop every `POLL_MS` (3 seconds). A user pressing `a` or `1` will see no response for up to 3 seconds, making the toggle appear broken. Fix: after modifying `expandedRunIds` in `handleKeyInput`, perform an immediate re-render (re-poll and write to stdout) outside the normal poll interval. A simple approach is to resolve the current sleep early (e.g. via a flag + `setImmediate`) or to factor the render logic into a helper called from both the poll loop and the key handler.

- **[WARNING]** `src/cli/watch-ui.ts:213-214` / `223` — **Toggle hints are shown for single-agent runs with no visible index prefix.** When `state.runs.length === 1`, no numeric prefix is rendered on the agent card (index is `undefined`), yet the hint still says `"1-9 toggle agent"`. A user running a single-agent watch sees a key hint referencing numbers `1-9` but no numbered labels on the card to guide them. The `a` key is sufficient for a single agent; the `1-9` hint should be omitted (or the index prefix always shown) when there is only one agent.

- **[NOTE]** `src/cli/watch-ui.ts:279` — `process.emit("SIGINT" as any)` uses an `any` cast to work around TypeScript's process event typing. This is a common workaround but consider using `process.kill(process.pid, "SIGINT")` instead, which is more semantically correct and doesn't require a type cast.

- **[NOTE]** `src/cli/watch-ui.ts:213-214` — The toggle-key hints (`'a' toggle all | 1-9 toggle agent`) are baked into `renderWatchDisplay`'s output string whenever `showDetachHint=true && !allDone`. If `renderWatchDisplay` is ever called from a non-interactive context (e.g. `foreman status`), misleading hints will appear. Consider gating these hints behind the presence of `expandedRunIds` rather than `showDetachHint`.

## Positive Notes
- Clean separation of concerns: `renderAgentCardSummary` is a pure function exported independently, making it easy to test and reuse.
- Backward compatibility is preserved perfectly — all existing callers of `renderAgentCard` and `renderWatchDisplay` work unchanged (optional parameters with sensible defaults).
- stdin raw-mode lifecycle is handled correctly: guarded by `isTTY`, wrapped in try/catch, and cleaned up in `finally` alongside the SIGINT listener.
- The "toggle all" logic (collapse all if any expanded, expand all if none expanded) is intuitive and correctly uses `lastState` for the expand-all case.
- Test coverage is excellent: 24 new tests covering summary rendering, collapsed state, mixed expand/collapse in multi-agent display, and index numbering edge cases.
- Ctrl+C correctly emits SIGINT through the existing `onSigint` handler path even in raw mode, avoiding duplicate cleanup logic.
