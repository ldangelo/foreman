# Repo-rules review — run-30ab70c9019bd2df980642a0c395e65f

## Review engine

Repository-rules reviewer: this phase (inline pass over the diff, rules taken from `AGENTS.md`
§Typed Boundaries / §Documentation Gate / §Invariants and `docs/lessons/typed-boundaries-full.md`).
No external reviewer CLI is used here.

Diff range reviewed: `git diff main...HEAD` (`$FOREMAN_BASE_BRANCH` = `main`), branch
`foreman/adhoc-4f35b3c7/run-30ab70c9019bd2df980642a0c395e65f`, 5 files, 450 insertions / 83
deletions:

- `packages/foreman_server/lib/foreman_server_web/operator_run_dashboard_live.ex`
- `packages/foreman_server/lib/foreman_server_web/workspace/layouts.ex`
- `packages/foreman_server/test/foreman_server_web/operator_run_dashboard_ui_test.exs`
- `docs/reports/foreman-adhoc-4f35b3c7/FIX_REPORT.md`, `docs/reports/foreman-adhoc-4f35b3c7/REVIEW_CODERABBIT_REPORT.md`

Previous phase's file: `docs/reports/foreman-adhoc-4f35b3c7/REVIEW_CODERABBIT_REPORT.md` **is
present but empty** (57 bytes, the placeholder written by the phase wrapper). It contains **no
`FOREMAN_REVIEW_FINDINGS_START` / `FOREMAN_REVIEW_FINDINGS_END` block**, so there were no CodeRabbit
findings to carry forward. The findings below are this phase's own.

## Findings

Nine findings were raised against the diff; all nine were triaged against the code as it now stands.
Six were fixed (F1–F6), two were fixed by the same edit (F7 is the regression guard for F1) and one
was declined (F8, F9 informational).

- F1 `operator_run_dashboard_live.ex:658` — `chip_kind/1` resolves through `Map.get/3`, so any run
  status outside the 11 keys of `@chip_kinds` renders a **muted** chip. Fixed.
- F2 `operator_run_dashboard_live.ex:488-492` — `entry_kind/1` has a `_` catch-all mapping unknown
  log channels to `msg--system`. Fixed.
- F3 `operator_run_dashboard_live.ex:555-560` — `change_kind/1` has a `_` catch-all and a table
  duplicate of `ChangeEvidence.live_status?/1`. Fixed.
- F4 `operator_run_dashboard_live.ex:26-42` — `@chip_kinds` is a fourth, partial copy of the run
  status vocabulary (the other three are `aggregates/run.ex`, `operator_dashboard.ex:158-170`
  `actions_for_status/1`, `overview/group.ex:117-120` and `coordinator/context.ex:138`), and it
  omits `needs_recovery`, the state `actions_for_status/1` itself treats as stoppable and
  resettable. Fixed (loud version, see F1).
- F5 `operator_run_dashboard_live.ex:164` — the filter form lost its Refresh button (moved to the
  header at `:151`), and the form's native Enter submit silently dropped `run_id`, `tab` and `file`
  from the URL, losing the operator's selection. Fixed.
- F6 `operator_run_dashboard_live.ex:634` — `describe/1` falls back to `inspect/1`, which re-leaks
  tuples as terms; `:155` renders `Error: {describe(@error)}` over an `{run_id, reason}` tuple.
  Fixed.
- F7 `operator_run_dashboard_ui_test.exs:157-160` — the `styled_classes/0` parser treats
  `[role="…"]` attribute selectors as class rules (it matches the `.md` in `role="run.md"`-shaped
  strings), so the test asserting "every class the page emits is styled" passes for classes that
  have no rule. Fixed by stripping attribute selectors first, then enumerating the dashboard's
  dynamic `chip--*` classes from `@chip_kinds` instead of a hardcoded suffix list (F1 would have
  been invisible to this test as written).
- F8 — "document the restyled dashboard in `docs/user-guide.md`". Declined: no externally visible
  identifier was added, removed or renamed (see Documentation gate below); the sections that
  describe `/dashboard/runs` (`:1348-1380`, `:2576`) still describe the shipped behavior.
- F9 — "`ws-nav-*` / `thread-earlier` classes in the workspace have no CSS rule either". Declined:
  pre-existing in files this run does not touch, and out of scope; noted here only so the
  observation is not lost.

## Fixed

| File | What was wrong | What changed |
| --- | --- | --- |
| `packages/foreman_server/lib/foreman_server_web/operator_run_dashboard_live.ex` | `chip_kind/1` silently downgraded an unrecognised run/phase status to muted (`Map.get/3` default), so a new projection status would look like a settled/idle run. §5.2/§5.3: absence must not degrade to a plausible-looking success. | Split into `run_chip_kind/1` and `phase_chip_kind/1`, each a head for every status in its own closed vocabulary plus a final clause that `raise`s naming the status and pointing at the map that needs the new key. `@chip_kinds` is now an ordered keyword list with `run:` / `phase:` groups, documented with the three other places the vocabulary lives. `needs_recovery` → `warn` and `unresponsive` → `err` added, because `operator_dashboard.ex:163,168` and `overview/group.ex:117` already treat them as live run statuses. 12 rendering sites switched to the right function. |
| `packages/foreman_server/lib/foreman_server_web/operator_run_dashboard_live.ex` | `entry_kind/1` mapped any unknown log channel to `msg--system` with a `_` clause — §5.2 again. | Heads for `stderr`/`system`/`operator`/`agent` plus a raising fallthrough. |
| `packages/foreman_server/lib/foreman_server_web/operator_dashboard.ex` | The dashboard would have had to keep its own copy of the `git status --porcelain` letter vocabulary (§5.7 duplicate boundary). | Added `ForemanServerWeb.OperatorDashboard.ChangeEvidence.status_class/1`, next to the existing `live_status?/1` that already matches the same letters, returning the shared chip modifier; unknown letter → `:unknown`. |
| `packages/foreman_server/lib/foreman_server_web/operator_run_dashboard_live.ex` | `change_kind/1` duplicated that letter vocabulary in the view. | Deleted; the view interpolates `ChangeEvidence.status_class(file.status)` directly (a `nil` interpolation drops the surrounding markup, which is exactly the trap the `render_meta/1` comment warns about, so the map result is not carried into a HEEx expression). |
| `packages/foreman_server/lib/foreman_server_web/operator_run_dashboard_live.ex` | `describe/1`'s last clause `inspect(value)` re-introduced the term leak the phase was meant to fix: `Error: {describe(@error)}` rendered `Error: {:run_not_found, …}`-shaped tuples for the `{run_id, reason}` detail error. | Tuple clause now reads `"tag (rest inspected)"`; the raising status paths never reach `describe/1` at all. |
| `packages/foreman_server/lib/foreman_server_web/operator_run_dashboard_live.ex` | The filter form (`phx-submit="filter"`) submits to the current URL, so pressing Enter in a field dropped `run_id`/`tab`/`file` and the selected run vanished from the page. The header Refresh button was also far from the fields being edited. | The form's submit button is now `type="button" phx-click="filter"` (an explicit click carries the form's fields and preserves the URL, as `refresh` at `:151` already does), and a matching in-form Refresh was added. Both are labelled `aria-label="Apply filters"` / `aria-label="Refresh run list"` so the two buttons are distinguishable to a screen reader. |
| `packages/foreman_server/test/foreman_server_web/operator_run_dashboard_ui_test.exs` | `styled_classes/0` counted `[role="…"]` attribute selectors as class rules, and `emitted_classes/0` hardcoded `~w(ok info warn err muted)` suffixes, so a chip class produced by an unmapped status could never be caught. | Strip `[...]` selectors before scanning for `.name` rules; enumerate dynamic chip classes by reading `@chip_kinds` itself (keys for `chip--`, values for both `chip--` and `thread-dot--`). |

No other file changed. `layouts.ex` needed no change: the only modifier the new code can emit that
wasn't already there was `.thread-dot--muted`, added in phase 1.

## Declined

| File | Finding | Reason |
| --- | --- | --- |
| `docs/user-guide.md` | "Restyle of the run dashboard is undocumented." | No externally visible identifier added/removed/renamed; the documented behavior (deep links, tabs, run controls, stale marking, `#main` skip link sharing the workspace root layout) is unchanged. UI restyle to match an existing shell is not a doc event under the documentation gate. |
| `packages/foreman_server/lib/foreman_server_web/workspace/components.ex` | "`ws-nav-run`, `ws-nav-branch`, `ws-nav-workflow`, `ws-nav-pr`, `ws-nav-trd`, `ws-nav-docs`, `ws-nav-conversation`, `ws-nav-worktree`, `ws-add-files`, `ws-showall`, `thread-earlier` have no rule in `layouts.ex`." | Same class of defect this run fixed in the dashboard, but it is pre-existing on lines this run does not touch (§Surgical changes). Carried as an unresolved finding below rather than silently expanded into. |
| `docs/TRD/TRD-2026-c7977e9d-operator-run-dashboard.md`, `docs/PRD/PRD-2026-c7977e9d-operator-run-dashboard.md` | "Still name the removed classes `.operator-run-dashboard`, `.dashboard-layout`, `.focus-marker`." | `AGENTS.md`: PRD/TRD are point-in-time specs — leave the claims as written. `operator_run_dashboard_ui_test.exs:6-10` already carries the reconciliation note in the file that enforces the new vocabulary. |
| `packages/foreman_server/lib/foreman_server_web/live_dashboard.ex:62,64` | "`/dashboard` still uses `jido-live-dashboard` / `dashboard-meta`, classes with no rule." | Explicitly out of this brief ("Existing Jido dashboard remains at `/dashboard`", `operator_run_dashboard_live.ex:147`); a second page's restyle is not this run's scope. Unresolved finding below. |

## Verification

| Command | Exit |
| --- | --- |
| `devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix compile --warnings-as-errors'` | 0 (no warnings) |
| `devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test test/foreman_server_web/operator_run_dashboard_ui_test.exs test/foreman_server_web/operator_run_dashboard_live_test.exs test/foreman_server_web/operator_dashboard_test.exs --warnings-as-errors'` | 0 — **49 tests, 0 failures** |
| `devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted lib/foreman_server_web/operator_run_dashboard_live.ex lib/foreman_server_web/operator_dashboard.ex lib/foreman_server_web/workspace/layouts.ex test/foreman_server_web/operator_run_dashboard_ui_test.exs'` | 0 |
| `git diff main...HEAD` re-read after fixes | new violations: none. Re-running the parity test's own emitted-vs-styled check over the fixed source reports no unstyled class emitted by the dashboard. |

Full suite was not run: AGENTS.md asks for the narrowest affected tests, and phase 1 already ran it
(6905/6907; the 2 red are `config_test.exs:73/:87` asserting `DATABASE_URL =~ "localhost"` against
this worktree's `127.0.0.1:55432/foreman_test`, identical before and after this diff).

**Documentation gate.** Identifiers this diff touches: no routes, no config keys, no env vars, no
CLI verbs, no MCP tools, no command/event types. Class names removed by phase 1
(`operator-run-dashboard`, `dashboard-layout`, `run-list`, `run-detail`, `focus-marker`,
`dashboard-stale`, `dashboard-error`, `dashboard-action-result`, `dashboard-detail-error`) were
never documented as CSS — grep of `CLAUDE.md`, `README.md`, `docs/user-guide.md`,
`docs/cli-reference.md` for them hits only `docs/PRD/*` and `docs/TRD/*` (point-in-time specs, left
as written per AGENTS.md). `docs/user-guide.md` needed no edit (no operator-visible behavior
change); `docs/cli-reference.md` no change (no CLI surface); `README.md`/`CLAUDE.md` no change.
`docs/lessons/claude-projects-architecture.md` describes the workspace pages, not this run's diff.

**Status-tool note:** `foreman_inbox_send` and `foreman_task_add_comment` are not exposed to this
phase, so the progress milestones could not be posted; `ask_advisor` also fails in this environment
(`Advisor model not found: openai-codex/gpt-5.5`), so the advisor gate could not be run.

Fixes are left uncommitted for Foreman to commit, as instructed.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
- `packages/foreman_server/lib/foreman_server_web/workspace/components.ex:431,512` Minor — the workspace nav rows emit `class="ws-nav-run"` (and `ws-nav-branch`/`ws-nav-worktree`/`ws-nav-pr`/`ws-nav-trd`/`ws-nav-docs`/`ws-nav-conversation`, plus `ws-add-files`, `ws-showall`, `thread-earlier`) with no matching rule in `workspace/layouts.ex`, the same dead-class defect this run fixed in the run dashboard; unstyled because `NavRuns`/`nav_runs.ex:11` also documents a `starting`/`running` run status that `chip_kind` now raises on if a projection ever emits it.
- `packages/foreman_server/lib/foreman_server_web/live_dashboard.ex:62` Minor — `/dashboard` (and `/admin`) still rest on `jido-live-dashboard` / `dashboard-meta`, classes no stylesheet defines, so that page remains unstyled while `/dashboard/runs` is now on the shared shell; out of this run's brief and needs its own pass.
<!-- FOREMAN_REVIEW_FINDINGS_END -->
