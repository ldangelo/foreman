# CodeRabbit Review Report — coord-e363648b60a1de0f / run-c49ef2346998c9e59e2679dba08aeca8

## Review engine

Command (run from worktree root, base `$FOREMAN_BASE_BRANCH=main`):

```
coderabbit review --agent --base "main"
```

Ran successfully in both rounds (engine = same as the GitHub PR bot, run locally against the working tree).

## Rounds

### Round 1
- Findings received: 2 (1 Major, 1 Minor)
- Fixed: 2 (1 Major, 1 Minor)
- Declined: 0

### Round 2
- Findings received: 2 (both Minor)
- Fixed: 1 (Minor — doc report wording)
- Declined: 1 (Minor — see Declined)
- No Critical/Major findings → stopped early (no round 3).

## Fixed

1. **Major — `packages/foreman_server/lib/foreman_server_web/project_workspace_live.ex:561,568`**
   `memory_topics/1` and `library_entries/1` mapped `{:error, _}` to `[]`, so a
   genuine read failure (unknown project, absent path, IO error) was shown
   identically to an empty collection — a silent fallback masking a failure.
   Changed the error clause to return `:error`. `components.ex` now renders an
   "unavailable" state (`ws-error`) distinct from the empty state; the count
   span and list only render for a list (`is_list/1` guards); the `attr`s for
   `memory_topics`/`library_entries` are widened from `:list` to `:any`.
   (Note: a missing on-disk directory already returns `{:ok, []}` from both
   stores, so ordinary empty projects still show the empty state.)

2. **Minor — `packages/foreman_server/test/foreman_server_web/live/project_workspace_live_test.exs:1241`**
   `assert html =~ "Second PR"` also matched the Overview, so it would still
   pass if the Threads panel stopped rendering titles. Replaced with a scoped
   `has_element?/3` on `section[aria-labelledby="panel-threads-title"]
   ul.ws-panel-list li strong`, pinning the Threads-panel contract.

3. **Minor — `docs/reports/foreman-coord-e363648b60a1de0f/FIX_REPORT.md:7`** (round 2)
   The phase-1 summary described a read failure as producing `[]`. Updated it to
   state that a genuine read failure now returns `:error` and renders an
   "unavailable" state, so the committed report matches the current code.

## Declined

1. **Minor — `packages/foreman_server/lib/foreman_server_web/workspace/components.ex:80`**
   "Label the library count as entries" (rename heading to "Library entries").
   Declined: the panel is named **Library files** by the task spec and that
   heading is asserted by the test suite; renaming it would break the required
   panel label. The per-entry file counts are already shown next to each entry,
   and summing a total file count is out of this run's scope. No change.

## Verification

```
# narrowest affected test files, warnings-as-errors (DATABASE_URL/EVENTSTORE_URL unset)
devbox run -- bash -c 'cd packages/foreman_server && unset DATABASE_URL EVENTSTORE_URL && \
  MIX_ENV=test mix test --warnings-as-errors \
  test/foreman_server_web/live/project_workspace_live_test.exs \
  test/foreman_server_web/workspace/project_view_test.exs'
# => 54 passed, exit 0

devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted \
  lib/foreman_server_web/project_workspace_live.ex \
  lib/foreman_server_web/workspace/components.ex \
  test/foreman_server_web/live/project_workspace_live_test.exs'
# => exit 0
```

Doc gate: no externally visible identifiers added/removed/renamed (private
functions, internal component `attr` types, CSS classes, test only). No edits
needed to CLAUDE.md / README.md / docs/user-guide.md / docs/cli-reference.md.

Fixes left uncommitted for Foreman to commit.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
<!-- FOREMAN_REVIEW_FINDINGS_END -->
