# Handoff — Restyle the task list after gh-dash's PR list

Status: Implemented in `clients/cockpit/` · Date: 2026-07-10 · Owner: Leo D'Angelo
Audience: local coding agent (Go / Bubble Tea v2)
Related: `docs/design/cockpit-task-capabilities-handoff.md` (supersedes its left-column parts), `cockpit-ui-spec.md`, `cockpit-showcase-components-handoff.md`
Reference: gh-dash PR list (screenshot provided) — section tabs, filter line, rich two-line rows, wide list.

Implementation note (2026-07-11): the cockpit ships section tabs with live
counts, a filter/query line, configurable sections under `cockpit.taskList`,
field-token filtering including `attention:true`/`false`, `pr:<state>`,
`messages:<count>`, and ignored unknown field tokens, current/global scope
filtering over supplied project ids, two-line rich task/run rows with project
metadata in global scope and available right-side metadata columns, dash-like
wider list sizing on wide terminals,
mouse selection for section tabs and visible rows, and focused tests in
`task_list_test.go`, `view_test.go`, and `integrations_test.go`.

## 1. Objective

Make the cockpit's left task list read like gh-dash's PR list:

1. **Section tabs instead of a tree.** Replace the collapsible `RUNNING` /
   `READY` / `RECENT` groups with a top tab strip of sections (with counts),
   like dash's `My Pull Requests (4) | Needs My Review (0) | Involved (0)`.
2. **A filter/query line** under the tabs showing the active section's static
   configured filter plus the transient `/` search query.
3. **Richer rows** — two-line, columnar rows with more metadata around the task
   id (title, type, priority, phase/status, checks, diff, age), like dash's
   `repo/#num by @author` + bold title + columns.
4. **A wider list** at dash-like proportions.

The cockpit is now on Bubble Tea v2 / `bubbles/v2` (already in `go.mod`), so use
the v2 component set.

## 2. gh-dash → cockpit element mapping

| gh-dash element (screenshot) | Cockpit equivalent |
|---|---|
| Top section tabs `My PRs (4) | Needs Review (0) | Involved (0)` | task **section tabs** with counts: `Running (N) | Ready (N) | Failed (N) | Recent (N) | All` (configurable) |
| Query line `is:pr repo:… author:@me` | per-section **filter line** plus additive task-list search via `/` |
| Row line 1 `repo/foreman #301 by @ldangelo` + state icon | row line 1: `foreman-<id> · <type> · P<pri>` + state glyph (+ project when global) |
| Row line 2 bold title `[ESCALATED] test(prompts)…` | row line 2: **bold task title** |
| Columns: 💬 checks ● diff `+73.5k -215.8k` · ages `1h 1mo` | columns: msgs/events · checks/verdict glyph · PR dot · diff `±` (runs) · updated/created age |
| Selected-row dark band | selected-row band highlight (already have `cSelBg`) |
| Bottom bar `PRs · Issues · cockpit · PR 1/4` | status bar includes active section + selected position |
| Right detail pane (Overview/Activity/Commits/Checks/Files tabs) | existing right drill-down (`summary…pr`) — unchanged |

Note: this introduces **two independent tab strips** — task **sections**
(top-left) and run **drill-down** (right). Keep their keymaps distinct (§6).

## 3. Design decision & tradeoff (read before building)

The current tree shows `RUNNING`/`READY`/`RECENT` *simultaneously* — the spec's
"answer the first three questions at a glance." Section tabs show **one at a
time**, which is what gives each row the room to be dash-rich. That's the
tradeoff the user chose. Mitigate the lost overview by:

- Putting **counts in every tab label** (`Running 3 · Ready 5 · Failed 2 …`) so
  the fleet shape is always visible even while viewing one section.
- Keeping the roll-up counts in the status bar.

Fallback if the overview loss bites: a hybrid where an "All" (or "Overview")
section groups by state within one scrollable table. Ship tabs first.

## 4. Implemented code shape

- `task_list.go` owns section tabs, active-section index, section filters,
  current/global project scope, filtered items, selection identity, sticky
  headers, and keep-visible behavior.
- `view.go` renders the section tab strip, filter line, rich two-line rows, and
  dash-like wider left pane. Narrow terminals drop columns before wrapping.
- `model.go` routes section navigation, filter editing, scope toggling, and
  mouse hit-testing without `bubblezone`.
- `client.go` maps the row metadata used by the list: task title/type/priority,
  run title/status/phase, timestamps, messages/events counts, PR/check fields,
  verdict, diff totals, and dependency text.

## 5. Implemented sections and filters

- Default sections are `Running`, `Ready`, `Failed`, `Recent`, and `All`.
- Configured sections live under `.foreman/config.yaml`:

  ```yaml
  cockpit:
    taskList:
      sections:
        - name: Ready P0
          filter: state:ready priority:P0
  ```

- The filter grammar is intentionally small and closed for the shipped cockpit:
  `state:…`, `type:…`, `priority:P0`, `attention:true|false`, `pr:<state>`,
  `messages:<count>`, and bare text matched against id/title/rendered row text.
  Unknown field tokens are ignored gracefully.

## 6. Keymap

| Key | Action |
|-----|--------|
| `[` / `]` | previous / next **task section** |
| `/` | search/refine within the active section; configured section filters stay static |
| `↑`/`↓`, `j`/`k` | move selection within the section |
| `tab` / `shift+tab`, `1`–`8` | **drill-down** tabs on the right |
| `g` | scope current-project ↔ global |

`space` no longer collapses groups because the left pane is section-tabbed, not a
collapsible tree.

## 7. Data and API closure

- **Age columns** read `created_at` + `updated_at` from `Run`/`Task` projections
  when supplied; rows degrade to the available timestamp instead of fetching
  more data while rendering.
- **Messages/events/checks/PR/verdict/diff columns** are populated from
  `GET /api/v1/runs` fields (`messages_count`, `events_count`, `pr_state`,
  `pr_checks`, verdict, and added/removed diff totals).
- File metadata prefers the selected run worktree's `git diff --numstat` and
  `--name-status` against the projected base branch, then falls back to
  structured or legacy `/api/v1/runs/:run_id/debug` timeline `payload` /
  `file_changes` fields when no worktree diff is available.
- The shipped cockpit does not require a dedicated file-metadata endpoint. Such
  an endpoint would be optional API cleanup, not roadmap completion work.
- Aggregation happens in client mapping, not on the render path.

## 8. Relationship to the task-capabilities handoff

That handoff added rich task fields and creation. This handoff supersedes only
the old collapsible grouped-tree left column with section tabs + rich rows, and
reuses the detail view and add-task (`n`/`N`) flows unchanged.

## 9. Verification completed and closed non-goals

- Tests cover section filter predicates, counts per section, RECENT most-recent
  ordering and default cap, row renderer output, row glyph/status classification,
  two-line keep-visible math, task age formatting/fallbacks, current/global
  scope, mouse hit-testing for sections/actions/visible rows, configured
  sections, status-bar section position, and detail reloads when selection changes.
- README and `cockpit-ui-spec.md` document the section tabs, layout proportions,
  keymap, status bar, and two-strip model.
- No new backend endpoints were added; the read-only client architecture is
  preserved.

Sources: gh-dash ([gh-dash.dev](https://www.gh-dash.dev/), configurable
`prSections`), [bubbles v2](https://pkg.go.dev/charm.land/bubbles/v2),
[lipgloss v2](https://pkg.go.dev/charm.land/lipgloss/v2).
