# Handoff — Integrate gh-dash + diffnav into the Foreman cockpit

Status: Implemented in `clients/cockpit/` · Date: 2026-07-10 · Owner: Leo D'Angelo
Audience: local coding agent (Go / Bubble Tea)
Related: `docs/design/cockpit-ui-spec.md`, `docs/adr/0001-go-clients-elixir-core-runtime.md`
Target module: `clients/cockpit/` (Go, `github.com/fortium/foreman/clients/cockpit`)

## 1. Objective

Give a developer everything in one pane: Foreman runs/tasks (already built) plus
GitHub PR state and rich diff review, without leaving the cockpit. Integrate two
external Charm TUIs and one native view:

- **diffnav** (`dlvhdr/diffnav`) — a delta-based git diff pager with a file tree.
- **gh-dash** (`dlvhdr/gh-dash`, run as `gh dash`) — a GitHub PR/issue dashboard.
- **gh-enhance** (`dlvhdr/gh-enhance`, run as `gh enhance`) — a GitHub Actions
  TUI: watch runs, drill into job logs, and rerun failed/flaky jobs. This is the
  CI dimension — Foreman surfaces *whether* checks are red; enhance is how you
  inspect *why* and rerun.
- A **native PR drill-down tab** sourced from Foreman's own PR reconciliation
  data (so per-run PR status is always on screen with no external process).


## Implementation status

Implemented in the Go cockpit module:

- Config loading for optional `diffnav`, `delta`, `gh dash`, `gh enhance`, and PR integration settings.
- Runtime tool and `gh` extension availability checks with graceful notices for missing/disabled tools.
- `D` full-run `diffnav` handoff from the `files` tab.
- Inline selected-file diff previews using `delta` when available, plain `git diff` otherwise.
- Best-effort file tab population from `/api/v1/runs/:run_id/debug` timeline
  payloads until a dedicated changed-file endpoint exists.
- Global `G` `gh dash` handoff.
- Global `C` `gh enhance` handoff from the selected run worktree.
- Native `pr` tab backed by Foreman-projected run PR fields, including optional mergeability, review decision, and check summaries when projected, with `o`/`enter` opening the PR URL and action hints for PR/CI triage.

Verification used for the implementation: `go test ./...`, `go build ./...`, and `go vet ./...` in `clients/cockpit`.

## 2. Guiding decision (do not deviate without flagging)

Both external tools are `package main` binaries, **not importable libraries**, so
in-process embedding of their models is out of scope. Use three tiers:

1. **Handoff** (`tea.ExecProcess`) — suspend the cockpit, run the tool full
   screen, resume on exit. This is the existing nvim pattern. Use it for the full
   `diffnav` review and the full `gh dash` dashboard.
2. **Inline native render** — reuse the *engine*, not the binary: pipe git diff
   through `delta` for an inline preview; source PR status from Foreman's API and
   render it natively. Use it for the always-visible parts.
3. **Embedded live TUIs via pty** — **explicitly out of scope.** Do not attempt
   pty multiplexing in this task.

Foreman-native principle: do **not** duplicate what the Elixir core already
knows. Per-run PR status comes from Foreman; `gh dash` is only for repo-wide
triage beyond Foreman's tasks.

## 3. What already exists (build on these, don't reinvent)

Confirmed hook points in `clients/cockpit/`:

- `nvim.go` — `openInNvim(e EditorConfig, t target, diff bool) tea.Cmd` wraps
  `tea.ExecProcess` (inline) and a background remote command. `EditorConfig`,
  `useRemote()`, `serverAddr()`, `describe()`, `expandHome()`, and the `target`
  struct all live here. **This is the template for every handoff.**
- `task_edit.go` — `editTaskInNvim(...)` is a working example of "run an external
  editor via `tea.ExecProcess`, then refresh from the server on completion."
  Mirror its shape for tools that should trigger a data refresh on return.
- `model.go` — `tabNames`, `firstOpenableTab`, `viewerTab()`, `openableTab()`,
  the `handleKey` switch (add global keys here), `loadDetail()` (per-run detail
  fetch), and the `dataMsg` refresh path.
- `view.go` — `renderTabs(w)` builds the tab strip from `tabNames`;
  `renderRight(w)` / `renderViewerLines(...)` / the tab `switch` render bodies;
  `renderAction(w)` renders the action bar. Add the `pr` tab body here.
- `client.go` — the `Client` interface, the `Run`/`Task`/`Message`/`Event`/
  `Report`/`FileChange` types, `httpClient` with `get()`, helpers `arr`/`obj`/
  `str`/`stringList`, `DrainErrors()`, and `NewMockClient()`. Add PR data here.
- `styles.go` — palette (`cGreen`/`cYellow`/`cRed`/`cCyan`/`cDim` …) for status
  coloring.
- `main.go` — `clientForConfig`, `ensureTTY()` (handoffs require a TTY — already
  guaranteed for the interactive path).

Run struct now includes PR projection fields used by the native `pr` tab:
`PRURL`, `PRState`, `PRHeadSHA`, `BaseBranch`, and `BranchName`. `Client.PR`
returns the selected run's `PRStatus`; no dedicated PR endpoint is required yet.

## 4. Dependencies & graceful degradation

External binaries (all optional at runtime): `diffnav`, `delta`, `gh`, and the
`gh dash` and `gh enhance` extensions (`gh extension install dlvhdr/gh-dash` /
`dlvhdr/gh-enhance`). diffnav needs a Nerd Font for icons; the `gh` extensions
need `gh` auth. `ToolResolver.ExtensionAvailable("dash"|"enhance")` shells
`gh extension list` once and caches the parsed result, distinct from
`ToolResolver.Available` for plain binaries.

`tools.go` keeps path and extension availability checks cached. Every integration
degrades gracefully: if the tool is missing, do nothing destructive and set
`m.notice` to a clear message (e.g. `diffnav not found — install dlvhdr/diffnav`).
Never crash, never block.

## 5. Configuration surface

Extend `.foreman/config.yaml` (parsed where `EditorConfig` is loaded). All
optional; shown with defaults:

```yaml
integrations:
  diffnav:
    enable: auto        # auto | on | off  (auto = use if on PATH)
    base: origin/dev    # diff base; Foreman rebases onto origin/dev
    watch: false        # pass diffnav --watch for live runs
  delta:
    enable: auto        # inline diff preview renderer
  ghDash:
    enable: auto
    args: []            # extra args appended to `gh dash`
  ghEnhance:
    enable: auto
    args: []            # extra args appended to `gh enhance`
pr:
  provider: github      # source of PR status (github via gh, or foreman events)
```

Load into an `Integrations` struct next to `EditorConfig`. Env overrides for
tests: `COCKPIT_DIFFNAV=off`, `COCKPIT_DELTA=off`, `COCKPIT_GHDASH=off`,
`COCKPIT_GHENHANCE=off`.

## 6. Workstreams

Implement in this order. Each is independently shippable and testable. Follow the
repo TDD rule (RED → GREEN → refactor): write the failing test first.

### A. diffnav review on the `files` tab (tier 1 handoff)

Intent: from a run's `files` tab, open the whole run diff in diffnav.

- Keymap: add `D` (shift-d) in `handleKey`, active when `tabNames[m.tab] ==
  "files"`. Keep existing `d` = per-file nvim diff and `o` = open file in nvim.
- Command builder (pure, unit-testable — do NOT inline the exec in `handleKey`):

  ```go
  // diffnav.go
  func diffnavCommand(run Run, cfg Integrations) (*exec.Cmd, error) {
      if !cfg.diffnavEnabled() { return nil, errToolDisabled("diffnav") }
      wt := expandHome(run.Worktree)
      base := cfg.Diffnav.Base // default "origin/dev"
      // git -C <wt> diff <base>...HEAD | diffnav
      pipeline := fmt.Sprintf("git -C %q diff %s...HEAD | diffnav", wt, base)
      return exec.Command("bash", "-lc", pipeline), nil
  }
  ```

  Return it via `tea.ExecProcess(cmd, func(err error) tea.Msg { return diffnavDoneMsg{err} })`,
  mirroring `openInNvim`. Handle `diffnavDoneMsg` in `Update` to set a notice.
- If `run.Worktree` is empty/`(cleaned)` (merged/failed runs), show a notice
  instead of launching.
- Optional: when `cfg.Diffnav.Watch`, append `--watch` semantics per diffnav docs
  (re-runs the diff and refreshes) — nice for active runs.
- Acceptance: on the `files` tab of a run with a worktree, `D` suspends the
  cockpit, shows diffnav with the run's changed files, and returns cleanly on
  quit; missing diffnav/delta shows a notice and does nothing else.

### B. Inline `delta` diff preview in the `files` tab (tier 2)

Intent: selecting a changed file shows a syntax-highlighted diff inline (no
process takeover), the way `reports` render markdown through Glamour today.

- In the `files` branch of the viewer/body render, for the selected file build:
  `git -C <wt> diff <base>...HEAD -- <path>` piped through `delta --color-only`
  (respect `NO_COLOR`/width). Capture stdout, split into viewer lines.
- Put the exec behind a pure builder `deltaPreviewCommand(run, path, cfg)` and a
  thin runner; cache the output per (runID, path) so it isn't recomputed every
  render/tick. Degrade to a plain `git diff` (or the existing file list) when
  delta is absent.
- Keep it inside the existing `Viewer` line model so scrolling/`fitBlock` still
  work. Do not break the `o`/`d`/`D` actions.
- Acceptance: moving the cursor onto a changed file shows its colored diff inline;
  no external process is launched; absent delta falls back to plain diff text.

### C. gh-dash repo-wide handoff (tier 1)

Intent: a global key opens the full GitHub dashboard.

- Keymap: add `G` (shift-g) in `handleKey` (note lowercase `g` already toggles
  scope — use uppercase). Active regardless of tab.
- Builder: `ghDashCommand(cfg Integrations) (*exec.Cmd, error)` → `exec.Command("gh",
  append([]string{"dash"}, cfg.GhDash.Args...)...)`. Launch via `tea.ExecProcess`.
- Acceptance: `G` suspends the cockpit, opens `gh dash`, returns on quit; missing
  `gh`/`gh dash` shows a notice.
- Optional stretch: document the reverse direction in the spec — `gh dash` custom
  commands can launch `foreman-cockpit`/`diffnav`/`gh enhance` with
  `{{.RepoPath}}` / `{{.PrNumber}}` context. No cockpit code needed; just a
  config recipe.

### E. gh-enhance GitHub Actions handoff (tier 1) — implemented

Implemented in this pass after Workstreams A–D:

Intent: from a run (especially when its PR checks are red), open `gh enhance` to
watch/inspect the GitHub Actions job logs and rerun failed or flaky jobs (`Ctrl+R`
inside enhance) — deep CI work that Foreman's `cicd-developer` phase complements
but does not replace.

- Keymap: global `C` (CI). Most useful on the `pr` tab, but allow it on any run.
- Builder: `ghEnhanceCommand(run Run, cfg Integrations, tools ToolResolver) (*exec.Cmd, error)` →
  `exec.Command("gh", append([]string{"enhance"}, cfg.GhEnhance.Args...)...)`,
  with `cmd.Dir = expandHome(run.Worktree)` so `gh` resolves the right repo.
  The first implementation launches unfiltered from the selected worktree rather
  than guessing unsupported branch/workflow flags.
- Launch via `tea.ExecProcess`; set a notice on return (mirrors `ghDashCommand`).
- Degrade with a notice if `gh` or the `gh enhance` extension is missing
  (`ExtensionAvailable("enhance")`), disabled, or if the run has no worktree.
- Acceptance: `C` suspends the cockpit, opens `gh enhance`, and returns cleanly;
  missing prerequisites show a notice and do nothing else.
- UI pairing: the `pr` tab's checks summary answers *whether* CI is red; `C` →
  enhance is how you inspect *why* and rerun. The `pr` action bar hints `C`
  whenever a PR URL is present.

### D. Native PR drill-down tab (tier 2)

Intent: a `pr` tab showing the selected run's PR status without any external
process — the true single-pane win.

- Add `"pr"` to `tabNames` (append after `files`; it is not an nvim-openable tab,
  so keep it out of the `>= firstOpenableTab` open/diff logic — verify
  `openableTab()` still refers only to logs/reports/files).
- Data source, in priority order (inspect the Elixir side to confirm exact
  fields — see `packages/foreman_server/lib/foreman_server/projection_store/`
  for `PrUpdated` / `PrReady` / `run.pr.merge` events and any `pr_url`/`pr_state`
  on the run projection):
  1. If the run projection (`GET /api/v1/runs`) exposes PR fields, extend the
     `Run` struct (`PRNumber`, `PRState`, `PRURL`, `Mergeable`, `Checks`) and map
     them in `httpClient.Runs()`.
  2. Otherwise derive from `GET /api/v1/events` / `…/runs/:id/debug` (the events
     tab already falls back to debug) by folding `run.pr.*` events.
  3. As a last resort for live check/review detail, shell `gh pr view <url>
     --json state,statusCheckRollup,reviewDecision,mergeable` (guarded by `gh`
     availability). Keep this behind the `pr.provider: github` config.
- Add `Client.PR(runID string) PRStatus` to the interface; implement on both
  `httpClient` and `mockClient` (give the mock realistic data for the existing
  `foreman-a1b2c` / merged / failed runs).
- Render in `view.go`: PR number + state (color by state: open=cyan,
  merged=green, closed=red, draft=dim), mergeable, a checks summary
  (`✓ 4  ✗ 1  ● 2` using the palette), review decision, and the URL.
- Actions on the `pr` tab: `o`/`enter` opens the PR in the browser (`gh pr view
  --web <url>` or an `openLink`-style fallback); reuse `G` to jump into `gh dash`
  filtered to `head:<run.Branch>` if feasible.
- Empty state: runs without a PR show "No PR for this run yet."
- Acceptance: selecting a run with a PR shows live-ish PR status on the `pr` tab;
  runs without a PR show the empty state; no blocking calls on the render path
  (fetch in `loadDetail`, cache like other detail).

## 7. Keymap additions (update the spec + README to match)

| Key | Context | Action |
|-----|---------|--------|
| `D` | `files` tab | open the run diff in diffnav (handoff) |
| `G` | global | open `gh dash` (handoff) |
| `C` | global (esp. `pr` tab) | open `gh enhance` — GitHub Actions (handoff) |
| `o`/`enter` | `pr` tab | open the PR in the browser |
| (`1`–`7`) | global | extend tab jump to include `pr` |

Leave `d` (per-file nvim diff), `o` (open in nvim), `g` (scope), `r`/`R` as-is.

## 8. Testing (required, TDD)

Keep all `exec` behind pure builder functions so they are unit-testable without
running anything:

- `diffnavCommand`, `ghDashCommand`, `ghEnhanceCommand`, `deltaPreviewCommand`,
  and any `gh pr view` builder return `*exec.Cmd`; assert on `.Path`/`.Args`/
  `.Dir` in table-driven tests, including the disabled/missing-tool and
  empty-worktree/no-branch branches.
- `toolAvailable` — test the `enable: on|off|auto` resolution independent of PATH.
- PR mapping — feed sample `/runs` and `/events` JSON (capture real shapes with
  `COCKPIT_DUMP=1` against a live server, or copy fixtures) into the parser and
  assert the resulting `PRStatus`.
- Mock client — extend `mockClient.PR` and add a couple of file diffs so the UI
  paths render in `COCKPIT_BACKEND=mock`.
- Run `go build ./... && go test ./...` in `clients/cockpit`; keep `go vet` clean.

## 9. Docs to update (documentation gate)

- `clients/cockpit/README.md` — new keys (`D`, `G`, `C`), the `pr` tab, dependency
  list (diffnav, delta, gh + gh-dash + gh-enhance, Nerd Font), and the
  `integrations`/`pr` config block.
- `docs/design/cockpit-ui-spec.md` — add the `pr` tab to the tab strip, the
  diffnav/gh-dash/gh-enhance integration section, the keymap table, and the
  config surface.
- `docs/adr/0001-…` — no change expected; note here if the PR data need forces a
  new `/api/v1` field (that would be an Elixir-core follow-up, out of this task).

## 10. Non-goals & risks

- **Out of scope:** pty-embedded live TUIs (tier 3); building new Elixir
  endpoints. If per-run PR data is not obtainable from the existing API + `gh`,
  stop and flag it rather than adding server endpoints in this task.
- **Risks:** base-branch assumption (`origin/dev`) — make it configurable and
  fall back sensibly; diffnav Nerd-Font/`delta` requirements; `gh` auth; and the
  render path must never block on `exec` (fetch in `loadDetail`, cache results).
- **Consistency:** every handoff must go through `tea.ExecProcess` and set a
  notice on return, exactly like `openInNvim`/`editTaskInNvim`. Do not spawn
  detached processes for interactive tools.

## 11. Suggested PR breakdown

1. `tools.go` + `Integrations` config + `toolAvailable` (+ tests).
2. Workstream A (diffnav handoff) — smallest, highest signal.
3. Workstream C (gh-dash handoff).
4. Workstream B (inline delta preview).
5. Workstream D (native `pr` tab) — largest; may reveal an API gap to flag.
6. Workstream E (gh-enhance handoff).
7. Docs sweep (README + spec).
