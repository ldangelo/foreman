# Handoff — Attach an `omp` (oh-my-pi) session to a run's worktree

Status: Implemented in `clients/cockpit/` · Date: 2026-07-10 · Owner: Leo D'Angelo
Audience: local coding agent (Go / Bubble Tea)
Related: `docs/design/cockpit-integrations-handoff.md`, `docs/adr/0001-go-clients-elixir-core-runtime.md`, `clients/cockpit/`

Implementation note (2026-07-11): the cockpit implements `p`/`P`, auto tmux vs
inline launch, worktree/active-worker guards, configurable command/args/session
mode, per-task OMP session directories with `--continue` when a prior session is
present, triage brief writing with safe fallback outside the worktree unless
`.foreman/` is gitignored, opening instructions that point at the exact written
brief path, PR/failure/conflict/report/log context, and sensitive-line
redaction. Direct interactive opening-instruction injection stays out of the
launch path; the cockpit writes the brief and prints a read-it-first message
before starting `omp`.

## 1. Objective

From the cockpit, attach an interactive **`omp`** (oh-my-pi) coding-agent session
to the selected run's git worktree, so a human can drive Pi to finish what the
autonomous pipeline couldn't:

- Triage a failed/stuck Foreman run.
- Resolve PR / rebase merge conflicts.
- Fix a broken build / failing CI.
- Address CodeRabbit findings.

Launch it either in a **separate tmux pane** (preferred — cockpit keeps running)
or, when tmux isn't available, **inline** by suspending the cockpit, exactly like
the existing nvim handoff.

Why this fits: `omp` is a fork of the same Pi that Foreman's workers use, so we're
handing the human the identical runtime — operating in the exact worktree/branch
Foreman created. After a fix, the human commits/pushes on that branch and
Foreman's PR reconciliation picks it up (and `r` can re-run the failed phase).

## 2. What `omp` is (verified with `omp --help` 2026-07-11)

- Binary: **`omp`** (Rust terminal coding agent; fork of `@mariozechner/pi-coding-agent`).
- `omp` alone launches the interactive TUI. `omp -p "<prompt>"` answers a single
  prompt and **exits** (non-interactive — do NOT use `-p` for the attach flow).
- Sessions behave like git branches: **resume / fork / branch / share**.
- Interactive launch accepts an initial positional message, but the cockpit does
  not depend on injecting text into the running TUI. It launches `omp` in the
  worktree after writing a briefing file, and the opening instruction printed
  before launch says to read that brief first.

Treat the binary + args as **config** (`integrations.omp.cmd`, default `omp`), so
this works even if the invocation differs.

## 3. Launch modes (mirror the nvim remote/inline split)

Resolve mode from config (`tmux | inline | window | auto`; default `auto`):

- **tmux pane (preferred, non-suspending).** When `$TMUX` is set, split a pane in
  the worktree and launch `omp` there; the cockpit keeps running and refreshing in
  its own pane. This is the "separate tmux pane" the user asked for. Builder:

  ```go
  // omp.go
  func ompTmuxCommand(run Run, brief string, cfg OmpConfig) *exec.Cmd {
      wt := expandHome(run.Worktree)
      inner := shellQuote(cfg.Cmd) + " " + ompOpening(run, brief, cfg)
      if cfg.KeepShell { inner += "; exec $SHELL" } // keep pane after omp exits
      switch cfg.Tmux.Split {
      case "window":
          return exec.Command("tmux", "new-window", "-c", wt, "-n", "omp:"+run.TaskID, inner)
      case "vertical":
          return exec.Command("tmux", "split-window", "-v", "-c", wt, inner)
      default: // horizontal
          return exec.Command("tmux", "split-window", "-h", "-c", wt, inner)
      }
  }
  ```

  Run it as a background `tea.Cmd` (like the remote-nvim branch): the `tmux`
  command returns immediately; emit `ompDoneMsg{}` and set a notice
  ("opened omp in tmux pane"). Do NOT use `tea.ExecProcess` here (no suspend).

- **inline (fallback).** No tmux → `tea.ExecProcess(exec.Command(cfg.Cmd, …))`
  with `cmd.Dir = wt`; suspend the cockpit, run `omp`, resume on exit. Identical
  shape to `openInNvim`'s inline path.

- **`auto`**: tmux when `$TMUX` present, else inline.

- Other multiplexers (zellij, wezterm, kitty) are not part of the closed roadmap.
  The shipped cockpit supports tmux and inline fallback.

## 4. Where it runs + safety

- cwd = `run.Worktree` (already used by the diffnav/files integrations). If the
  worktree is empty/`(cleaned)` (e.g. a merged run), show a notice and don't
  launch — offer nothing destructive.
- **Concurrency guard (important):** do NOT silently attach to a worktree an
  active Foreman worker is writing (`RUNNING`/`in_progress`). Two agents editing
  the same tree corrupts state. Behavior:
  - Best targets: `failed`, `stuck`, `conflict`, `cooldown`, and `RECENT` runs.
  - For an actively-running worker, require a confirmation keypress (or refuse
    with a notice: "run is active — reset/stop it before attaching omp").
- This is a **live, mutating** session (unlike the read-only handoffs). Say so in
  the notice/docs. Never write secrets/tokens into the briefing file.

## 5. Triage context (what makes it useful)

Assemble a briefing from data the cockpit already has and pass it to `omp`. Write
`<worktree>/.foreman/triage-<runID>.md` (ensure `.foreman/` is gitignored in the
worktree; if not, write to a temp dir and point omp at it) containing:

- Task id, run id, current phase, status, and `run.Attention` reason.
- The latest error (from the events/messages the `events`/`summary` tabs use).
- PR URL/state and, for conflicts, the conflicted files (the `files` tab already
  flags `Conflict==true`).
- Relevant report excerpts by failure mode: `CR_CLI_REPORT.md` / `REVIEW.md`
  (CodeRabbit), `FINALIZE_VALIDATION.md` (conflicts), CI log excerpt (build).

Pick the opening instruction by failure mode (a small `switch` on
`run.Attention` / phase):

| Mode (signal) | Opening instruction to omp |
|---------------|----------------------------|
| `merge_conflict` (finalize/merge-resolver) | "Resolve the rebase/merge conflicts in this worktree. See the generated brief for conflicted files, then run `git status` first." |
| `ci_failed` (cicd) | "CI failed. Reproduce the failing build/tests here and fix them." |
| `coderabbit_*` (cli-review) | "Address these CodeRabbit findings (see CR_CLI_REPORT.md): …" |
| generic `failed`/`stuck` | "This Foreman run failed at `<phase>`. Investigate using `<brief-path>` and propose a fix." |

Session identity is keyed by task id using `--session-dir
<state>/foreman-cockpit/omp/<task>`; if that directory already contains an OMP
session file, the launcher adds `--continue` so re-attaching resumes context
rather than starting cold.

## 6. Configuration

Add to `.foreman/config.yaml` `integrations:` and an env override
(`COCKPIT_OMP=auto|on|off`, plus `COCKPIT_OMP_MODE`):

```yaml
integrations:
  omp:
    enable: auto            # auto | on | off (auto = use if `omp` on PATH)
    cmd: omp                # binary/launcher
    mode: auto              # auto | tmux | inline | window
    tmux:
      split: horizontal     # horizontal | vertical | window
    keepShell: true         # keep the tmux pane's shell after omp exits
    session: per-task       # per-task | none  (named/resumable sessions)
    args: []                # extra args
```

Load into an `OmpConfig` on the existing `Integrations` struct; detect the binary
with the existing `toolAvailable`/resolver and `$TMUX` for tmux mode.

## 7. Keymap

| Key | Context | Action |
|-----|---------|--------|
| `p` | a run selected | attach an `omp` session to the run's worktree, seeded with triage context for its failure mode |
| `P` | a run selected | attach a **plain** `omp` session without briefing, for freeform work |

`p`/`P` are implemented and documented in the README + UI spec keymaps.

## 8. Implemented hook points

- `omp.go` owns `OmpConfig`, `resolveOmpMode`, `ompTmuxCommand`,
  `ompInlineCommand`, `buildTriageBrief`, `ompOpening`, and `attachOmp`.
- `model.go` handles the `p`/`P` key cases and `ompDoneMsg`, following the
  `openGhEnhance` / `diffnavDoneMsg` notice pattern.
- The implementation reuses `expandHome`, worktree resolution, and the
  cached tool-availability resolver already in the module.

## 9. Verification coverage

- Builders (`ompTmuxCommand`, `ompInlineCommand`) assert `.Path`/`.Args`/`.Dir`
  across mode, split, keep-shell, and session permutations; the inline path sets
  `Dir`, and the tmux path uses `-c <worktree>`.
- `resolveOmpMode` tests cover `auto`, `$TMUX`, `on/off`, missing binary, and
  missing worktree paths.
- `buildTriageBrief` tests cover failure-mode sections, opening instructions
  with the actual written brief path, and sensitive-line redaction.
- Active-run safeguards are covered so the cockpit does not silently attach to a
  worktree an active worker may be mutating.

## 10. Documentation and verification completed

- `clients/cockpit/README.md` documents `p`/`P`, optional `omp`, the
  `integrations.omp` config block, and that this is a live mutating session.
- `docs/design/cockpit-ui-spec.md` documents the keymap rows and OMP triage
  behavior.
- Tests cover tmux/inline command builders, mode resolution, brief generation,
  session continuation, active-run safeguards, and missing-tool notices.

## 11. Closed non-goals & risks

- No embedding of omp's TUI inside the cockpit (still tier-3 / out of scope); this
  is a pane/handoff launch only.
- No new backend endpoints; brief is built from data the cockpit already fetches.
- zellij, wezterm, and kitty support are excluded external-integration ideas,
  not Go cockpit roadmap features.
- Risks kept in the implementation: worktree contention with an active worker is
  guarded, brief files avoid unignored `.foreman/` paths, launcher flags remain
  configurable for OMP CLI drift, and secrets must never enter briefing files.

Sources: [omp.sh docs](https://omp.sh/docs), [can1357/oh-my-pi](https://github.com/can1357/oh-my-pi), [@mariozechner/pi-coding-agent](https://www.npmjs.com/package/@mariozechner/pi-coding-agent)
