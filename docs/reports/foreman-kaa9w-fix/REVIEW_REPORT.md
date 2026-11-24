# Review Report — foreman-kaa9w-fix (phase 4, repo-rules-review)

## Review engine

Repository-rules reviewer: this phase, reviewing the run's own diff against the
repository's contributor rules in `AGENTS.md` (Working Rules, Documentation
Gate, Typed Boundaries §5) and against the established patterns in the files
the diff touches.

Diff range reviewed: `git diff 0f4e38cb...HEAD` — `0f4e38cb` is the tip of
`origin/main` and is the merge-base of `HEAD` (`0f13c6e2`). `$FOREMAN_BASE_BRANCH`
is `main`, but the local `main` ref in this worktree is stale at `39303e89`, so
`git diff main...HEAD` also carries three upstream commits that are not this
run's work; the diff base was corrected to `origin/main` and only those three
commits were dropped. Those three commits are unrelated to this diff: they
change `docs/user-guide.md`'s "Work with project memory" section, add
`packages/foreman_server/lib/foreman_server/project_memory*.ex` and
`test/foreman_server/project_memory*_test.exs`, and modify
`lib/foreman_server_web/{layouts.ex,project_workspace_live.ex}`,
`workspace/{inline_composer.ex,memory_panel.ex}` — none of them touch
`agent_commands.go`, `agent_commands_test.go`, or
`docs/user-guide.md:2050-2058` (the run's own edit is at 2054-2058). No overlap
with this run's edits, so no conflict review was needed.

Files in this run's diff (6): `docs/reports/foreman-kaa9w-fix/FIX_REPORT.md`,
`PLAN.md`, `REVIEW_CODERABBIT_REPORT.md`, `docs/user-guide.md`,
`packages/foreman_cli/cmd/foreman/agent_commands.go`,
`packages/foreman_cli/cmd/foreman/agent_commands_test.go`.

Carry-forward from the previous phase: `docs/reports/foreman-kaa9w-fix/REVIEW_CODERABBIT_REPORT.md`
as committed at `HEAD` is a 20-line prose-only document with **no readable
`foreman.review_findings/1` findings block and no risk-judgement block**, so
there was nothing machine-readable to carry forward. Its prose states it ran the
real CodeRabbit CLI and reported "no findings to report; no fixes needed", which
is consistent with carrying zero findings. Recorded as a finding below.

## Findings

Six findings, all raised by this review (`source: repo-rules`); none carried
forward (the previous phase's report has no block). One fixed, three declined,
two left open for the operator.

| # | severity | location | disposition |
| --- | --- | --- | --- |
| 1 | minor | `packages/foreman_cli/cmd/foreman/agent_commands.go:475` | fixed |
| 2 | minor | `packages/foreman_cli/cmd/foreman/agent_commands.go:479` (omp) | open |
| 3 | minor | `docs/cli-reference.md:551` | open |
| 4 | minor | `packages/foreman_cli/cmd/foreman/agent_commands.go:476` (`RecommendedGlobalDir`) | declined |
| 5 | minor | `docs/reports/foreman-kaa9w-fix/FIX_REPORT.md:3` | declined |
| 6 | minor | `docs/reports/foreman-kaa9w-fix/REVIEW_CODERABBIT_REPORT.md:1` | declined |

After fixing, the diff was re-read once (`git diff 0f4e38cb...HEAD` plus the
uncommitted working-tree diff). The only new change is a test function; it adds
no production code, no new dependency, no new config key, route, CLI verb or
env var, so it does not re-trigger the Documentation Gate and introduces no new
violation of the same rules.

## Fixed

**1. `packages/foreman_cli/cmd/foreman/agent_commands_test.go:158` — the fix
changed a directory the CLI writes to, but no test executed the install path.**

What was wrong: the run's production change is the value that
`foreman commands install --agent pi` uses as its default write target
(`agent_commands.go:475` → consumed at `agent_commands.go:176` as
`dir = result.RecommendedProjectDir`). The only assertion the run added checks
the value returned by `renderAgentCommands("pi", …)`. Nothing executed
`commandsInstall` for pi, so a regression that restored `.pi/agent/skills` as
the project default — the exact bug this run fixes — would still pass the whole
suite, because the render-level assert and the install path are separate
statements. `AGENTS.md` Working Rule 5 ("Turn the task into a verifiable check:
failing test → passing test") is the rule this violates for a change whose whole
point is where bytes land on disk.

What changed: added `TestCommandsInstallPiDefaultWritesProjectSkillsDir`, which
runs the real command with no `--target` and default `--scope project` inside a
temporary project directory, asserts it writes at least one
`.pi/skills/<id>/SKILL.md`, and asserts it creates no `.pi/agent` directory at
all. `HOME` is pinned to a temp dir so the global-dir expansion is
deterministic; nothing outside the temp dirs is touched.

Failing-first evidence: with `agent_commands.go` temporarily reverted to its
pre-fix version (`git show e4a54380^:packages/foreman_cli/cmd/foreman/agent_commands.go`,
the shared `case "pi", "omp":` arm), the new test fails —

```
agent_commands_test.go:177: pi install wrote no skills under /var/folders/.../.pi/skills
```

After restoring the file (`git diff` confirmed empty against `HEAD`), it passes.
This is the behaviour-level check the run was missing; the pre-existing
render-level assertion is kept as-is.

## Declined

**4. `packages/foreman_cli/cmd/foreman/agent_commands.go:476` —
`RecommendedGlobalDir` is set for pi but no production code reads it.** Finding:
`commandsInstall` uses only `RecommendedProjectDir`; with `--scope global` and
no `--target` it returns the error
`foreman commands install: --scope global requires --target with a verified global command directory`
instead of using the recommended global dir, so the field's only consumer is the
`commands generate --agent pi` JSON output. This matches §5's "a declared value
that no code actually reads". Declined: it is pre-existing, introduced by
`3302b6c6` / `5625c632`, not by this diff — this run only re-stated the same
`os.ExpandEnv("$HOME/.pi/agent/skills")` expression for pi, and the value is
still legitimately surfaced through `commands generate`. Fixing the dead path is
a separate change.

**5. `docs/reports/foreman-kaa9w-fix/FIX_REPORT.md:3` — the fix report
describes test code that is not in the branch.** Finding: it says
`agent_commands_test.go:127` gained "`piProjectDir` … plus
`assert.Equal(t, ".pi/skills", piProjectDir)`" and that the pi project dir is
now derived "via the same `globalDir + "/agent/skills"` expression". Neither is
in the committed file: `TestRenderAgentSupportStates` uses stdlib
`t.Fatalf` comparisons with no `piProjectDir` variable, testify is not a
dependency of `packages/foreman_cli` at all (no `testify` in `go.mod` or
`go.sum`), and the pi project dir is the literal `".pi/skills"`, not derived
from `globalDir`. Documentation that misdescribes the diff is a Documentation
Gate hit. Declined: this phase must not edit `docs/reports/`, and the report's
substantive claims (root cause, files changed, red-then-green, doc-gate results)
are all accurate against the code. Operator note: correct those two clauses when
the PR is reviewed; the code is right, the prose is wrong.

**6. `docs/reports/foreman-kaa9w-fix/REVIEW_CODERABBIT_REPORT.md:1` — the phase-3
artifact has no machine-readable blocks.** Finding: the committed file (20 lines)
contains no `foreman.review_findings/1` or `foreman.risk_judgement/1` block, so
Foreman's parser reads neither its findings nor its risk claim, and the phase
explicitly asks for its findings block to carry forward. Declined: the file is
committed, `docs/reports/` is off-limits to this phase, and its prose reports
zero findings, so the carry-forward set is empty either way and no finding is
concealed by leaving it as is.

## Open (operator action needed, out of this run's scope)

**2. `packages/foreman_cli/cmd/foreman/agent_commands.go:479` — omp still
recommends the project dir `.pi/agent/skills`.** The run split the shared
`case "pi", "omp":` arm and, correctly per its task, carried omp's previous
values verbatim. omp's real skill-lookup directories are documented nowhere in
this repository (unlike pi, which is documented in
`packages/foreman_server/lib/foreman_server/agent_runtime/jido_harness/skill_resolver.ex:35-37`
and `docs/lessons/executor-isolation-and-vfs.md:78`), so the same class of bug
may exist for omp and cannot be confirmed or denied from here. Needs a follow-up
bead to verify omp's loader paths.

**3. `docs/cli-reference.md:551` — documented global-scope behavior contradicts
the code.** It states "For Pi and OMP agents, `--scope global` uses the
recommended global skill directory when no `--target` is specified", but
`agent_commands.go:173-175` returns an error in exactly that case. Pre-existing
(same commit that added `--scope global`, `3302b6c6`) and not introduced by this
diff; the task also names `docs/cli-reference.md` as a do-not-touch file. Needs a
follow-up doc fix.

## Verification

All commands run from `packages/foreman_cli`. Full output in the phase log; exit
codes below.

| command | exit |
| --- | --- |
| `go test ./cmd/foreman/...` | 0 (`ok foreman/cli/cmd/foreman 0.512s`) |
| `go test ./cmd/foreman/ -count=1 -shuffle=on` | 0 (`ok 0.584s`) |
| `go vet ./cmd/foreman/` | 0 |
| `gofmt -l cmd` | 0 (no output) |
| `go test ./cmd/foreman/ -run TestCommandsInstallPiDefaultWritesProjectSkillsDir -v` | 0 (PASS) |
| same test with `agent_commands.go` reverted to `e4a54380^` | 2 (FAIL, red first) |
| `go build ./...` | 0 (run earlier, before this phase's edit) |

Formatter/linter: `gofmt -l cmd` is the repository's own Go format gate and
reports nothing. `go build`/`go vet` clean, so no new compile or vet warnings
(`AGENTS.md` §5.5). The full Elixir suite was deliberately not run: this phase
touched only a Go test file, and `AGENTS.md`'s full-suite gate is scoped to
`packages/foreman_server`.

Documentation Gate (AGENTS.md) for this phase's edit: the only externally visible
identifier touched is a Go test function name, which is not externally visible.
Grep results: `foreman commands install` / `.pi/agent/skills` / `.pi/skills` in
`CLAUDE.md` (0 hits), `README.md` (generic install only, no skill paths),
`docs/cli-reference.md:549-558` (global dir only, which the run did not change),
`docs/user-guide.md:2054-2058` (already corrected by phase 2). Nothing to edit
for this phase's change. The pre-existing `stale` hits under `docs/TRD/*` and
`docs/PRD/*` are point-in-time specs, which `AGENTS.md` says to leave as written.

Note on status updates: `foreman_inbox_send` and `foreman_task_add_comment` were
not available as tools in this phase, so no operator progress notes were sent.

Note on the `.beads/` premise in the phase input: this run worktree is a git
sparse checkout that excludes `.beads/` (`core.sparseCheckout=true`,
`.git/info/sparse-checkout` = `/*`, `!/.beads/`, `!/.beads/**`, and all four
tracked `.beads/` files marked skip-worktree). The directory was absent from disk
while `git status --porcelain` was empty, so a clean status here does **not**
prove `.beads/` matches `HEAD` — the phase's stated premise about `.beads/` is
inaccurate for run worktrees. The four files were restored from `HEAD`
(sha256-verified byte-identical: `d04f84375922190a0ab612556f65f72b67af891d116b6b44c4dd292921e87713`,
`79dd56392cd0fc984c32643e0f95a3f59c29585770391be7e2de96136159a677`,
`235a613695b9349c541d3d5dbeb0cdf862931340e341a95129356ae3a6c87573`,
`17221529804c317c2396c92fc664ba2ed85229833250026b2390b35df3174139`)
and then removed again, with the skip-worktree flags and sparse pattern left
exactly as Foreman created them, so the worktree is unchanged by this review
apart from the test file. `contact_supervisor` is unavailable in this phase
("works only inside a subagent"), so that recommendation could not be escalated.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "minor", "path": "packages/foreman_cli/cmd/foreman/agent_commands.go", "line": 475, "description": "The run changed the directory `foreman commands install --agent pi` writes to but only asserted the value returned by renderAgentCommands, so no test executed commandsInstall and a regression back to `.pi/agent/skills` would pass the suite.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "packages/foreman_cli/cmd/foreman/agent_commands.go", "line": 479, "description": "The omp arm still recommends the project dir `.pi/agent/skills`, and omp's real skill-lookup directories are documented nowhere in this repository, so the same class of bug may remain for omp.", "disposition": "open", "source": "repo-rules"}, {"severity": "minor", "path": "docs/cli-reference.md", "line": 551, "description": "It states `--scope global` uses the recommended global skill directory when no `--target` is given, but agent_commands.go:173-175 returns an error in exactly that case; pre-existing and the file is out of this run's scope.", "disposition": "open", "source": "repo-rules"}, {"severity": "minor", "path": "packages/foreman_cli/cmd/foreman/agent_commands.go", "line": 476, "description": "RecommendedGlobalDir is set for pi but no production code reads it, since a global install without `--target` errors out, leaving `commands generate` JSON as its only consumer; pre-existing, not introduced by this diff.", "disposition": "declined", "source": "repo-rules"}, {"severity": "minor", "path": "docs/reports/foreman-kaa9w-fix/FIX_REPORT.md", "line": 3, "description": "The fix report describes testify `assert.Equal` assertions, a `piProjectDir` variable and a `globalDir + \"/agent/skills\"` derivation that are not in the committed code, which uses stdlib t.Fatalf checks and the literal `\".pi/skills\"`.", "disposition": "declined", "source": "repo-rules"}, {"severity": "minor", "path": "docs/reports/foreman-kaa9w-fix/REVIEW_CODERABBIT_REPORT.md", "line": 1, "description": "The phase-3 artifact as committed has no machine-readable findings or risk-judgement block, so Foreman cannot read its result and there was nothing to carry forward.", "disposition": "declined", "source": "repo-rules"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "LOW", "rationale": "This phase added one Go test function and touched no production code, no config, no routes and no docs, so the only behavior change in the run remains the pi project skill dir `.pi/agent/skills` to `.pi/skills`, which the new test now proves at the install path and which matches Foreman's own pi loader documentation. The added test is hermetic (temp HOME and temp cwd, no network, no writes outside temp dirs) and the whole Go package, vet and gofmt are green. Residual risk is that omp's unverified project dir may carry the same bug, which this run deliberately left alone."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
