# Handoff — Migrate the cockpit to Bubble Tea v2 and adopt `robinovitch61/viewport`

Status: WS1–WS6 complete · Date: 2026-07-10 · Owner: Leo D'Angelo
Audience: local coding agent (Go / Bubble Tea)
Subject: [`github.com/robinovitch61/viewport`](https://github.com/robinovitch61/viewport)
Related: `clients/cockpit/viewer.go`, `view.go`, `task_list.go`, `model.go`, `styles.go`, `theme/gen.go`

## 1. Objective & decision

Replace the cockpit's three viewport-like surfaces (`Viewer`, the `view.go`
line-shaping helpers, and `TaskList` windowing) with the battle-tested
`robinovitch61/viewport` component, and gain capabilities it didn't have before:
**in-view search** (logs/events/messages), **horizontal pan** for long lines,
selection-preserving packed rows, and save-to-file.

The library targets **Bubble Tea v2 + Go 1.26**; the cockpit nested module now
targets Go 1.26 and Bubble Tea v2. WS1 landed the whole-app v2 migration, WS2
adopted the core `viewport` package for the drill-down `Viewer`, WS3 added
`filterableviewport` search, WS4 added pan/log-number/export extras, WS5 moved
the task list onto `viewport`/`filterableviewport`, and WS6 removed the last
bespoke windowing helpers.

## 2. Target versions

- Go **1.26** (bump dev + CI toolchain).
- `charm.land/bubbletea/v2` (v2.0.2+), `charm.land/bubbles/v2`,
  `charm.land/lipgloss/v2`.
- `github.com/robinovitch61/viewport` (adds `viewport` + `filterableviewport`).
- Glamour: the existing renderer builds under the v2 dependency set; its output
  remains a plain string fed as viewport item content.

## 3. Why (feature map)

The cockpit reimplements viewport logic in three places, and it has already
caused real bugs (the blank-pane/scroll episode). One tested component removes
that class of bug and adds features.

| Cockpit today (bespoke) | Library capability |
|---|---|
| Drill-down cursor/offset/bottom-follow/clamp | core viewport |
| Summary/body clipping in `view.go` | Lip Gloss pane bounds and viewport-backed drill-downs |
| Task-list windowing + keep-selected-visible | viewport selection plus a sticky section/filter header |
| messages "keep header visible / by-whole-message" special-case | packed child rows owned by selectable message headers |
| long log lines hard-clipped with `…` | **horizontal pan** or wrap toggle |
| no in-view search in logs/events/messages | **`filterableviewport`** search + next/prev + matches-only |
| save visible logs/report rows | save-to-file |
| stable log line-number prefixes | `MultiItem` |

Library specifics to lean on: generic `viewport.New[T]` where your type
implements `Object.GetItem() item.Item`; top/bottom auto-follow; optional fixed
headers; highlight ranges; `filterableviewport` with exact/regex/case-insensitive/fuzzy
modes, match highlighting, next/prev match,
matches-only, match limit, and search history.

## 4. Workstream 1 — Bubble Tea v2 migration to parity (complete)

The cockpit now builds and runs on Bubble Tea v2 / Lip Gloss v2. The v1 build was
retired after parity was verified.

Verified against the official
[Bubble Tea v2 upgrade guide](https://github.com/charmbracelet/bubbletea/blob/main/UPGRADE_GUIDE_V2.md)
and [Lip Gloss v2 upgrade guide](https://github.com/charmbracelet/bubbles/blob/main/UPGRADE_GUIDE_V2.md).
Implemented migration points:

| Cockpit call-site (file) | v1 | v2 |
|---|---|---|
| `main.go` program setup | program options for alt-screen/mouse | `tea.NewProgram(m)`; features are requested from `View()` |
| `view.go` `View()` | returned `string` | returns `tea.View` with content plus alt-screen/mouse mode |
| `model.go` key handling | `tea.KeyMsg` struct | `tea.KeyPressMsg` and text/code/mod fields |
| mouse handling | `tea.MouseMsg` struct | v2 mouse interfaces with wheel/button variants |
| Lip Gloss imports | `github.com/charmbracelet/lipgloss` | `charm.land/lipgloss/v2` |

The deterministic test/dump path uses Bubble Tea v2 program options such as
`tea.WithWindowSize` and `tea.WithColorProfile` so `COCKPIT_DUMP` and the VHS
demo render without a real TTY.

Acceptance is closed: v2 parity passed with build, test, vet, mock dump smoke,
mouse/key coverage, and handoff command coverage.

## 5. Workstream 2 — Drill-down `Viewer` → `viewport` (complete)

- Define a `viewerObject` implementing `Object.GetItem()`; map the existing keyed
  `ViewerLine`s to `item.NewItem(...)` (the stable keys map directly to item
  identity, preserving cursor-across-refresh).
- Instantiate `viewport.New[viewerObject](w, h, WithSelectionEnabled(true), …)`;
  wire selection, packed child rows for message bodies/diff previews, and the
  bottom-follow policy for append-only live logs.
- Route the drill-down key/mouse events into `vp.Update(msg)`; keep the root
  model's focus model (`viewFocused`) deciding whether keys go to the list or the
  viewport.
- Preserve the openable-tab `Target` resolution (`resolveTarget`) by carrying the
  target on the object (or a parallel map keyed by item identity).

Regression contract: cursor identity is preserved across the 2s refresh;
bottom-follow works for live logs; clamp-at-edges works; messages are navigable
by whole message; nvim/diffnav targets still resolve.

## 6. Workstream 3 — In-view search via `filterableviewport` (complete)

- Wrapped the drill-down viewport in `filterableviewport.New[viewerObject](vp, …)`.
- Reconciled keys: `/` stays task-list search when the **list** is focused; when
  a **drill-down** is focused, `/` starts exact search, `enter` applies, `esc`
  clears, `n`/`N` jump matches, and `o` toggles matches-only view. README/spec
  keybars are updated.

Regression contract: filtering, match navigation, and matches-only mode work in
logs/events/messages with no key collision against task-list search.

## 7. Workstream 4 — Long-line handling & extras (complete)

- Horizontal pan for long unwrapped log lines replaces hard `…` clipping.
  `left`/`right` pan when the logs view is focused.
- Logs render stable line-number prefixes.
- `s` writes the currently visible viewer rows to `cockpit.exportDir`
  (`COCKPIT_EXPORT_DIR` override).

Regression contract: a long unwrapped log line pans instead of truncating; line
numbers render for logs; save-to-file writes the visible content.

## 8. Workstream 5 — Task list → `viewport` (complete)

WS5a moved `TaskList` rendering/windowing onto `viewport`: selectable task/run
rows are viewport items, the selected group header is sticky at the top, and
left-pane scrolling is driven by viewport selection instead of `windowLines`.

WS5b routed task-list search input through `filterableviewport` while preserving
case-insensitive substring filtering over task/run ids and row text, selection
clamping, and section-tab behavior.

## 9. Workstream 6 — Delete bespoke windowing + docs (complete)

Removed `windowLines`, `scrollWindowLines`, `fitBlock`, the unused max-scroll
helper, and the final pre-closure docs references. Window sizing is pane layout
only; drill-down scrolling/panning/searching lives in `Viewer`, and task-list
scrolling/searching lives in `TaskList`.

## 10. Resolved risks & mitigations

- **Whole-app migration:** closed by migrating the whole cockpit to v2 before
  adding viewport-backed components; the v1 build is no longer retained.
- **v2 API churn:** closed by checking the official v2 guides and updating the
  concrete call-sites listed above.
- **Glamour under v2:** closed by keeping rendered markdown as viewport item
  content.
- **Go toolchain:** the nested module now records the required Go/tool versions
  in `clients/cockpit/go.mod`.
- **Handoffs (`tea.ExecProcess`):** nvim/diffnav/gh/omp command handoffs are
  covered after the v2 migration.

## 11. Rejected alternatives

- **Stay on v1, borrow the patterns into `Viewer`:** rejected; the cockpit now
  uses the v2-compatible viewport path directly instead of reimplementing library
  behavior on v1.
- **Vendor/port a subset to v1** — the library is generic and v2-coupled; a clean
  backport is more work than the borrow-the-patterns option and orphans upstream
  fixes.

## 12. Sequencing

1. WS1 — v2 migration to parity (complete).
2. WS2 — drill-down `Viewer` → `viewport` (+ selection, follow, packed child rows) (complete).
3. WS3 — `filterableviewport` in-view search (complete).
4. WS4 — horizontal pan / wrap / line numbers / save-to-file (complete).
5. WS5 — task-list viewport rendering, sticky selected-group header, and filterable task-list search (complete).
6. WS6 — delete bespoke windowing + docs sweep (complete).

Sources: [robinovitch61/viewport](https://github.com/robinovitch61/viewport),
[library go.mod](https://raw.githubusercontent.com/robinovitch61/viewport/main/go.mod),
[Bubble Tea](https://github.com/charmbracelet/bubbletea)
