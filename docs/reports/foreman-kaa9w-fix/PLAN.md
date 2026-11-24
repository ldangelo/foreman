# PLAN — foreman-kaa9w: `foreman commands install --agent pi` writes to a directory pi never reads

Worktree rebased onto `origin/main` tip `0f4e38cb feat(phase): repo-rules-review (#966)` before analysis.

## 1. Verdict

**Real bug, present on `origin/main` `0f4e38cb`.**

Evidence:

- `packages/foreman_cli/cmd/foreman/agent_commands.go:471-474` — one `case "pi", "omp":` arm sets
  `result.RecommendedProjectDir = ".pi/agent/skills"` (:473) and
  `result.RecommendedGlobalDir = os.ExpandEnv("$HOME/.pi/agent/skills")` (:474).
- `agent_commands.go:176` — `dir = result.RecommendedProjectDir` is the default install target for
  `--scope project`, so `foreman commands install --agent pi` writes `<project>/.pi/agent/skills/<id>/SKILL.md`.
- Foreman's own verified model of pi's loader says the project directory is `.pi/skills`:
  `packages/foreman_server/lib/foreman_server/agent_runtime/jido_harness/skill_resolver.ex:35-37`
  ("`<project>/.pi/skills` … NOT `.pi/agent/skills`"), plus
  `docs/lessons/executor-isolation-and-vfs.md:78` and
  `docs/TRD/TRD-2026-a804d1c7-phase-0-durable-execution.md:780` (OTD-3 1.0.17 correction).
- `docs/user-guide.md:2056-2059` already documents the defect by bead id.

Global dir `$HOME/.pi/agent/skills` is **correct** (pi user dir = `<agent_dir>/skills`, `agent_dir`
defaults to `~/.pi/agent`) and must not change.

## 2. Root cause

`renderAgentCommands` in `packages/foreman_cli/cmd/foreman/agent_commands.go` (case arm at :471)
hard-codes the pi project skill dir as `.pi/agent/skills` — it mirrors the *global* layout instead of
pi's project layout `<cwd>/.pi/skills`. `pi` and `omp` share the arm, so the pi fix cannot be made
without splitting it.

## 3. Failing check first

Edit the existing test `TestRenderAgentSupportStates`
(`packages/foreman_cli/cmd/foreman/agent_commands_test.go:126-148`). Today its pi/omp loop only
asserts `RecommendedProjectDir != ""` (`:134-136`), so it passes with the wrong value.

Insert, immediately **after** the closing `}` of the `claude/pi/omp` loop (i.e. after line 137) and
before the `codex/opencode` loop:

```go
	pi := renderAgentCommands("pi", specs)
	if pi.RecommendedProjectDir != ".pi/skills" {
		t.Fatalf("pi project dir must be the directory pi reads (.pi/skills), got %q", pi.RecommendedProjectDir)
	}
	if pi.RecommendedGlobalDir != os.ExpandEnv("$HOME/.pi/agent/skills") {
		t.Fatalf("pi global dir must stay $HOME/.pi/agent/skills, got %q", pi.RecommendedGlobalDir)
	}
```

`os` is already imported in that test file (it uses `os.MkdirAll`/`os.WriteFile`); do not add imports.

Show it red on unmodified `agent_commands.go`:

```bash
cd packages/foreman_cli && go test ./cmd/foreman/ -run TestRenderAgentSupportStates -v
```

Expected before the fix:
`pi project dir must be the directory pi reads (.pi/skills), got ".pi/agent/skills"` → `FAIL`.

## 4. Edits

### Edit 1 — split the shared arm, change only pi

File: `packages/foreman_cli/cmd/foreman/agent_commands.go`, function `renderAgentCommands`.

Replace lines 471-474:

```go
	case "pi", "omp":
		result.NativeInstallSupported = true
		result.RecommendedProjectDir = ".pi/agent/skills"
		result.RecommendedGlobalDir = os.ExpandEnv("$HOME/.pi/agent/skills")
```

with:

```go
	case "pi":
		result.NativeInstallSupported = true
		// pi's project-scoped skill directory is `<project>/.pi/skills`; `.pi/agent/skills`
		// is the GLOBAL layout (`<agent_dir>/skills`) and is not read under a project.
		result.RecommendedProjectDir = ".pi/skills"
		result.RecommendedGlobalDir = os.ExpandEnv("$HOME/.pi/agent/skills")
	case "omp":
		result.NativeInstallSupported = true
		result.RecommendedProjectDir = ".pi/agent/skills"
		result.RecommendedGlobalDir = os.ExpandEnv("$HOME/.pi/agent/skills")
```

omp's project dir stays `.pi/agent/skills`: it is unverified, and changing it is out of scope.

### Edit 2 — test (as written in §3)

File: `packages/foreman_cli/cmd/foreman/agent_commands_test.go`, after the `claude/pi/omp` loop in
`TestRenderAgentSupportStates`. Keep the existing loop and the codex/opencode loop unchanged.

### Edit 3 — documentation gate

File: `docs/user-guide.md`, lines 2054-2059. Replace the two sentences that describe the defect:

```
for skills. pi reads `<project>/.pi/skills` and `~/.pi/agent/skills`. The CLI
(`packages/foreman_cli/cmd/foreman/agent_commands.go`) recommends `.pi/agent/skills` for a
project, which pi does not read (a known defect, bead `foreman-kaa9w`; the global
recommendation `~/.pi/agent/skills` is correct). `foreman init --force` refreshes workflows and prompts only,
```

with:

```
for skills. pi reads `<project>/.pi/skills` and `~/.pi/agent/skills`, and the CLI
(`packages/foreman_cli/cmd/foreman/agent_commands.go`) recommends the same: `.pi/skills` for a
project and `~/.pi/agent/skills` globally. `foreman init --force` refreshes workflows and prompts only,
```

Preserve the surrounding sentences (`~/.foreman/skills` … `target_dir/1` before it, `never skills. A
skill placed anywhere…` after it) exactly; do not reflow unrelated lines.

Gate result for the other three files (checked, **no edit needed**):

- `docs/cli-reference.md:558` — "Pi/OMP install to `~/.pi/agent/skills/<id>/SKILL.md`": global dir,
  still correct. Task explicitly says do not edit.
- `README.md:349` — "Pi/OMP skills (in `~/.pi/agent/skills/`)": global dir, still correct.
- `CLAUDE.md` — no `.pi/agent/skills` / `.pi/skills` hit.

## 5. Verification

```bash
cd packages/foreman_cli
go test ./cmd/foreman/ -run TestRenderAgentSupportStates -v   # must now PASS
go test ./cmd/foreman/...                                     # all PASS
gofmt -l cmd                                                  # no output
```

Success = the new assertions pass, the whole `./cmd/foreman/...` package is green (notably
`usage_drift_test.go`, which parses the dispatch switches — no CLI verb or usage text changes here,
so it must stay green), and `gofmt -l cmd` prints nothing.

PR title: `fix(cli): recommend .pi/skills for pi project command install`.
PR body must state that the `pi`/`omp` arm was split and **omp was left unchanged** because its
project dir is unverified.

## 6. Out of scope

- `packages/foreman_server/**` — including `skill_resolver.ex` and its tests; they already model
  `.pi/skills` correctly.
- `docs/cli-reference.md`, `README.md`, `CLAUDE.md`, `docs/TRD/**`, `docs/PRD/**`,
  `docs/lessons/**` — point-in-time or already-correct text.
- The omp project directory, the global directory for either agent, the claude/codex/opencode arms.
- `.beads/`, `docs/reports/**` (this plan file is written by the planning phase only; the
  implementer must not add plan or report documents to the PR).
- No refactor of `renderAgentCommands`, no new flag, no change to `commandsInstall` defaulting logic
  at `agent_commands.go:170-180`.
- Do not run the Elixir suite or the full Go repo build; only the commands in §5.
