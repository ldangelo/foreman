# CodeRabbit review — foreman-kaa9w-fix

## Review engine

`coderabbit` is on `PATH` (`/Users/ldangelo/.local/bin/coderabbit`, version 0.9.7) and authenticated. Command run from the worktree root, with `$FOREMAN_BASE_BRANCH` set to `main`:

```
coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"
```

Exit code 0, `review_completed`, 0 findings. Two additional invocations were run to make sure the empty result was real rather than the engine silently reviewing nothing (see Rounds).

## Rounds

**Round 1** — `coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"` → exit 0, `review_completed`, `"findings":0`, `totalFiles:5`. Files it actually reviewed: `docs/reports/foreman-kaa9w-fix/FIX_REPORT.md`, `docs/reports/foreman-kaa9w-fix/PLAN.md`, `docs/user-guide.md`, `packages/foreman_cli/cmd/foreman/agent_commands.go`, `packages/foreman_cli/cmd/foreman/agent_commands_test.go`. Findings received: 0. Fixed: 0. Declined: 0.

**Round 2** — base check. Local `main` is stale (39303e89) while the branch is rebased onto `origin/main` (0f4e38cb), so `--base main` and `--base <origin/main tip>` can differ. Re-ran with the exact merge base: `coderabbit review --agent --base 0f4e38cb` → exit 0, `"findings":0`, same 5 files. Findings received: 0. Fixed: 0. Declined: 0.

**Round 3** — `coderabbit review --agent --base "$FOREMAN_BASE_BRANCH" --committed` (ignore any working-tree state, review only committed code) → exit 0, `"findings":0`, same 5 files. Findings received: 0. Fixed: 0. Declined: 0.

**Engine sanity probe (not a product round).** To prove the zero-finding result was not a false clean, I temporarily reverted `RecommendedProjectDir` for pi back to `".pi/agent/skills"` and re-ran the round-1 command. The engine emitted exactly one finding, `severity: major`, `packages/foreman_cli/cmd/foreman/agent_commands.go:475`, "Use the Pi project skills directory." — i.e. it does read this file and does catch this exact defect. A second probe appended a false claim to `docs/user-guide.md`; that produced 0 findings, so prose edits in this diff are simply outside what it flags. Both probes were reverted; the working tree is byte-identical to `HEAD` again (`git diff` empty, `git status` clean). The probe finding is **not** reported as a finding below: it described a mutation I injected, not the code as it is committed.

Stop condition met after round 1 (no Critical/Major finding fixed); rounds 2–3 were confirmation runs.

## Fixed

None. All three rounds returned zero findings against the committed code, and the seeded test plus the CodeRabbit probe both confirm the shipped value is the correct one.

## Declined

None. There were no findings on the real diff to decline.

Out-of-scope observations recorded for the operator, deliberately **not** filed as findings (they are pre-existing and the task prompt names `docs/cli-reference.md` as do-not-edit):

- `docs/cli-reference.md:558` — "Pi/OMP install to `~/.pi/agent/skills/<id>/SKILL.md`". Correct as written (it describes the global scope) and the task prompt says to leave it, so untouched.
- `docs/cli-reference.md:1271` and `:1335` — stale `ompskills` / `ompsync` command names from the Beads `om` → `omp` rename. Unrelated to this run.

## Verification

Ran after the probes were reverted, on the final tree (`cd packages/foreman_cli`):

- `go test ./cmd/foreman/` → exit 0 (`ok foreman/cmd/foreman 0.477s`, coverage 81.1%)
- `go test ./cmd/foreman/ -count=1 -shuffle=on` → exit 0 (`ok 0.568s`)
- `go test ./cmd/foreman/ -run 'TestRenderAgentSupportStates|TestSupportedAgentTypesShape|TestRenderCommandsInstallHint' -v` → exit 0 (all PASS)
- `go test ./... -cover` → exit 0 (`cmd/foreman 81.1%`, `internal/client 86.2%`)
- `gofmt -l cmd` → exit 0, no output (must be run from `packages/foreman_cli`; from the repo root there is no `cmd` dir)
- `go vet ./...` → exit 0
- `go build ./...` → exit 0
- Task-specified VERIFY command verbatim: `cd packages/foreman_cli && go test ./cmd/foreman/... && gofmt -l cmd` → exit 0 (`ok github.com/fortium/foreman/packages/foreman_cli/cmd/foreman 0.505s`, gofmt silent)

Regression proof of the test that phase 2 added: with the pre-fix value restored, `go test ./cmd/foreman/ -run TestRenderAgentSupportStates` fails at `agent_commands_test.go:141` with `pi project dir must be the directory pi reads (.pi/skills), got ".pi/agent/skills"` → exit 1. So the assertion bites; it is not a vacuous pass.

Documentation gate for this phase: this phase changed no identifiers (no routes, config keys, env vars, CLI verbs, tools, or command/event types) — it changed no code at all. Grep of `CLAUDE.md`, `README.md`, `docs/user-guide.md`, `docs/cli-reference.md` for `.pi/agent/skills` / `.pi/skills` found only `README.md:349` and `docs/cli-reference.md:558`, both describing the global directory, which this run did not change. `docs/user-guide.md` was already corrected in phase 2. No doc edits were needed from this phase.

Working tree left clean and uncommitted-by-design: nothing to commit, Foreman's own commit step for this phase will find no changes.

Operator progress note: `foreman_inbox_send` succeeded. `foreman_task_add_comment` failed with "Task external_id is malformed", so no task Work Log comment was written; nothing else in this phase depends on it.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": []}
<!-- FOREMAN_REVIEW_FINDINGS_END -->
<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "LOW", "rationale": "The diff moves one Go CLI default string from .pi/agent/skills to .pi/skills for the pi agent, keeps the global directory untouched, and matches the value pi's own skill resolver reads. CodeRabbit returned zero findings across three base variants, and an injected-reverse probe proved the engine does flag this exact line when wrong. Blast radius is one recommended install path plus a doc sentence and a test."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
