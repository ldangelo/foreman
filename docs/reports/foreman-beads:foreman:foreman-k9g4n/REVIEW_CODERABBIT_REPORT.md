
<analysis>
Phase 3 (coderabbit-review) for the `fix` workflow run-072288707e69fe6c4116585c041d7cdc on bead foreman-k9g4n ("Graceful degradation on fetch failure").

Key orientation facts established:
- `FOREMAN_BASE_BRANCH` is set to `main` (valid, so no Blocked-exit needed on that gate).
- Branch: `foreman/foreman-k9g4n/run-072288707e69fe6c4116585c041d7cdc`; HEAD `a22396d7` "Foreman run ... phase 2", parent `1bb84a33` "[pi] Plan written. No code changed." Parent of those is `f0f3b083` (main tip content).
- Working tree clean at start.
- Report dir `docs/reports/foreman-beads:foreman:foreman-k9g4n/` exists with `PLAN.md` (9779 bytes) and `FIX_REPORT.md` (only 112 bytes — suspiciously small, likely a "Blocked: no plan found" style artifact or minimal content; NOT yet read).
- `coderabbit` CLI is available: `/Users/ldangelo/.local/bin/coderabbit` version 0.9.6.

Critical concern carried forward: the two commits above main appear to be plan-only plus a tiny FIX_REPORT — meaning this run may contain essentially zero implementation code, exactly the recurring failure family recorded in project memory (foreman-7gyd7, foreman-g9mlf, foreman-uvzfs, foreman-ch78x, run-2944c14) where phase 1 reported "Blocked: no plan found" and phases 2-3 reviewed a diff of only report files. The 112-byte FIX_REPORT.md strongly suggests that pattern. I had not yet read FIX_REPORT.md or confirmed the actual diff contents against `main` when the summary was requested; that is the immediate next step, followed by running `coderabbit review --agent --base main` from the worktree root.
</analysis>

<summary>
1. **Primary Request and Intent:**
   Execute phase 3 (`coderabbit-review`) of Foreman's `fix` workflow for task `beads:foreman:foreman-k9g4n`, run `run-072288707e69fe6c4116585c041d7cdc`. Concretely:
   - Run `coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"` from the worktree root, at most **3 rounds**; triage every finding as exactly one of **Fix** (narrowest change, real finding) or **Decline** (stale/wrong/out-of-scope, with one-line reason).
   - Stop early once a round yields no fixed `Critical`/`Major` finding. Fix `Minor`/`Nitpick` only when obviously safe and local.
   - If `coderabbit` is missing from PATH or exits non-zero with an auth error: do not fail the phase, do not retry in later rounds — record command/exit code/message under `## Review engine`, write **no** findings block, finish.
   - Run the narrowest repo-native test command and repo formatter/linter for changed files only (this repo: `devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors'` or the narrowest affected test files).
   - Leave fixes **uncommitted** (Foreman commits the phase itself).
   - Write the report to `/Users/ldangelo/.foreman/worktrees/foreman/foreman-k9g4n/run-072288707e69fe6c4116585c041d7cdc/workspace/docs/reports/foreman-beads:foreman:foreman-k9g4n/REVIEW_CODERABBIT_REPORT.md` with sections in order: **Review engine**, **Rounds**, **Fixed**, **Declined**, **Verification**, then the machine-read findings block, then the risk-judgement block (last thing in file).
   - Findings block rules: exactly once, last-but-one; both marker lines alone at line start, outside any fence; raw JSON between them with exactly keys `schema` = `"foreman.review_findings/1"`, `reviewed`, `findings`. `reviewed: true` only because a review actually ran; no block at all if the review did not run. Each finding: `severity` (critical|major|minor|nitpick), `path` (string), `line` (positive int or null), `description` (one sentence), `disposition` (fixed|declined|open), `source` = `"coderabbit"`. List fixed and declined findings too.
   - Risk block rules: `{"schema": "foreman.risk_judgement/1", "level": "LOW|MEDIUM|HIGH", "rationale": "≤1000 chars, 1-2 sentences"}` between `<!-- FOREMAN_RISK_JUDGEMENT_START -->` / `..._END -->`, raw, unfenced, written once.
   - Underlying bead being fixed: **"Graceful degradation on fetch failure"** — when `git fetch origin <base_branch>` fails (offline, auth, missing remote), emit a visible warning and continue against checkout HEAD instead of blocking the run; record the warning on the run so operators see it. Dimension: robustness; severity: major. Found by automated review of run-8dec153539dbd49ac86c0a25c6bbc698 (bead foreman-ch78x).
   - Optional operator progress updates via `foreman_inbox_send` / `foreman_task_add_comment` if available; continue the phase if denied, and mention the failure in the artifact only if relevant. Per prior session memory, both were unavailable in earlier phases of this family.

2. **Key Technical Concepts:**
   - Foreman: CQRS/event-sourced Elixir umbrella; `packages/foreman_server` (Phoenix is sole HTTP ingress; CommandGateway → CommandRouter → aggregates → events → ProjectionStore), thin Go CLI (`packages/foreman_cli`), `jido_harness` providers, `foreman_client`.
   - Phase-execution engine: `Workflow.Lowering` → `Exec.Engine` (jobsite dispatch door retired); `RunExecutor` drives task claim/complete/fail.
   - Recurring bug family in this repo's recent history: `git fetch origin <base>` at run start hard-fails a run when the remote fetch fails, instead of degrading to checkout HEAD with an operator-visible warning.
   - Project memory (this session's daily log, entry 01a20856) records the plan-phase findings for this very bead: `resolve_declared_base/2` at `lib/.../run_executor.ex:4447` only resolves HEAD; the `git fetch origin <base>` does **not** exist on main (`f0f3b083`); `Exec.Git.fetch_branch/4` (`lib/.../exec/git.ex:568`) has one caller, `Exec.Worktree.sync_branch/3` (`exec/worktree.ex:150`, PR-attach path, must stay fatal). The fetch feature lives on sibling bead **foreman-ylwq0, open PR #942** (branch `foreman/foreman-ylwq0/run-4c8b40838270b2b29b0aeb44d96e26bc`, merge-base = this run's HEAD), which adds `VcsAdapter.fetch_base/3`, `VcsAdapter.Default.fetch_base/3`, `Git.remote_exists?/2`, `resolve_origin_base/2`, `fetch_origin_base/3` returning hard `{:error, {:origin_fetch