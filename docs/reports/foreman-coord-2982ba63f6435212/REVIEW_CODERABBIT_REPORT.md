# CodeRabbit Review Report — coord-2982ba63f6435212 / run-f9e7ac6b6c65fb226c0067fc60641ee6

Progress tools `foreman_inbox_send` and `foreman_task_add_comment` were not
available in this phase ("Tool ... not found"); phase continued without
operator-facing progress notes.

## Review engine

Command (run once, from the worktree root):

```
coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"   # $FOREMAN_BASE_BRANCH=main
```

Exit: completed, `{"type":"complete","status":"review_completed","findings":10}`.

## Rounds

- **Round 1** — 10 findings received; 7 fixed, 3 declined. No `Critical`/`Major`
  finding remained after the fixes, so review stopped early (no round 2/3).

Severity mix: 1 minor + several trivial across `components.ex`, `layouts.ex`,
and the live test.

## Fixed

1. **`packages/foreman_server/lib/foreman_server_web/workspace/components.ex:283`** (trivial)
   — `thread_chip/1` used `Map.get(@group_chip_kind, group, "muted")`, a silent
   default. `group_title(group)` (evaluated first in the same tuple) already
   uses `Map.fetch!/2` and raises for an unknown group, so the default was dead
   and only misleading. Changed to `Map.fetch!(@group_chip_kind, group)` so the
   two parallel tables fail loudly together (§5.5).

2. **`.../workspace/components.ex:486-497`** (trivial) — `sender_label/1` and
   `message_variant/1` had disagreeing catch-alls (unknown/`nil` role → label
   "Foreman"/"Admin" but variant `coordinator`), the "plausible-looking success"
   shape AGENTS §5.2 forbids. The coordinator conversation role vocabulary is
   closed to `operator`/`coordinator`/`system` (producers in
   `aggregates/coordinator.ex`, `executor.ex`, `turn_runner.ex`, `reporter.ex`,
   `setup_proposer.ex`). Removed both catch-alls and the `String.capitalize`
   clause; added the explicit `message_variant("coordinator")` clause. Narrowed
   `@spec sender_label(String.t())` (was `String.t() | nil`). An unknown role
   now raises `FunctionClauseError` instead of a wrong attribution.

3. **`.../workspace/components.ex:535-536`** (minor) — removed
   `defp coordinator_chip(_), do: {"idle", "muted"}`. `@status` is always the
   status map (the template dereferences `@status["consecutive_failures"]` and
   `@status["status"]` directly), always carrying a binary `"status"`, so the
   `is_binary` clause is total. The fallback fabricated a healthy-looking "idle"
   chip and hid the Restart control (`@status["status"] == "unhealthy"`) for a
   malformed status; now a malformed status crashes instead of lying (§5.3).

4. **`.../workspace/layouts.ex:117`** (minor) — removed `white-space: pre-wrap`
   from `.msg` (the `<article>` wrapper). HEEx leaves whitespace-only text nodes
   between the wrapper's block children; under `pre-wrap` those render as blank
   lines / extra padding inside operator bubbles. The message text keeps
   `pre-wrap` via `.msg-text` on the element that actually holds it.

5. **`.../workspace/layouts.ex:118`** (minor) — added
   `.ws-msg { white-space: pre-wrap; overflow-wrap: anywhere; margin: 0 0 8px; }`.
   `ws-msg` is applied to the instructions and question text (components.ex:80,
   83, 310) but had no CSS rule, so newlines collapsed to single spaces and
   multi-line instructions rendered run-on under `ws-clamp-8`.

6. **`.../workspace/layouts.ex:91`** (minor) — capped the sticky sidebar:
   `.ws-side` gains `max-height: calc(100vh - 32px); overflow-y: auto`, with
   `max-height: none; overflow-y: visible` restored in the `max-width: 999px`
   (static) branch. Without a cap, a sidebar taller than the viewport kept its
   lower controls below the fold while the conversation scrolled.

7. **`packages/foreman_server/test/foreman_server_web/live/project_workspace_live_test.exs:1270`**
   (trivial) — the "long instructions keep their full text" test only checked
   `html =~ "SENTINEL_TAIL"`, which the clamped `<p>` satisfies even if the
   reveal is broken. Added `has_element?(view, "details.ws-showall > summary",
   "Show all")` and `has_element?(view, "details.ws-showall", "SENTINEL_TAIL")`
   to pin the Show-all reveal contract.

## Declined

- **`.../workspace/layouts.ex:32`** (minor) — "light-theme `--accent` `#c15f3c`
  fails WCAG AA (~4.0:1 link / ~4.2:1 button)". Declined: the operator spec
  pins this exact token (`--accent #c15f3c` for light) and says "do not
  improvise colours or sizes" / "follow the tokens … LITERALLY". Changing it
  would override a dictated value. Per the spec's conflict rule, the token is
  kept and the contrast conflict is surfaced here and in the unresolved block
  for the operator to decide.

- **`.../workspace/components.ex:80-84`** (minor) — "Show all reveal duplicates
  the instructions text (clamped `<p>` + full `<p>` both in DOM)". Declined: the
  spec (§4) mandates exactly this structure — a clamped 8-line preview plus a
  `Show all` `<details>` whose full text "must remain in the DOM". Hiding the
  preview on `[open]` would require a `:has()`/sibling CSS rule beyond the spec
  and risks browser inconsistency. Kept the spec'd behaviour; noted below.

- **`.../test/.../project_workspace_live_test.exs:708-730`** (trivial) — "add
  direct unit tests for `message_time/1`, `sender_label/1`, and the system
  collapse thresholds". Declined as additive coverage rather than defect
  remediation: the section-7 consumer-visible contracts (no raw ISO stamp, no
  "via system", composer in the transcript card, empty states, controls present)
  are already tested, and this phase's mandate is to fix defects CodeRabbit
  finds, not expand the suite.

## Verification

Run via devbox (Elixir 1.20.4 / OTP 28), `DATABASE_URL`/`EVENTSTORE_URL` unset
so the test config defaults to the foreman Postgres.

| Command | Exit |
| --- | --- |
| `mix format --check-formatted` (3 edited source/test files) | 0 (clean) |
| `MIX_ENV=test mix test --warnings-as-errors test/foreman_server_web/live/project_workspace_live_test.exs test/foreman_server_web/live/project_workspace_coordinator_live_test.exs` | 0 — **54 passed** |

Doc gate: no externally visible identifiers (routes, config keys, env vars, CLI
verbs, events, MCP tools) added/removed/renamed. `sender_label/1` and
`message_time/1` remain public with unchanged names; `sender_label/1`'s spec
narrowed from `String.t() | nil` to `String.t()` (no operator-visible surface).
No `CLAUDE.md`/`README.md`/`docs/user-guide.md`/`docs/cli-reference.md` edit
needed. No files under `.beads/` touched. Fixes left uncommitted for Foreman.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
- `packages/foreman_server/lib/foreman_server_web/workspace/layouts.ex:32` Minor — light-theme `--accent` `#c15f3c` is ~4.0:1 (link) / ~4.2:1 (button), below WCAG AA 4.5:1; kept because the operator spec pins the token, operator to decide whether to darken it.
- `packages/foreman_server/lib/foreman_server_web/workspace/components.ex:80-84` Minor — the clamped instructions preview and the Show-all `<details>` both hold the full text, so an opened reveal shows the text twice; kept per spec §4 (full text must remain in DOM), operator to decide if the preview should hide on open.
<!-- FOREMAN_REVIEW_FINDINGS_END -->
