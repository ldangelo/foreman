# Design — Kanban layout: tasks on top (board), activities on the bottom

Status: Proposed · Date: 2026-07-11 · Owner: Leo D'Angelo
Audience: local coding agent (Go / Bubble Tea v2) + Leo (decisions)
Related: `docs/design/cockpit-task-list-gh-dash-style-handoff.md` (section tabs — reworked here), `cockpit-focus-affordance-handoff.md` (top/bottom focus), `cockpit-ui-spec.md`
Proof point: `src/cli/super-tui/panes/BoardPane.ts` (existing Foreman Kanban board)

## 1. Objective

Refactor the cockpit from a **left/right** split (task list | details) to a
**top/bottom** split:

- **Top — task board (Kanban).** Tasks/runs rendered as cards in columns:
  **Backlog · Ready · In Progress · Blocked · Done**.
- **Bottom — activities.** The existing drill-down (summary / messages / events
  / logs / reports / files / pr) for the selected card.

Focus model is unchanged in spirit and reuses today's `m.viewFocused`: focus
starts on the **board**; `enter` on a card focuses **activities**; `esc` returns
to the board.

## 2. Proof point — this board already exists in Foreman

The Ink `super-tui` ships a working Kanban board over Foreman task data:
`src/cli/super-tui/panes/BoardPane.ts`. It proves the model is sound and gives us
a **validated state→column mapping** to port — we are not inventing it. Its
columns and `boardColumnForTaskStatus` map directly onto the requested five
(only two labels rename):

| This design's column | BoardPane column | Foreman statuses (from `boardColumnForTaskStatus`) |
|---|---|---|
| Backlog | `backlog` | `open`, `todo` |
| Ready | `ready` | `ready`, `pending` |
| In Progress | `in_progress` | `running`, `in_progress`, `cooldown` (+ live phase names: explorer/developer/qa/reviewer/finalize) |
| **Blocked** | `needs_attention` | `failed`, `stuck`, `conflict`, `blocked`, `review`, `test_failed` |
| **Done** | `closed` | `merged`, `completed`, `done`, `closed`, `reset`, `pr_created` |

Also port BoardPane's proven behaviors:

- **Attention override:** a card goes to **Blocked** if it has an attention
  reason or `verdict ∈ {fail, blocked}`, regardless of raw status
  (`boardColumn()` in the proof point). This is what makes "Blocked" mean "needs
  a human," matching the cockpit's `attention:` filter and the omp-triage flow.
- **Sort within a column** by last activity (most-recent first).
- **Selected-column highlight** + **per-card selection**, a **card cap** with a
  `… N more` overflow row, and a **compact mode** that shows only the selected
  column when space is tight.

Port `boardColumnForTaskStatus` + `boardColumn` to Go and reuse the cockpit's
existing status classifiers (`activeRunStatus`, `readyTaskStatus`,
`normalizeStatus` in `client.go`) so the board and the rest of the cockpit agree
on state. The one label choice to confirm: **Blocked** (this design) vs
BoardPane's **Needs Attention** — see §12.

## 3. Why this layout

- **Kanban restores the whole-fleet overview.** The just-shipped section tabs
  trade simultaneity for row width (one state at a time). Columns show **all
  states at once** again — the board *is* the overview the tabs gave up — while
  still giving each card room.
- **Top/bottom fits both jobs better than left/right.** Five columns want the
  **full terminal width**; and logs / diffs / reports / markdown read far better
  in a **full-width** bottom pane than in a ~55-col right column.
- **It's proven.** The mapping and interactions already shipped once (§2); this
  is a re-layout on top of validated semantics, not a green-field UX.

## 4. Layout & responsiveness

```
┌ foreman cockpit ─────────────────────────────────────────────────────────────┐
│ foreman  3 running · 5 ready · 2 blocked · 20 done     focus: board · ↻ live   │ status bar
├────────────┬────────────┬────────────┬────────────┬────────────────────────────┤
│ Backlog 12 │ Ready 5    │ In Prog 3  │ Blocked 2  │ Done 20                     │ board (top)
│ ─────────  │ ─────────  │ ─────────  │ ─────────  │ ─────────                   │  ~55% height
│ ▸foreman-… │ foreman-…  │ ●foreman-… │ ✗foreman-… │ ✓foreman-…                  │
│  fix auth  │  add tests │  developer │  conflict  │  merged #482                │
│  P1 · task │  P0 · task │  P1 4m12s  │  P2 finalize│ …17 more                   │
│  …9 more   │            │            │            │                             │
├────────────┴────────────┴────────────┴────────────┴────────────────────────────┤
│ foreman-a1b2c · developer · run …            [summary] messages 3  events 4  … │ activities
│ ─────────────────────────────────────────────────────────────────────────────  │  (bottom)
│ Implementing auth middleware…  worktree ~/.foreman/worktrees/foreman-a1b2c      │  ~45% height
│ ▸ open DEVELOPER_REPORT.md in nvim (action bar)                                 │
├────────────────────────────────────────────────────────────────────────────────┤
│ ←→/h l column  ↑↓/j k card  enter activities  esc board  a approve  n new  … q  │ keybar
└────────────────────────────────────────────────────────────────────────────────┘
```

- **Proportions:** board ~55% of body height, activities ~45%; configurable
  (`cockpit.layout.split`). Both regions full width.
- **Column width:** `bodyWidth / 5`. Cards are 2–3 compact lines each.
- **Responsive fallback (from the proof point):** below a width threshold
  (~5×18 cols), switch to **compact mode** — show only the focused column full
  width with `←/→` cycling columns — or fall back to the shipped **section-tab
  list** (recommended; it already exists). Pick one; see §12.
- **Vertical overflow:** each column scrolls independently (its own viewport)
  with a `… N more` affordance; selection keeps the focused card visible.

## 5. Column model

- Columns and mapping per §2 (port `boardColumnForTaskStatus` + attention
  override). Column header shows the label + live count
  (`Blocked 2`), colored by the theme's semantic token (Blocked = danger,
  In Progress = accent/green, Done = success/dim, etc.).
- **Ordering within a column:** last-activity desc by default (proof point);
  optionally priority-first for Backlog/Ready. Configurable.
- **Caps:** show N cards per column with `… N more`; the count in the header is
  always the true total. Done is capped hardest (it's history).
- **WIP hint (optional):** a soft per-column cap can render the count in warning
  color when exceeded (e.g., too many Blocked) — a nice "fleet health" signal.

## 6. Card design

Reuse the rich-row work (title/type/priority/glyph/age) as a compact **card**:

- Line 1: state glyph + `foreman-<id>` (+ project when global scope).
- Line 2: bold title (truncated to column width).
- Line 3 (space permitting): `P<pri> · <type>` or, for In Progress, `phase ·
  elapsed`; for Blocked, the attention reason (`conflict`, `ci_failed`).
- Selected card: full-width band within the column (`cSelBg`); selected column
  header highlighted (focus affordance).

## 7. Focus & navigation

Two focus regions — **board** (top) and **activities** (bottom) — reusing
`m.viewFocused` (board = false, activities = true; starts board). The focus
affordance handoff already highlights active / dims inactive; it applies
unchanged to top/bottom.

| Key | Board focused | Activities focused |
|-----|---------------|--------------------|
| `←`/`→` or `h`/`l` | move between columns | (pan logs, as today) |
| `↑`/`↓` or `j`/`k` | move card within column | scroll viewer |
| `enter` | focus activities for the selected card | — |
| `esc` | — | back to board |
| `tab`/`shift+tab`, `1`–`8` | — | drill-down tabs (unchanged) |
| `g` | scope current-project ↔ global | — |

Selecting a card (arrow/click) drives the bottom activities immediately (same
`loadDetail` path as selecting a row today). Card actions carry over unchanged:
`a` approve, `e` edit, `n`/`N` new, `y` copy, `r`/`R` retry/reset, `p`/`P` omp.

## 8. Actions & state transitions (read-model board)

The board reflects backend state; the cockpit stays a **read-only projection
client**. Cards therefore **don't drag freely** between columns — a card moves
when a backend action changes its state:

- `a` approve → task leaves Ready, appears in In Progress once dispatched.
- `r` retry / `R` reset → moves out of Blocked.
- backend block/failure → moves into Blocked (attention override).

v1 is **action-driven** relocation (no arbitrary drag). A future enhancement
could map explicit drag/move gestures to task commands (e.g. block/unblock), but
only where a real backend transition exists — flagged, not built.

## 9. What's reused vs reworked

Reworked (arrangement only): the left/right split becomes top/bottom; the
section-tab list becomes columns (or the narrow-terminal fallback).

Reused as-is:

- Card rendering ← the two-line rich rows.
- State classification ← `activeRunStatus`/`readyTaskStatus` + the ported
  `boardColumnForTaskStatus`.
- Filter grammar + current/global **scope** ← task list (a global filter still
  narrows every column).
- Per-column scroll/selection ← the viewport/keep-visible infra.
- Bottom activities ← the existing drill-down viewer + tabs, verbatim.
- Focus affordance, theme tokens, mock data, client mapping ← unchanged.

Section tabs: subsumed by columns (columns == states). Keep the section-tab list
as the **narrow-terminal fallback** and/or a `layout.mode: list` option so no
shipped work is wasted.

## 10. Components & rendering

- Board = `lipgloss.JoinHorizontal` of N column blocks; each column is a
  `robinovitch61/viewport` (or the cockpit viewer) for independent vertical
  scroll + selection + `… N more`.
- Body = `JoinVertical(statusBar, board, activities, keybar)`; board/activities
  heights from `layout.split`.
- Clicks: native hit-testing in `handleMouse` (as the focus/gh-dash work already
  does — no `bubblezone`): map (x,y) → column + card, or into the activities
  pane, and set selection/focus accordingly.

## 11. Data

No new backend data. Columns are derived client-side from the same `Run`/`Task`
projections already fetched; header counts are true totals. Aggregation stays in
client mapping, off the render path (as today).

## 12. Decisions to confirm

1. **Column label:** "Blocked" (requested) vs the proof point's "Needs
   Attention." Recommend **Blocked** per your ask; keep the attention override
   semantics. Confirm whether `failed`/`stuck`/`conflict` all read as "Blocked"
   (recommended) or whether you want a separate Failed column (would make six).
2. **Board vs list:** board as the primary view with the section-tab list as the
   narrow-terminal fallback (recommended), or a user toggle `layout.mode:
   board | list | auto`.
3. **Narrow-terminal behavior:** compact single-column board (proof-point style)
   vs falling back to the section-tab list. Recommend the **list fallback**
   (already shipped, less code).
4. **Drag-to-move:** action-driven only in v1 (recommended), or invest in
   drag→command mapping now.

## 13. Config

```yaml
cockpit:
  layout:
    mode: board          # board | list | auto (auto = board wide, list narrow)
    split: 0.55          # board height fraction
    narrowThreshold: 100 # cols below which auto uses the list
  board:
    columns:             # optional override; defaults ported from BoardPane
      - {name: Backlog,     statuses: [open, todo]}
      - {name: Ready,       statuses: [ready, pending]}
      - {name: In Progress, statuses: [running, in_progress, cooldown]}
      - {name: Blocked,     statuses: [failed, stuck, conflict, blocked, test_failed], attention: true}
      - {name: Done,        statuses: [merged, completed, closed, reset, pr_created]}
    cardCap: 12          # cards shown per column before "… N more"
    order: activity      # activity | priority
```

## 14. Acceptance

- Startup shows the board (focus: board) with all five columns and true counts;
  attention/failed cards land in Blocked.
- `←/→` move columns, `↑/↓` move cards, `enter` focuses activities for the
  selected card, `esc` returns; focus highlight/dim tracks top/bottom.
- Selecting a card updates the bottom activities (same data as today).
- Columns scroll independently with `… N more`; global scope + filter narrow all
  columns.
- Narrow terminals degrade per §12.3 without breaking layout.
- `go build/test/vet ./...` clean.

## 15. Testing

- Port + unit-test the `boardColumnForTaskStatus` mapping and the attention
  override against the proof point's cases (table-driven; include
  `failed`/`stuck`/`conflict`/`blocked` → Blocked and `merged`/`completed` →
  Done).
- Column bucketing + counts + ordering; per-column keep-visible; card renderer
  output within column width; responsive fallback selection; mouse hit-testing
  (column+card).
- Snapshot via `COCKPIT_DUMP` for board and activities focus states.

## 16. Non-goals & risks

- No backend changes; read-only projection client preserved.
- Risk: five columns on narrow terminals — mitigated by §12.3 fallback.
- Risk: reworking freshly-shipped section tabs — mitigated by keeping the list as
  a fallback/mode, and by reusing rows/filter/scope/viewer/focus rather than
  rewriting them.
- Risk: column/state drift vs backend — mitigated by porting the proof point's
  mapping and reusing the shared status classifiers.

## 17. Sequencing

1. Port `boardColumnForTaskStatus` + attention override to Go (+ tests) — the
   proof-point core, independent of layout.
2. Top/bottom frame + `layout.split`; move activities to the bottom (reuse the
   drill-down verbatim).
3. Board render: columns via `JoinHorizontal`, per-column viewport, cards from
   the rich-row renderer, counts + `… N more`.
4. Board navigation (`←/→`/`h l`, `↑/↓`/`j k`, enter/esc) + focus affordance on
   top/bottom + card actions.
5. Responsive fallback (compact column or list) + config.
6. Mouse hit-testing for columns/cards.
7. Docs sweep (README, `cockpit-ui-spec.md`); note section tabs → columns/list.

Source of the mapping and behaviors: `src/cli/super-tui/panes/BoardPane.ts`.
