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

- Config loading for optional `diffnav`, `delta`, `gh dash`, and `gh enhance`
  integration settings.
- Runtime tool and `gh` extension availability checks with graceful notices for missing/disabled tools; the full-run `diffnav` handoff preflights both `diffnav` and `delta` to match the configured review stack and avoid suspending into a broken external diff path.
- `D` full-run `diffnav` handoff from the `files` tab.
- Inline selected-file diff previews using `delta` when available, plain `git diff` otherwise.
- File tab population reads selected-run worktree/base metadata from `/api/v1/runs`,
  prefers `git diff --numstat` and `--name-status` from that worktree, then falls
  back to structured or legacy `/api/v1/runs/:run_id/debug` timeline `payload` /
  `file_changes` fields when no worktree diff is available.
- Global `G` `gh dash` handoff.
- Global `C` `gh enhance` handoff from the selected run worktree.
- Native `pr` tab backed by Foreman-projected run PR fields, including mergeability, review decision, and check summaries, with `o`/`enter` opening the PR URL and action hints for PR/CI triage.

Historical implementation verification used `go test ./...`, `go build ./...`, and `go vet ./...` in `clients/cockpit`; rerun the release verification before shipping new integration changes.

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
  `str`/`stringList`, `DrainErrors()`, and `NewMockClient()` include the PR data
  consumed by the native tab.
- `styles.go` — palette (`cGreen`/`cYellow`/`cRed`/`cCyan`/`cDim` …) for status
  coloring.
- `main.go` — `clientForConfig`, `ensureTTY()` (handoffs require a TTY — already
  guaranteed for the interactive path).

The run projection and client parser now expose the PR fields used by the native
`pr` tab: `PRURL`, `PRState`, `PRHeadSHA`, `BaseBranch`, `BranchName`,
mergeability, review decision, and check summary. `Client.PR` returns the
selected run's `PRStatus`; no dedicated PR endpoint is required.

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

The cockpit reads `.foreman/config.yaml` into `Config.Integrations` and
`Config.Cockpit`. All optional; shown with defaults:

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
```

Env overrides for integration enablement remain `COCKPIT_DIFFNAV=off`,
`COCKPIT_DELTA=off`, `COCKPIT_GHDASH=off`, and `COCKPIT_GHENHANCE=off`.

## 6. Closed workstreams

The workstreams below are implemented. Keep the historical criteria as
regression contracts, not as work still to do.

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
- When `cfg.Diffnav.Watch` is true, append `--watch` semantics per diffnav docs
  (re-runs the diff and refreshes) for active runs.
- Regression contract: on the `files` tab of a run with a worktree, `D`
  suspends the cockpit, shows diffnav with the run's changed files, and returns
  cleanly on quit; missing diffnav/delta shows a notice and does nothing else.

### B. Inline `delta` diff preview in the `files` tab (tier 2)

Intent: selecting a changed file shows a syntax-highlighted diff inline (no
process takeover), the way `reports` render markdown through Glamour today.

- In the `files` branch of the viewer/body render, for the selected file build:
  `git -C <wt> diff <base>...HEAD -- <path>` piped through `delta --color-only`
  (respect `NO_COLOR` and the focused pane width via `COLUMNS`). Capture stdout,
  split into viewer lines.
- Put the exec behind a pure builder
  `deltaPreviewCommand(run, path, width, cfg, tools)` and a thin runner; cache
  the output per (runID, path) so it isn't recomputed every render/tick. Degrade
  to a plain `git diff` (or the existing file list) when delta is absent.
- Keep it inside the existing `Viewer` line model so viewport-backed scrolling
  still works. Do not break the `o`/`d`/`D` actions.
- Regression contract: moving the cursor onto a changed file shows its colored
  diff inline; no external process is launched; absent delta falls back to plain
  diff text; loading and cached-preview guards prevent recomputation on render/tick.

### C. gh-dash repo-wide handoff (tier 1)

Intent: a global key opens the full GitHub dashboard.

- Keymap: add `G` (shift-g) in `handleKey` (note lowercase `g` already toggles
  scope — use uppercase). Active regardless of tab.
- Builder: `ghDashCommand(cfg Integrations) (*exec.Cmd, error)` → `exec.Command("gh",
  append([]string{"dash"}, cfg.GhDash.Args...)...)`. Launch via `tea.ExecProcess`.
- Regression contract: `G` suspends the cockpit, opens `gh dash`, returns on
  quit; missing `gh`/`gh dash` shows a notice.
- Reverse direction documented: `gh dash` custom PR keybindings can launch
  `foreman-cockpit`, `diffnav`, or `gh enhance` from `{{.RepoPath}}` while using
  `{{.PrNumber}}`, `{{.BaseRefName}}`, and other selected-PR template fields.
  This remains an operator-local config recipe, not cockpit runtime code.

### E. gh-enhance GitHub Actions handoff (tier 1) — implemented

Implemented after Workstreams A–D:

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
- Regression contract: `C` suspends the cockpit, opens `gh enhance`, and returns
  cleanly; missing prerequisites show a notice and do nothing else.
- UI pairing: the `pr` tab's checks summary answers *whether* CI is red; `C` →
  enhance is how you inspect *why* and rerun. The `pr` action bar hints `C`
  whenever a PR URL is present.

### D. Native PR drill-down tab (tier 2)

Intent: a `pr` tab showing the selected run's PR status without any external
process — the true single-pane win.

- Add `"pr"` to `tabNames` (append after `files`). It is a viewer tab, but not an
  nvim-openable tab; `openableTab()` stays limited to logs/reports/files.
- Data source, in priority order:
  1. Prefer PR fields on the run projection (`GET /api/v1/runs`): `pr_url`,
     `pr_state`, `pr_head_sha`, branch/base fields, `pr_mergeable`,
     `pr_review_decision`, and `pr_checks`. The run projection also carries
     cockpit row counts and diff totals.
  2. Otherwise derive from `GET /api/v1/events` / `…/runs/:id/debug` (the events
     tab already falls back to debug) by folding `run.pr.*` and PR-gate events.
     The client does not shell out to `gh pr view` for data; `gh` remains an
     opener/enhancement handoff, while Foreman projections/debug timelines are
     the authoritative cockpit data source.
- `Client.PR(runID string) PRStatus` is implemented on both `httpClient` and
  `mockClient`, with realistic mock PR data for the existing `foreman-a1b2c`,
  merged, and failed runs.
- Render in `view.go`: PR number + state (color by state: open=cyan,
  merged=green, closed=red, draft=dim), mergeable, a checks summary
  (`✓ 4  ✗ 1  ● 2` using the palette), review decision, and the URL.
- Actions on the `pr` tab: `o`/`enter` opens the PR in the browser (`gh pr view
  --web <url>` or an `openLink`-style fallback). Global `G` still opens the
  configured repo-wide `gh dash`; PR-specific reverse handoffs live in operator
  `gh-dash.yml` keybindings, not cockpit runtime code.
- Empty state: runs without a PR show "No PR for this run yet."
- Regression contract: selecting a run with a PR shows live-ish PR status on the
  `pr` tab; runs without a PR show the empty state; no blocking calls run on the
  render path.

## 7. Keymap additions

| Key | Context | Action |
|-----|---------|--------|
| `D` | `files` tab | open the run diff in diffnav (handoff) |
| `G` | global | open `gh dash` (handoff) |
| `C` | global (esp. `pr` tab) | open `gh enhance` — GitHub Actions (handoff) |
| `o`/`enter` | `pr` tab | open the PR in the browser |
| (`1`–`8`) | global | direct tab jumps include `pr` and `metrics` |

Leave `d` (per-file nvim diff), `o` (open in nvim), `g` (scope), `r`/`R` as-is.

## 8. Verification completed

The shipped tests keep process handoffs behind pure builder functions and cover:

- `diffnavCommand`, `ghDashCommand`, `ghEnhanceCommand`,
  `deltaPreviewCommand`, and the selected-file diff-preview runner command
  construction, disabled/missing-tool paths (including missing `gh`),
  empty-worktree/no-branch branches, selected-file loading/cache guards, and
  viewport-width `COLUMNS` propagation into the actual preview subprocess.
- `toolAvailable` / integration enablement modes independent of PATH.
- PR projection mapping from `/api/v1/runs`, including checks and review fields.
- Mock client file diffs, PR state, and render paths for `COCKPIT_BACKEND=mock`.
- Historical broad verification: `go test ./...`, `go build ./...`, and `go vet ./...` in `clients/cockpit`; rerun before shipping new integration changes.

## 9. Documentation updated

- `clients/cockpit/README.md` — keys (`D`, `G`, `C`), the `pr` tab, dependency
  list (diffnav, delta, gh + gh-dash + gh-enhance, Nerd Font), and the
  `integrations` config block. The `pr` tab is projection-driven and has no
  separate config block.
- `docs/design/cockpit-ui-spec.md` — add the `pr` tab to the tab strip, the
  diffnav/gh-dash/gh-enhance integration section, the keymap table, and the
  config surface.
- No ADR update was needed; the required PR readiness fields were added to the
  existing `/api/v1/runs` projection instead of creating a new endpoint.

## 10. Non-goals & risks

- **Out of scope:** pty-embedded live TUIs (tier 3) and brand-new integration
  endpoints. Worktree/branch/base metadata, PR readiness fields, row counts, and
  diff totals are exposed on the existing `/api/v1/runs` projection; file-change
  fallback data is exposed on the existing `/api/v1/runs/:run_id/debug` timeline.
- **Resolved risks:** the diff base is configurable (`integrations.diffnav.base`) and falls
  back sensibly; conflicted worktree files are marked in the file list; diffnav
  Nerd-Font/`delta` requirements and `gh` auth failures surface as notices; exec
  work stays out of render paths by loading/caching detail.
- **Consistency:** full-screen external review tools (`diffnav`, `gh dash`, and
  `gh enhance`) go through `tea.ExecProcess` and set a notice on return, exactly
  like `openInNvim`/`editTaskInNvim`. OMP tmux mode is the exception: it uses a
  non-suspending tmux pane/window when configured or auto-detected.

## 11. Closed PR breakdown

1. `tools.go` + `Integrations` config + `toolAvailable` (+ tests) — complete.
2. Workstream A (diffnav handoff) — complete.
3. Workstream C (gh-dash handoff) — complete.
4. Workstream B (inline delta preview) — complete.
5. Workstream D (native `pr` tab) — complete.
6. Workstream E (gh-enhance handoff) — complete.
7. Docs sweep (README + spec) — complete.
