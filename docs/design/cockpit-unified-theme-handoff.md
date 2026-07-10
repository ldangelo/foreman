# Handoff — Make cockpit + gh-dash + gh-enhance + diffnav feel like one app

Status: Partially implemented in `clients/cockpit/` · Date: 2026-07-10 · Owner: Leo D'Angelo
Audience: local coding agent (Go / Bubble Tea + config authoring)
Related: `docs/design/cockpit-ui-spec.md`, `docs/design/cockpit-integrations-handoff.md`
Target: `clients/cockpit/` + shipped theme configs for the three external TUIs

## 1. Objective

The cockpit hands off to `diffnav`, `gh dash`, and `gh enhance`. Today each has
its own default look and keymap, so moving between them feels like four apps.
Make them read as **one product**: shared color tokens, one diff renderer, one
font/icon language, a converged keymap, and consistent chrome — installed and
kept in sync from a single source of truth.

Guiding principle: **one set of design tokens, many render targets.** Define the
palette once (the cockpit already effectively owns it), then project it into each
tool's native config format. Never hand-maintain four divergent color lists.

Keep the **terminal background as the shared canvas** (don't force a full-screen
bg in any tool). Theme the things that actually differ between tools: text
roles, borders, selection highlight, semantic status colors, and — most
importantly — the diff rendering.

## 2. What each tool lets you theme (confirmed)

| Tool | Theming surface | Notes |
|------|-----------------|-------|
| **cockpit** | `theme/tokens.yaml` → generated `theme_tokens_gen.go`; Glamour JSON for markdown; `delta` for inline diff preview | Implemented as the source of truth for cockpit colors and report rendering. |
| **gh-dash** | generated `theme/gh-dash.yml` with `theme.colors` (`text.{primary,secondary,inverted,faint,warning,success}`, `background.selected`, `border.{primary,secondary,faint}`), plus keybindings | Generated fragment exists; global install/merge remains future work. |
| **gh-enhance** | `ENHANCE_THEME` Bubbletint theme id | Implemented as generated `theme/enhance.env` and cockpit handoff env. Full custom schema/config path is not used. |
| **diffnav** | generated `theme/diffnav/config.yml` → `ui:` (icons, sideBySide, file-tree width, header/footer, colorFileNames…). Diff **body** color is delegated to **delta** | Cockpit sets `$DIFFNAV_CONFIG_DIR` to the packaged dir during handoff. |
| **delta** | generated `theme/delta.gitconfig` (syntax-theme, plus/minus styles, line-numbers, side-by-side, hunk/file headers) | Shared fragment exists; inline previews still respect tool availability and fall back to plain git diff. |

Residual truth to accept: gh-dash exposes only `warning` + `success` text
semantics (no separate `error`/`info` slot), and some chrome (exact border
glyphs, header layout) isn't configurable beyond color. Document these as known
residual differences rather than fighting them.

## 3. Canonical design tokens (single source of truth)

`clients/cockpit/theme/tokens.yaml` is the authority. It is consumed by
`clients/cockpit/theme/gen.go`, which writes cockpit constants and all shipped
theme fragments:

```yaml
# Foreman unified terminal theme — all values #RRGGBB truecolor unless noted.
text:
  primary: "#c8ccd4"
  secondary: "#8b93a1"
  faint: "#6b7280"
  inverted: "#12141a"
accent: "#56b6c2"
accent2: "#b392f0"
success: "#7ee787"
warning: "#e5c07b"
danger: "#ff7b72"
border:
  primary: "#2b2f3a"
  secondary: "#3a3f4b"
  faint: "#1c1f27"
bg:
  canvas: "transparent"
  selected: "#1f2a44"
  emphasis: "#13303a"
  failure: "#3a1414"
  action: "#0f1a12"
  bar: "#0c0e13"
  header: "#161922"
diff:
  add: "#7ee787"
  remove: "#ff7b72"
  addBg: "#12261a"
  addEmphasisBg: "#1d3f28"
  removeBg: "#2a1315"
  removeEmphasisBg: "#4a1b1b"
  syntaxTheme: "tokyonight_night"
tools:
  ghEnhanceTheme: "tokyonight"
font:
  family: "CommitMono Nerd Font"
  icons: "nerd-fonts-status"
```

Semantic mapping is the contract: **green = success/merged/additions, red =
failed/conflict/deletions, amber = pending/retrying, cyan = focus/info,
purple = secondary accent.** Every tool must honor these meanings.

The cockpit consumes generated constants from `tokens.yaml`; do not re-declare a
second color list in `styles.go`.

## 4. Per-tool projection (ship these config fragments)

Put generated/authored fragments under `clients/cockpit/theme/` and install them
(see §7). Examples below use the token values above.

### gh-dash — `theme.colors`
```yaml
theme:
  colors:
    text:
      primary:   "#c8ccd4"
      secondary: "#8b93a1"
      inverted:  "#12141a"
      faint:     "#6b7280"
      warning:   "#ff7b72"   # gh-dash uses "warning" for attention/error → danger red
      success:   "#7ee787"
    background:
      selected:  "#1f2a44"
    border:
      primary:   "#2b2f3a"
      secondary: "#3a3f4b"
      faint:     "#1c1f27"
```

### gh-enhance
`gh-enhance` uses Bubbletint theme ids through `ENHANCE_THEME`, so the generated
projection is `theme/enhance.env`:

```sh
ENHANCE_THEME=tokyonight
```

The cockpit sets this env var when launching `gh enhance`.

### diffnav — `ui:` chrome (body color comes from delta)
```yaml
ui:
  sideBySide: true
  icons: nerd-fonts-status
  colorFileNames: true
  showDiffStats: true
  hideHeader: false        # keep header; match cockpit's titled panes
```

### delta — git config (the linchpin; unifies diffnav + cockpit inline preview)
```gitconfig
[delta]
    syntax-theme = tokyonight_night
    side-by-side = true
    line-numbers = true
    navigate = true
    minus-style                = syntax "#2a1315"
    minus-emph-style           = syntax "#4a1b1b"
    plus-style                 = syntax "#12261a"
    plus-emph-style            = syntax "#1d3f28"
    file-style                 = "#56b6c2" bold
    hunk-header-style          = "#8b93a1"
    line-numbers-minus-style   = "#ff7b72"
    line-numbers-plus-style    = "#7ee787"
```
Ship as `theme/delta.gitconfig`. Inline cockpit previews still run the selected
worktree's `git diff | delta` when `delta` is available and fall back to plain
`git diff`; a future installer can include this fragment from user git config so
external diffnav and inline preview styling are identical.

### cockpit — Glamour (markdown reports)
Reports use a generated `theme/glamour.json` loaded by the cockpit renderer so
headings, code, links, and rules share the same tokens as the rest of the UI.

## 5. Typography & icons

One Nerd Font across everything (diffnav *requires* it for its file-tree icons;
gh-dash uses icons; the cockpit phase rail uses glyphs). Document the chosen font
in the README and `tokens.yaml`. Standardize diffnav on `nerd-fonts-status`
icons. Keep the cockpit's glyph vocabulary (`✓ ● ○ ✗ ↻`) and make sure the same
status→glyph mapping is used in any status column the tools share conceptually.

## 6. Keymap convergence

The tools are already vim-ish; converge on one table and reconfigure where each
tool allows it. diffnav's keys are mostly fixed but happen to align well; gh-dash
and gh-enhance support `keybindings` config; the cockpit is ours.

| Intent | Canonical | cockpit | diffnav | gh-dash / enhance |
|--------|-----------|---------|---------|-------------------|
| move | `j`/`k` | ✅ | ✅ | configurable → set `j`/`k` |
| next/prev item | `n`/`p` | (tabs) | ✅ | map if available |
| open in editor | `o` | ✅ | ✅ (`o`→$EDITOR) | map to editor/browser |
| copy | `y` | ✅ (task id) | ✅ (file path) | `y`/`Y` (pr number/url) |
| search / goto | `/` (cockpit), `t` (diffnav) | `/` | `t` | `/` | reconcile: document both, prefer `/` where settable |
| half-page scroll | `ctrl+d`/`ctrl+u` | ✅ | ✅ | ✅ |
| switch pane/tab | `tab` | ✅ | ✅ | ✅ |
| help | `?` | ✅ | (footer) | ✅ |
| quit | `q` | ✅ | ✅ | ✅ |

Deliverable: a single keymap reference in `cockpit-ui-spec.md`, plus generated
`keybindings:` blocks for gh-dash and cockpit `?`/`ctrl+d/u` coverage. Where a
binding can't be changed (diffnav `t` for search), document the residual
difference rather than forcing it.

## 7. Delivery: one source, installed everywhere

- `clients/cockpit/theme/` holds `tokens.yaml` (authority) + generated fragments:
  `gh-dash.yml`, `enhance.env`, `diffnav.yml`, `diffnav/config.yml`,
  `delta.gitconfig`, `glamour.json`, and `theme_tokens_gen.go`.
- `theme/gen.go` reads `tokens.yaml` and writes all fragments plus the cockpit's
  color constants, so editing one file re-themes the suite.
- Installer remains future work: `foreman-cockpit --install-themes` (or
  `theme/install.sh`) should write each fragment to the tool's config path
  (`~/.config/gh-dash/config.yml`, `~/.config/diffnav/config.yml`, the delta
  gitconfig include, and any future gh-enhance config path). **Do not clobber**
  existing user config: merge only the theme block, or back up first and print a
  diff. Idempotent.
- Cross-launch inheritance is implemented where available: cockpit sets
  `DIFFNAV_CONFIG_DIR` to the packaged `theme/diffnav` dir and `ENHANCE_THEME`
  to the generated Bubbletint theme id when launching handoffs.

## 8. Constraints & residual differences (accept, don't fight)

- Config schemas differ and evolve — **verify gh-enhance keys** and re-check
  gh-dash/diffnav keys against installed versions before shipping.
- Terminal ANSI palette can override truecolor; require a truecolor terminal and
  explicit hex everywhere. Optionally ship a matching terminal theme, or document
  that the terminal's own theme should use the same tokens.
- Some chrome (border glyph style, header layout) isn't configurable per tool;
  match by color and accept minor structural differences.
- gh-dash `warning`/`success`-only text semantics: amber is unused there; map
  attention→danger red. Note it.

## 9. Acceptance — visual QA matrix

Verify each token renders consistently in all four surfaces (screenshot
side-by-side). Check: text primary/secondary/faint, border, selected-row bg,
success/warning/danger, focus/accent, diff add/remove, syntax theme, icon set,
font. A row is "done" only when the same token looks the same in cockpit, dash,
enhance, and diffnav.

Programmatic checks: `tokens.yaml` validates (all color tokens are `#RRGGBB`);
generator output is byte-stable (`go run theme/gen.go` diff clean); cockpit
builds/tests/vet clean (`go test ./...`, `go build ./...`, `go vet ./...`).

## 10. Implementation status

Done in `clients/cockpit/`:

1. `theme/tokens.yaml` + `theme/gen.go` generate cockpit color constants.
2. Generated fragments exist for `gh-dash`, `gh-enhance` env, `diffnav`,
   `delta`, and Glamour.
3. Cockpit loads generated Glamour styles and generated Lip Gloss token
   constants.
4. Handoffs pass packaged theme env for `diffnav` and `gh enhance`.
5. Cockpit keymap covers `?` help and `ctrl+d/u` half-page viewer scrolling.

Remaining future work:

1. Global `--install-themes`/merge workflow for user config paths.
2. Visual screenshot QA across cockpit, dash, enhance, and diffnav.

## 11. Non-goals

- No forking of gh-dash/gh-enhance/diffnav to change non-themeable internals.
- No pty embedding (still tier-3 / out of scope).
- No new backend/API work; this is presentation only.

Sources: [gh-dash theme docs](https://dlvhdr.github.io/gh-dash/configuration/theme/),
[gh-dash.dev](https://www.gh-dash.dev/), [diffnav README](https://github.com/dlvhdr/diffnav),
[delta configuration](https://dandavison.github.io/delta/configuration.html)
