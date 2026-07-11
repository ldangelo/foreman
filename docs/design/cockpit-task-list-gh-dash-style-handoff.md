# Handoff — Restyle the task list after gh-dash's PR list

Status: Implemented in `clients/cockpit/` · Date: 2026-07-10 · Owner: Leo D'Angelo
Audience: local coding agent (Go / Bubble Tea v2)
Related: `docs/design/cockpit-task-capabilities-handoff.md` (supersedes its left-column parts), `cockpit-ui-spec.md`, `cockpit-showcase-components-handoff.md`
Reference: gh-dash PR list (screenshot provided) — section tabs, filter line, rich two-line rows, wide list.

Implementation note (2026-07-11): the cockpit ships section tabs with live
counts, a filter/query line, configurable sections under `cockpit.taskList`,
field-token filtering, current/global scope filtering over supplied project ids,
two-line rich task/run rows with project metadata in global scope, dash-like
wider list sizing on wide terminals, mouse selection for section tabs and
visible rows, and focused tests in `task_list_test.go`, `view_test.go`, and
`integrations_test.go`.

## 1. Objective

Make the cockpit's left task list read like gh-dash's PR list:

1. **Section tabs instead of a tree.** Replace the collapsible `RUNNING` /
   `READY` / `RECENT` groups with a top tab strip of sections (with counts),
   like dash's `My Pull Requests (4) | Needs My Review (0) | Involved (0)`.
2. **A filter/query line** under the tabs showing the active section's filter,
   editable like dash's `is:pr repo:… is:open author:@me`.
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
| Query line `is:pr repo:… author:@me` | per-section **filter line** (editable via `/`) |
| Row line 1 `repo/foreman #301 by @ldangelo` + state icon | row line 1: `foreman-<id> · <type> · P<pri>` + state glyph (+ project when global) |
| Row line 2 bold title `[ESCALATED] test(prompts)…` | row line 2: **bold task title** |
| Columns: 💬 checks ● diff `+73.5k -215.8k` · ages `1h 1mo` | columns: msgs/events · checks/verdict glyph · PR dot · diff `±` (runs) · updated/created age |
| Selected-row dark band | selected-row band highlight (already have `cSelBg`) |
| Bottom bar `PRs · Issues · cockpit · PR 1/4` | existing status bar (extend with section + position) |
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

## 4. What changes in the code

- `task_list.go` (`TaskList`) — today owns grouped rows + `collapsed` + `scope` +
  search + `keepSelectedVisible`. Replace grouping with **sections**: a section
  list, an active-section index, per-section filter, and filtered items for the
  active section only. Keep selection + keep-visible + scope.
- `view.go` `renderLeft`/`renderRow` — replace the grouped tree render with a
  **section tab strip + filter line + rich table rows**. Widen `leftW`.
- `model.go` `handleKey` — add section navigation; repurpose `/` to edit the
  active section's filter; retire `space` (collapse group) for the list.
- `client.go` `Run`/`Task` — ensure the columns' data exists (title, type,
  priority already added; verify timestamps + diff stat + checks, §7).

## 5. Workstreams

Follow the repo TDD rule. Each is shippable on its own.

### A. Section tabs (replace the tree)
- Define default sections, each a filter over the merged run/task set:
  `Running` (active runs), `Ready` (dispatchable/ready tasks), `Failed`
  (failed/stuck/conflict + verdict=fail), `Recent` (terminal runs), `All`.
- Render a tab strip above the list (reuse the right-pane tab rendering style)
  with **counts** per section. Active tab highlighted with the theme accent.
- Config: `.foreman/config.yaml` `taskSections:` — an ordered list of
  `{name, filter}` mirroring gh-dash's `prSections`, so sections are
  user-definable; ship the defaults above when unset.
- Acceptance: tabs switch the visible list; counts are correct and live; the
  default section is `Running`.

### B. Filter / query line
- Under the tabs, show the active section's filter (e.g. `state:running`), and
  make `/` open a `bubbles/v2 textinput` to edit it, applying on `enter`,
  clearing on `esc` — matching dash's query line.
- Filter grammar (start minimal, extend later): space-separated terms —
  `state:…`, `type:…`, `priority:P0`, `attention:true`, plus bare text matched
  against id/title. Keep it a pure, unit-tested predicate function.
- Acceptance: editing the filter narrows the current section live; invalid terms
  are ignored gracefully; `esc` restores the section default.

### C. Rich two-line / columnar rows
- Row line 1: state glyph + `foreman-<id>` + `· <type>` + `· P<pri>` (+ project
  when scope is global). Line 2: bold title (truncate with `…`).
- Right-aligned columns (show what the row has): msgs/events count, checks /
  verdict glyph, PR state dot, diff `+add -del` (runs with a worktree), and age
  columns (updated, created) formatted like dash (`1h`, `2w`, `1mo`).
- Rendering: prefer a custom two-line row renderer with `lipgloss/v2` for the
  dash look; use `bubbles/v2 table` only if you drop to single-line rows. Reuse
  `reflow`-correct truncation (see showcase handoff) so wide glyphs don't break
  columns.
- Selected row: full-width band (`cSelBg`), matching dash.
- Acceptance: rows show id+type+priority+title plus the columns; long titles
  truncate; columns align; the selected band spans the row width.

### D. Wider, dash-like layout
- Give the list the dominant share: `leftW ≈ 58%` of total width (dash-like),
  clamped to keep the right pane usable (`min rightW ≈ 48`), configurable via
  `taskList.width` (`auto` | fixed | percent). Two-line rows mean the viewport
  windowing must count 2 lines per row — update the keep-visible math.
- Acceptance: the list is visibly the primary region; the detail pane stays
  usable; narrow terminals degrade (drop columns, then shorten title).

### E. (Optional) clickable tabs & rows (`bubblezone`)
- Per the showcase handoff, wrap section tabs and rows in zones so a click
  selects/activates them (dash is mouse-friendly). Verify `bubblezone` v2 first.

## 6. Keymap (reconcile the two tab strips)

| Key | Action |
|-----|--------|
| `[` / `]` (or `H` / `L`) | previous / next **task section** |
| `/` | edit the active section's **filter** |
| `↑`/`↓`, `j`/`k` | move selection within the section |
| `tab` / `shift+tab`, `1`–`7` | **drill-down** tabs on the right (unchanged) |
| `g` | scope current-project ↔ global (unchanged) |

Retire `space` (collapse group) for the list. Update `?` help, the keybar, and
`cockpit-ui-spec.md` to show section nav and the two-strip model.

## 7. Data the columns need (verify; flag gaps)

- **Age columns** need `created_at` + `updated_at` on `Run`/`Task`. `Run.Last`
  (updated) exists; confirm a created timestamp is available from
  `GET /api/v1/runs` / `/tasks`, else show one age.
- **Diff `±`** needs aggregate added/removed lines per run — `httpClient.Files`
  is currently empty (see caveats); until a file/diff endpoint exists, omit the
  diff column for live data (mock can show it). Flag as a backend follow-up.
- **Checks / verdict** reuse the `pr` tab data and run verdict.
- Do the aggregation in the client mapping, not on the render path.

## 8. Relationship to the task-capabilities handoff

That handoff already added `title`/`type`/`priority` to rows and the full task
detail view. This handoff **supersedes its "collapsible grouped tree" left
column** with section tabs + rich rows, and reuses its detail view and add-task
(`n`) flow unchanged. Don't re-litigate the detail pane here.

## 9. Testing, docs, non-goals

- Tests: section filter predicate (table-driven), counts per section, row
  renderer output (id/type/pri/title + columns within `leftW`), two-line
  keep-visible math, age formatting. `go build/test/vet ./...` clean.
- Docs: README (Keys, "What it shows"), `cockpit-ui-spec.md` (left column →
  section tabs, layout proportions, keymap, two-strip model).
- Non-goals: no change to the right drill-down; no new backend endpoints beyond
  confirming timestamps/diff availability; keep the read-only-client architecture.

## 10. Sequencing

1. Section model + tabs with counts (A) — replaces the tree; biggest structural
   change, do first.
2. Rich two-line/columnar rows (C) + wider layout (D).
3. Filter line (B).
4. Optional clickable tabs/rows (E).
5. Docs sweep.

Sources: gh-dash ([gh-dash.dev](https://www.gh-dash.dev/), configurable
`prSections`), [bubbles v2](https://pkg.go.dev/charm.land/bubbles/v2),
[lipgloss v2](https://pkg.go.dev/charm.land/lipgloss/v2).
