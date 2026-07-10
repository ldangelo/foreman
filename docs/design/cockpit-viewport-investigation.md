# Handoff — Migrate the cockpit to Bubble Tea v2 and adopt `robinovitch61/viewport`

Status: WS1–WS4 complete; WS5a task-list viewport rendering complete; WS5b filterable task-list search is next · Date: 2026-07-10 · Owner: Leo D'Angelo
Audience: local coding agent (Go / Bubble Tea)
Subject: [`github.com/robinovitch61/viewport`](https://github.com/robinovitch61/viewport)
Related: `clients/cockpit/viewer.go`, `view.go` (`windowLines`/`scrollWindowLines`/`fitBlock`), `task_list.go`, `model.go`, `styles.go`, `theme/gen.go`

## 1. Objective & decision

Replace the cockpit's three hand-rolled viewport implementations (`Viewer`, the
`view.go` window helpers, and `TaskList` windowing) with the battle-tested
`robinovitch61/viewport` component, and gain capabilities it doesn't have today:
**in-view search** (logs/events/messages), **horizontal pan** for long lines,
**sticky headers**, and save-to-file.

The library targets **Bubble Tea v2 + Go 1.26**; the cockpit nested module now
targets Go 1.26 and Bubble Tea v2. WS1 landed the whole-app v2 migration, WS2
adopted the core `viewport` package for the drill-down `Viewer`, WS3 added
`filterableviewport` search, and WS4 added pan/log-number/export extras.

## 2. Target versions

- Go **1.26** (bump dev + CI toolchain).
- `charm.land/bubbletea/v2` (v2.0.2+), `charm.land/bubbles/v2`,
  `charm.land/lipgloss/v2`.
- `github.com/robinovitch61/viewport` (adds `viewport` + `filterableviewport`).
- Glamour: keep the current renderer if it builds under the v2 dep set (its
  output is a plain string fed as viewport item content); otherwise move to a
  v2-compatible markdown renderer. Verify during Workstream 1.

## 3. Why (feature map)

The cockpit reimplements viewport logic in three places, and it has already
caused real bugs (the blank-pane/scroll episode). One tested component removes
that class of bug and adds features.

| Cockpit today (bespoke) | Library capability |
|---|---|
| `Viewer` cursor/offset/bottom-follow/clamp (`viewer.go`) | core viewport |
| `windowLines`/`scrollWindowLines`/`fitBlock` (`view.go`) | core viewport windowing |
| `TaskList` windowing + keep-selected-visible | selection + sticky header |
| messages "keep header visible / by-whole-message" special-case | sticky header + selection |
| long log lines hard-clipped with `…` | **horizontal pan** or wrap toggle |
| no in-view search in logs/events/messages | **`filterableviewport`** search + next/prev + matches-only |
| "export logs/report" (not built) | save-to-file |
| line-number prefixing (not built) | `MultiItem` |

Library specifics to lean on: generic `viewport.New[T]` where your type
implements `Object.GetItem() item.Item`; sticky top/bottom auto-follow;
configurable sticky header; highlight ranges; `filterableviewport` with
exact/regex/case-insensitive/fuzzy modes, match highlighting, next/prev match,
matches-only, match limit, and search history.

## 4. Workstream 1 — Bubble Tea v2 migration to parity (do first, no library yet)

Goal: the cockpit compiles, runs, and behaves exactly as today, but on v2. Land
this on a branch and keep the v1 build until v2 reaches parity.

Verified against the official
[Bubble Tea v2 upgrade guide](https://github.com/charmbracelet/bubbletea/blob/main/UPGRADE_GUIDE_V2.md)
and [Lip Gloss v2 upgrade guide](https://github.com/charmbracelet/bubbles/blob/main/UPGRADE_GUIDE_V2.md).
The exact cockpit call-sites that change:

| Cockpit call-site (file) | v1 | v2 |
|---|---|---|
| `main.go` `tea.NewProgram(m, tea.WithAltScreen(), tea.WithMouseCellMotion())` | program options | `tea.NewProgram(m)`; set features in `View()` (see below) |
| `view.go` `View() string` | returns `string` | returns `tea.View` (`tea.NewView(frame)`, then `v.AltScreen=true`, `v.MouseMode=tea.MouseModeCellMotion`) |
| `model.go` `case tea.KeyMsg:` | struct | `case tea.KeyPressMsg:` (`tea.KeyMsg` is now an interface) |
| `handleKey` `msg.Runes` (search input) | `[]rune` | `msg.Text` (string) |
| `handleKey` `msg.Type == tea.KeyCtrlD` / `tea.KeyCtrlU` | key-type consts | `msg.String()=="ctrl+d"`/`"ctrl+u"` (or `msg.Code=='d' && msg.Mod==tea.ModCtrl`) |
| `handleKey` `case " ", "space"` | space is `" "` | space is `"space"` (already handled — keep) |
| `handleMouse(tea.MouseMsg)` wheel | struct + `msg.Action`/`msg.Button` | `case tea.MouseWheelMsg` with `tea.MouseWheelUp`/`Down`; coords via `msg.Mouse()` |
| `styles.go` / `theme/gen.go` lipgloss | `github.com/charmbracelet/lipgloss` | `charm.land/lipgloss/v2` — see its upgrade guide for the color/style API |

Steps:

1. `go.mod`: bump to `go 1.26`; swap `github.com/charmbracelet/bubbletea` →
   `charm.land/bubbletea/v2`, `lipgloss` → `charm.land/lipgloss/v2`; add
   `charm.land/bubbles/v2` if used. `go mod tidy`.
2. Update imports across the module (`tea`, `lipgloss`).
3. **Declarative View (the biggest change).** `View()` returns `tea.View`, not a
   string. Wrap the composed frame: `v := tea.NewView(frame); v.AltScreen = true;
   v.MouseMode = tea.MouseModeCellMotion; return v`. This is where the removed
   `tea.WithAltScreen()`/`tea.WithMouseCellMotion()` options now live, so `main.go`
   drops them from `NewProgram`. **`writeDebugDump` must read `v.Content`** (the
   rendered string), not a returned string.
4. **Keys** (`model.go` `handleKey`): match `tea.KeyPressMsg`. Rename the search
   input `msg.Runes` → `msg.Text`; replace the `msg.Type == tea.KeyCtrlD/CtrlU`
   half-page paths with `msg.String()` (`"ctrl+d"`/`"ctrl+u"`) or `msg.Code`+
   `msg.Mod`. `msg.String()` still drives the rest of the `switch`; `"space"` is
   already handled.
5. **Mouse** (`handleMouse`): `tea.MouseMsg` is an interface — handle
   `tea.MouseWheelMsg` (`tea.MouseWheelUp`/`Down`) for wheel scroll; read coords
   via `msg.Mouse()`. Button constants dropped the `Button` infix. Mouse mode
   moved to the View field (step 3).
6. **Commands/handoffs stay put.** `tea.ExecProcess`, `tea.Batch`, and `tea.Tick`
   are **not** in the v2 removed list — the nvim/diffnav/gh/omp handoffs and the
   2s refresh keep working unchanged. `tea.WindowSizeMsg` (the message) stays;
   only the `tea.WindowSize()` *command* was renamed to `tea.RequestWindowSize`
   (cockpit doesn't use it), and `tea.Sequentially`→`tea.Sequence` (unused).
   `p.Run()` is unchanged.
7. **lipgloss v2** (`styles.go`, `theme/gen.go`): follow the Lip Gloss v2 upgrade
   guide for the color/style API; ensure `//go:generate go run theme/gen.go` still
   emits valid v2 constants. The theme tokens (hex) are unchanged.
8. **Glamour**: confirm it builds under the v2 dep set; if not, feed pre-rendered
   strings as content (unchanged behavior) or swap renderer.
9. **Free testing win:** adopt the new `tea.WithColorProfile(p)` and
   `tea.WithWindowSize(w, h)` program options in the cockpit's tests /
   `COCKPIT_DUMP` path so rendering is deterministic without a real TTY.
10. Verify parity: `go build ./... && go test ./... && go vet ./...` on Go 1.26;
    manual run at parity (task list, all drill-down tabs, mouse, handoffs).

Acceptance (WS1): identical behavior to the v1 build, on v2. No viewport library
yet. v1 build removed only after this passes.

## 5. Workstream 2 — Drill-down `Viewer` → `viewport` (complete)

- Define a `viewerObject` implementing `Object.GetItem()`; map the existing keyed
  `ViewerLine`s to `item.NewItem(...)` (the stable keys map directly to item
  identity, preserving cursor-across-refresh).
- Instantiate `viewport.New[viewerObject](w, h, WithSelectionEnabled(true), …)`;
  wire selection, **sticky header** (the detail/messages header — replaces the
  messages special-case), and **sticky bottom auto-follow** for live logs
  (replaces `viewerBottom`/`scrollToBottom`).
- Route the drill-down key/mouse events into `vp.Update(msg)`; keep the root
  model's focus model (`viewFocused`) deciding whether keys go to the list or the
  viewport.
- Preserve the openable-tab `Target` resolution (`resolveTarget`) by carrying the
  target on the object (or a parallel map keyed by item identity).

Acceptance: cursor identity preserved across the 2s refresh; bottom-follow for
live logs; clamp at edges; messages navigable by whole message; nvim/diffnav
targets still resolve.

## 6. Workstream 3 — In-view search via `filterableviewport` (complete)

- Wrapped the drill-down viewport in `filterableviewport.New[viewerObject](vp, …)`.
- Reconciled keys: `/` stays task-list search when the **list** is focused; when
  a **drill-down** is focused, `/` starts exact search, `enter` applies, `esc`
  clears, `n`/`N` jump matches, and `o` toggles matches-only view. README/spec
  keybars are updated.

Acceptance: filtering + match navigation + matches-only work in logs/events/
messages; no key collision with task-list search.

## 7. Workstream 4 — Long-line handling & extras (complete)

- Horizontal pan for long unwrapped log lines replaces hard `…` clipping.
  `left`/`right` pan when the logs view is focused.
- Logs render stable line-number prefixes.
- `s` writes the currently visible viewer rows to `cockpit.exportDir`
  (`COCKPIT_EXPORT_DIR` override).

Acceptance: a long unwrapped log line pans instead of truncating; line numbers
render for logs; save-to-file writes the visible content.

## 8. Workstream 5 — Task list → `viewport` (partially complete)

WS5a moved `TaskList` rendering/windowing onto `viewport`: selectable task/run
rows are viewport items, the selected group header is sticky at the top, and
left-pane scrolling is driven by viewport selection instead of `windowLines`.

Remaining WS5b: replace the bespoke task-list search/filtering with
`filterableviewport` without changing substring search semantics or group
collapse behavior.

## 9. Workstream 6 — Delete bespoke windowing + docs

- Remove `windowLines`, `scrollWindowLines`, `fitBlock`, and the hand-rolled
  `Viewer` once fully replaced.
- Docs sweep: README "Architecture"/"Keys", `docs/design/cockpit-ui-spec.md`
  (component table → viewport, new search/pan keys), and note the v2/Go 1.26
  requirement in the run instructions.

## 10. Risks & mitigations

- **Whole-app migration** — mitigate by doing WS1 to parity on a branch, keeping
  v1 until v2 matches, and only then adding the library.
- **v2 API churn** — key/mouse/lipgloss names may differ from this doc; treat the
  deltas in §4 as a checklist to verify against the official v2 migration guide,
  not verbatim.
- **Glamour under v2** — verify early (WS1 step 7); fallback is feeding rendered
  strings as items.
- **Go 1.26 toolchain** — update dev + CI images before starting.
- **Handoffs (`tea.ExecProcess`)** — nvim/diffnav/gh/omp all rely on it; confirm
  v2 parity in WS1 step 5 before proceeding.

## 11. Rejected alternatives

- **Stay on v1, borrow the patterns into `Viewer`** — cheaper now but re-implements
  and re-tests what the library already solves, and you'd still migrate later.
  Fallback only if the v2 move is deferred.
- **Vendor/port a subset to v1** — the library is generic and v2-coupled; a clean
  backport is more work than the borrow-the-patterns option and orphans upstream
  fixes.

## 12. Sequencing

1. WS1 — v2 migration to parity (complete).
2. WS2 — drill-down `Viewer` → `viewport` (+ selection, follow, packed child rows) (complete).
3. WS3 — `filterableviewport` in-view search (complete).
4. WS4 — horizontal pan / wrap / line numbers / save-to-file (complete).
5. WS5a — task-list viewport rendering + sticky selected-group header (complete); WS5b filterable task-list search (next).
6. WS6 — delete bespoke windowing + docs sweep.

Sources: [robinovitch61/viewport](https://github.com/robinovitch61/viewport),
[library go.mod](https://raw.githubusercontent.com/robinovitch61/viewport/main/go.mod),
[Bubble Tea](https://github.com/charmbracelet/bubbletea)
