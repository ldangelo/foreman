# FIX_REPORT — foreman-jzycy

## Decision (the open question from the request)

The request asked to "stop the analyzer from starting a review for already-terminal
failed/cancelled runs" (expectation 3: *no review or other agent phase is started for a run
that is already terminal*). **That expectation is rejected for this bead.** The behaviour is
intentional and is now pinned by a test and by a comment next to the code that decides it:

* A terminal **failed** or **cancelled** run **is** reviewed on purpose. The review of work
  that did not land is where `foreman-gap` beads come from — that is the whole point of the
  reviewer for a failed run.
* The reviewer is not an Overwatch worker and not a second writer: it runs as a read-only
  `DetachedRun` in a scratch cwd, outside the run's worktree. This is stated in
  `docs/user-guide.md:1114` and in the "Session archive and automated review" section
  (`docs/user-guide.md:3088`).
* Therefore **no behaviour change** was made: `@terminal_events` still lists `RunFailed` and
  `RunCancelled`, and `handle_info/2` still starts an analysis for them.

What was missing was not the behaviour but (a) an explicit decision recorded at the code, and
(b) a test that pins it. Both are now in place.

## Changes

| File | Change |
| --- | --- |
| `packages/foreman_server/lib/foreman_server/review/analyzer.ex` | Added a comment above `@terminal_events` recording the decision (why a terminal failed/cancelled run is reviewed, why the reviewer is not a leaked worker or a second writer, and where the behaviour is documented). The comment quotes the exact title of the new test. |
| `packages/foreman_server/test/foreman_server/review/analyzer_test.exs` | New test `"a run whose projection is already terminal is still reviewed, failed and cancelled alike"` in `describe "subscriber"`: seeds a run, applies `RunFailed` / `RunCancelled` through `ProjectionStore.apply_events/1`, asserts the projection is already terminal (`status`, `terminal?`) when the Analyzer is notified, and asserts a review is recorded with verdict `met` and the matching status in the archive manifest. |

No production behaviour, no configuration and no public identifier changed.

## Documentation gate

No externally visible identifier was added, removed or renamed (no command/event type, no MCP
tool, no HTTP route, no CLI verb, no env var, no config key, no workflow/prompt name). The
behaviour was already documented in `docs/user-guide.md` (lines 1114-1116 and 3088-3131), so
`CLAUDE.md`, `README.md`, `docs/user-guide.md` and `docs/cli-reference.md` need no edit.

## Verification

All commands run from `packages/foreman_server` with
`DATABASE_URL=postgres://postgres:postgres@127.0.0.1:55432/foreman_test_jzycy`
(a dedicated database, because another suite holds the advisory lock on `foreman_test`).

| Command | Exit | Result |
| --- | --- | --- |
| `MIX_ENV=test mix test test/foreman_server/review/analyzer_test.exs --warnings-as-errors` | 0 | 42 tests, 42 passed |
| `MIX_ENV=test mix format --check-formatted lib/foreman_server/review/analyzer.ex test/foreman_server/review/analyzer_test.exs` | 0 | formatted |
| `MIX_ENV=test mix test test/foreman_server/review/analyzer_test.exs --warnings-as-errors` with `RunFailed RunCancelled` temporarily removed from `@terminal_events` | 2 | 38/42 passed — the new test fails, which proves it is load-bearing; `git checkout -- lib/foreman_server/review/analyzer.ex` restored the file |

The failing run above proves the new test fails when the behaviour it pins is removed
(temporary edit reverted immediately afterwards; the committed file is unchanged).

## Open items

None for this bead. The expectation (3) of `foreman-ws23g` — *no review is started for a run
that is already terminal* — is **not** implemented, on the record, because it contradicts the
documented purpose of the reviewer.
