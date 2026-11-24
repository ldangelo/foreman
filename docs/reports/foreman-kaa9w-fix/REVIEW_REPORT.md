Phase 4 (repo-rules-review) done. Report written, fixes uncommitted for Foreman.

**Diff base corrected**: local `main` ref in this worktree is stale (`39303e89`), so `git diff main...HEAD` would have swept in 3 unrelated upstream commits. Reviewed `git diff 0f4e38cb...HEAD` (origin/main tip = merge-base, HEAD `0f13c6e2`, 6 files).

**Findings (6, all `repo-rules`)**
- **fixed (minor)** `agent_commands.go:475` — pi install default changed but only the render-level constant was asserted; nothing ran `commandsInstall`. Added `TestCommandsInstallPiDefaultWritesProjectSkillsDir` (`agent_commands_test.go:158`): runs `foreman commands install --agent pi` in a temp project, asserts `.pi/skills/*/SKILL.md` written and **no** `.pi/agent` created. Red first against pre-fix code (`pi install wrote no skills under …/.pi/skills`), green after.
- **open (minor)** `agent_commands.go:479` — omp still recommends `.pi/agent/skills`; omp loader dirs undocumented in-repo → operator follow-up.
- **open (minor)** `docs/cli-reference.md:551` — says `--scope global` uses recommended global dir w/o `--target`; code errors instead. Pre-existing, file off-limits → operator follow-up.
- **declined (minor)** `agent_commands.go:476` — `RecommendedGlobalDir` read by no production code (only `commands generate --json`); pre-existing.
- **declined (minor)** `FIX_REPORT.md:3` — report describes testify `assert.Equal`/`piProjectDir`/`globalDir + "/agent/skills"` derivation that don't exist (stdlib `t.Fatalf`, literal `".pi/skills"`, no testify dep); `docs/reports/` off-limits.
- **declined (minor)** `REVIEW_CODERABBIT_REPORT.md:1` — committed phase-3 artifact has no machine-readable block ⇒ **carry-forward was empty** (prose claims 0 findings).

**Verify**: `go test ./cmd/foreman/...` ok 0.512s · `-count=1 -shuffle=on` ok 0.584s · `go vet` ok · `gofmt -l cmd` empty · JSON/marker parse checked with python (6 findings, keys valid, blocks unfenced, risk block last, LOW).

**Artifact**: `docs/reports/foreman-kaa9w-fix/REVIEW_REPORT.md` (untracked). Kata issue `9j71` created, commented, closed with test evidence.

Two notes: `foreman_inbox_send`/`foreman_task_add_comment` not exposed this phase (no progress notes sent); `.beads/` is sparse-checkout-hidden in this worktree, so a clean `git status` does **not** prove `.beads/` matches HEAD — files restored from HEAD then re-hidden exactly as Foreman created them.