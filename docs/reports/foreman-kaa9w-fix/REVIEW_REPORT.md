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

## Manual follow-up review (not the run's own review phase)

The run's review phase above overwrote its own findings with prose, so the PR body had no typed review evidence. This section was added afterwards by an independent manual review of the branch; it is not output of the run's review phase.

**Verdict**: the Go change is correct. For pi the recommended project directory is now `.pi/skills`, the directory pi reads under a project; the global directory stays `$HOME/.pi/agent/skills`, and omp keeps `.pi/agent/skills` for both. The only readers of the recommended directories are `commandsInstall` (project default) and `commands generate --json`. The `usage` text in `main.go` states no skills path, so it needed no change. `go test ./cmd/foreman/... -count=1` passes.

**Install into an existing directory**: `commandsInstall` stats every target file (`<dir>/<id>/SKILL.md`) before writing any, and refuses the whole install unless `--force` is given, so an existing `.pi/skills/foreman-*` skill is not silently overwritten. A directory that exists without a `SKILL.md` in it is written into.

**Docs**: docs/cli-reference.md and README.md were corrected (see the findings); docs/user-guide.md was already updated by the run. CLAUDE.md needed no edit.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "minor", "path": "packages/foreman_cli/cmd/foreman/agent_commands.go", "line": 475, "description": "Only the render-level constant was asserted for the pi install default and nothing ran commandsInstall. TestCommandsInstallPiDefaultWritesProjectSkillsDir was added: it runs the pi install in a temp project, asserts .pi/skills/*/SKILL.md is written and that no .pi/agent directory is created.", "disposition": "fixed", "source": "manual-review"}, {"severity": "minor", "path": "packages/foreman_cli/cmd/foreman/agent_commands.go", "line": 479, "description": "omp still recommends .pi/agent/skills for a project and the omp loader directories are not documented in this repo, so that default is unverified. Left unchanged by this bead; docs/cli-reference.md now states it as the current behaviour.", "disposition": "open", "source": "manual-review"}, {"severity": "minor", "path": "docs/cli-reference.md", "line": 551, "description": "The text said --scope global uses the recommended global skill directory for Pi and OMP when no --target is given, but commandsInstall returns an error for --scope global without --target. Corrected to say --target is required; the Pi/OMP path sentence below it was corrected too (project .pi/skills for pi, global via --target ~/.pi/agent/skills). README.md line 349 named only ~/.pi/agent/skills and was corrected as well.", "disposition": "fixed", "source": "manual-review"}, {"severity": "minor", "path": "packages/foreman_cli/cmd/foreman/agent_commands.go", "line": 476, "description": "RecommendedGlobalDir is read by no production code, only the commands generate --json output. Pre-existing; the value is kept as the correct global pi directory and asserted by the test.", "disposition": "declined", "source": "manual-review"}, {"severity": "minor", "path": "docs/reports/foreman-kaa9w-fix/FIX_REPORT.md", "line": 3, "description": "The fix report describes testify assert derivations that do not exist; the test uses the standard library t.Fatalf and a literal .pi/skills. A run artifact, left as written.", "disposition": "declined", "source": "manual-review"}, {"severity": "minor", "path": "docs/reports/foreman-kaa9w-fix/REVIEW_CODERABBIT_REPORT.md", "line": 1, "description": "The committed phase-3 artifact has no machine-readable block, so the carry-forward into the review phase was empty. A run artifact, left as written.", "disposition": "declined", "source": "manual-review"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "LOW", "rationale": "A one-constant change to the recommended pi project skills directory (.pi/agent/skills to .pi/skills) with a test that runs the install path, plus doc corrections. The install code still refuses to overwrite existing files without --force, and omp and the global pi directory are unchanged."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
