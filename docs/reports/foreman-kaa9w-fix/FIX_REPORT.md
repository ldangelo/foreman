# FIX REPORT — foreman-kaa9w

`foreman commands install --agent pi` recommended a project skill directory pi never reads.

## 1. Root cause

`renderAgentCommands` in `packages/foreman_cli/cmd/foreman/agent_commands.go` had a single
`case "pi", "omp":` arm (main `0f4e38cb` at lines 471-474) that set
`RecommendedProjectDir = ".pi/agent/skills"`. `commandsInstall` uses that field as the default
target for `--scope project` (`agent_commands.go:176`), so `foreman commands install --agent pi`
wrote `<project>/.pi/agent/skills/<id>/SKILL.md`.

`.pi/agent/skills` is the **global** layout (`<agent_dir>/skills`, `agent_dir` defaulting to
`~/.pi/agent`). Under a project, pi reads `<project>/.pi/skills` — as Foreman's own loader already
models in `packages/foreman_server/lib/foreman_server/agent_runtime/jido_harness/skill_resolver.ex:35-37`,
`docs/lessons/executor-isolation-and-vfs.md:78`, and
`docs/TRD/TRD-2026-a804d1c7-phase-0-durable-execution.md:780` (OTD-3). So the install succeeded and
printed a plausible path while the skill stayed invisible to pi. The global recommendation
`$HOME/.pi/agent/skills` (`:474`) is correct and was not touched.

## 2. Change

- `packages/foreman_cli/cmd/foreman/agent_commands.go` — split the shared `case "pi", "omp":` arm
  into `case "pi":` (`RecommendedProjectDir = ".pi/skills"`, global dir unchanged, with a comment
  naming why) and `case "omp":` kept **byte-identical** to the previous values. Rationale: pi's
  project dir is the verified defect; omp's is unverified, so it is deliberately left alone rather
  than changed as collateral.
- `packages/foreman_cli/cmd/foreman/agent_commands_test.go` — added the regression assertions to
  `TestRenderAgentSupportStates` that pin pi's project dir to `.pi/skills` and its global dir to
  `$HOME/.pi/agent/skills`. Rationale: the pre-existing loop only asserted the field was non-empty,
  so it passed with the wrong value.
- `docs/user-guide.md` (~2053-2060) — replaced the sentence pair that documented the mismatch as a
  known defect with the now-correct statement that pi reads `<project>/.pi/skills` and
  `~/.pi/agent/skills` and that the CLI recommends the same. Rationale: documentation gate — the
  text described the bug this change removes.

Diff totals: 3 files, +18 / −5.

## 3. Deviations from the plan

None. All three edits were applied as written in `PLAN.md` §4, in the order given, and the
failing-first check was run as specified in §3.

## 4. Tests

Updated `TestRenderAgentSupportStates` (`agent_commands_test.go`, inserted after the
`claude/pi/omp` loop and before the `codex/opencode` loop; `os` was already imported, no imports added):

```go
pi := renderAgentCommands("pi", specs)
if pi.RecommendedProjectDir != ".pi/skills" {
	t.Fatalf("pi project dir must be the directory pi reads (.pi/skills), got %q", pi.RecommendedProjectDir)
}
if pi.RecommendedGlobalDir != os.ExpandEnv("$HOME/.pi/agent/skills") {
	t.Fatalf("pi global dir must stay $HOME/.pi/agent/skills, got %q", pi.RecommendedGlobalDir)
}
```

- **Failing before:** at unmodified `agent_commands.go`, `go test ./cmd/foreman/ -run
  TestRenderAgentSupportStates -v` failed with
  `pi project dir must be the directory pi reads (.pi/skills), got ".pi/agent/skills"` (exit 1) —
  the failure the plan predicted, at the predicted assertion.
- **Passing after:** same command green (`ok ... 0.339s`), and the whole package is green (below).

No test removed, renamed or weakened; the existing claude/pi/omp non-empty loop and the
codex/opencode loop are unchanged.

## 5. Local verification

```
cd packages/foreman_cli
go test ./cmd/foreman/ -run TestRenderAgentSupportStates -v   # FAIL before the code edit, then ok
go test ./cmd/foreman/...                                     # ok  github.com/fortium/foreman/packages/foreman_cli/cmd/foreman  0.547s   exit 0
gofmt -l cmd                                                  # no output, exit 0
```

`usage_drift_test.go` (the one that parses the dispatch switches and the `usage` const) is part of
`./cmd/foreman/...` and stayed green — this change adds no CLI verb, flag or usage text.

**Documentation gate.** Identifiers this diff makes stale or refreshes: the recommended *project*
skill directory for agent `pi` (`.pi/agent/skills` → `.pi/skills`). Added/removed public names: none
— no route, config key, env var, CLI verb, command/event type or MCP tool was added, removed or
renamed, so `agent_commands.go`, `README.md` and the docs files were grepped rather than reshaped.

- `docs/user-guide.md` — **edited** (it asserted the CLI recommends a dir pi does not read).
- `docs/cli-reference.md` — **no edit needed**: line 558 says `Pi/OMP install to
  ~/.pi/agent/skills/<id>/SKILL.md`, which is the global scope and is still correct; the task also
  ruled this file out of scope.
- `README.md` — **no edit needed**: line 349 says `Pi/OMP skills (in ~/.pi/agent/skills/)`, global
  scope, still correct.
- `CLAUDE.md` — **no edit needed**: no `pi skill` or `.pi/…skills` reference at all.

Post-edit grep confirmation: `.pi/agent/skills` now survives only in the omp arm of
`agent_commands.go`, the global-dir assignments, the two global-scope doc lines above, and
`packages/foreman_server/test/foreman_server/agent_runtime/jido_harness/skill_resolver_test.exs:139`
(out of scope, still true).

## 6. Follow-ups

Intentionally left undone, all matching `PLAN.md` §6:

- **omp's project dir stays `.pi/agent/skills`** — unverified whether omp reads `.pi/skills`; the
  arm split makes it a separate, verifiable change. The PR body must state the arm was split and omp
  was left unchanged for that reason.
- `packages/foreman_server/**` untouched (`skill_resolver.ex` and its tests already model `.pi/skills`
  correctly); Elixir suite deliberately not run per the plan's verification section.
- `docs/TRD/TRD-2026-a804d1c7-phase-0-durable-execution.md:780` still says the CLI "still recommends
  `.pi/agent/skills` for a project". That file is a point-in-time spec and `AGENTS.md` forbids
  rewriting TRD claims; this report and the PR body carry the correction, so an operator can decide
  whether to add a forward-pointer note.
- The plan's note that `~/.foreman/skills` is not scanned by the pi/omp CLIs is unchanged and still
  correct.
- Changes are left **uncommitted** for Foreman to commit as this phase's work; `PLAN.md` was not
  edited or staged by this phase. Suggested PR title:
  `fix(cli): recommend .pi/skills for pi project command install`.
- An operator-level follow-up, out of scope here: `foreman commands install` for an existing pi
  project that previously used the wrong path will leave an orphan `<project>/.pi/agent/skills/`
  tree behind. Nothing in this change migrates or removes it.
