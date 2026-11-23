# Repo-rules review — run-8dec153539dbd49ac86c0a25c6bbc698 (task `beads:foreman:foreman-ch78x`)

## Review engine

- Reviewer: this phase's own repository-rules pass — `review-repo-rules.md` contract applied to
  the worktree's own conventions file `AGENTS.md` (repo root of this checkout), which is the
  repository-level contributor-guidance file here. No `CONTRIBUTING.md`; `CLAUDE.md` defers to
  `AGENTS.md`.
- Diff range reviewed: `git diff "main...HEAD"` with `FOREMAN_BASE_BRANCH=main` (set, non-empty;
  merge-base `4099cce4d820b64d386298dc902fe1a5e4a697fb`, branch
  `foreman/foreman-ch78x/run-8dec153539dbd49ac86c0a25c6bbc698`).
- What that range actually contains: two files, 44 insertions, both phase artifacts under
  `docs/reports/foreman-beads:foreman:foreman-ch78x/` — `FIX_REPORT.md` (14 lines, sole content
  `Blocked: no plan found`) and `REVIEW_CODERABBIT_REPORT.md` (30 lines). **Zero source, test,
  workflow or documentation changes.** The working tree is clean and `git diff` (uncommitted) is
  empty, so this phase had no implementation to review.
- Carried findings source: `docs/reports/foreman-beads:foreman:foreman-ch78x/REVIEW_CODERABBIT_REPORT.md`
  has **no readable findings block**. Its committed bytes (2638 B, read back with
  `git show HEAD:docs/reports/foreman-beads:foreman:foreman-ch78x/REVIEW_CODERABBIT_REPORT.md`)
  contain neither `FOREMAN_REVIEW_FINDINGS_START` nor `FOREMAN_RISK_JUDGEMENT_START`, even though
  its own prose claims both blocks were written and parser-verified, and claims the file is
  10608 B. The committed text is also visibly damaged — several sentences have tokens dropped out
  (e.g. line 22: "…(10608 B) 5 sections + both machine-read `ReviewFindings.read/1` 1
  `PrRisk.parse_judgement/1` **MEDIUM**"). That is consistent with the previous phase's write
  going through a context-compression proxy rather than from the file it believes it wrote. So
  there was no machine-read findings array to copy; I recovered the single finding from that
  report's prose `## Finding` section and carry it below with `source: coderabbit`.
- Independent review run: none available in this phase (no external review CLI is part of this
  contract). One pass over the range above, then triage, then one re-read.

## Findings

| # | severity | path:line | source | disposition |
| --- | --- | --- | --- | --- |
| 1 | major | `packages/foreman_server/priv/defaults/workflows/fix.yaml:35` | coderabbit | declined (already resolved on this branch — with evidence) |
| 2 | major | `packages/foreman_server/lib/foreman_server/events/run_base_branch_recorded.ex:1` | repo-rules | open (task work is entirely unimplemented) |
| 3 | minor | `packages/foreman_server/priv/defaults/workflows/fix.yaml:27` | repo-rules | declined (pre-existing on `main`, out of this run's scope) |
| 4 | major | `docs/reports/foreman-beads:foreman:foreman-ch78x/REVIEW_CODERABBIT_REPORT.md:1` | repo-rules | open (previous phase's artifact is not machine-readable) |

No fixes were applied. `git diff` remained empty across the whole phase, so the required
re-read of `git diff "main...HEAD"` confirmed the same two-file range and introduced no new
violation.

## Fixed

None. Nothing in the reviewed range was a live violation of `AGENTS.md` that this phase could
narrowly fix — see Declined and the open findings.

## Declined

1. `packages/foreman_server/priv/defaults/workflows/fix.yaml:35` — carried from CodeRabbit:
   `command: "/enseble:merge-pr --foreman"` names a command that exists in no registry.
   **Declined as stale/already-resolved, not as wrong.** Evidence, three ways:
   - The file at HEAD is the prompt-driven 3-phase manifest: lines 28–31 `fix` → `prompt: fix.md`,
     lines 32–36 `coderabbit-review` → `prompt: review-coderabbit.md`, lines 42–46
     `repo-rules-review` → `prompt: review-repo-rules.md` with `stack_pr: true`. There is no
     `command:` key anywhere in the file and no `enseble` string.
   - `md5` of the working-tree file equals `md5` of `main:...fix.yaml` and of
     `origin/main:...fix.yaml` — the file is byte-identical to the base, so it is not even part of
     this run's diff.
   - `grep -rn enseble` over the repo (excluding `_build`/`deps`) hits only this task's own report
     and a historical note at `docs/reports/trd-2026-b9e27ab5-per-project-dispatch-queues-completion-2026-11-20.md:83`,
     which records the same gap being closed earlier by commit `51311def`.
   Editing this file would violate `AGENTS.md` rule 4 (surgical changes — every changed line must
   trace to the request) and rule 3. The previous phase's stated "+13/−5 uncommitted" fix is not on
   disk; the earlier `git --no-pager diff` confirms an empty working tree.
2. `packages/foreman_server/priv/defaults/workflows/fix.yaml:27` — the bundled `fix` workflow has
   no plan phase that produces a `PLAN.md`, yet `priv/defaults/workflows/prompts/fix.md` dispatches
   a planner whose first instruction is to read `PLAN.md`. That is the structural cause of this
   run's phase 1 reporting `Blocked: no plan found`, and it is now recorded as the third-plus
   occurrence across runs (`foreman-7gyd7`, `foreman-uvzfs`, `foreman-g9mlf`, `foreman-ch78x`).
   **Declined for this run:** it is a defect in `fix.yaml` as it already stands on `main`
   (byte-identical here), not something this run's diff introduced or renamed, and adding a plan
   phase plus its prompt is a workflow-vocabulary change that belongs in its own task with its own
   catalog/lifecycle tests. Flagging it silently would be hiding it, so it is listed here as a
   named, dated, operator-visible gap rather than fixed speculatively.
3. `base_ref_policy` / base-SHA design choice — the task's EXPECTED section offers two
   implementations (fetch and base on `origin/<base>`, *or* at minimum record the base SHA and
   surface "N commits behind"). Choosing between them, and giving a new project setting a default,
   is an operator/product decision. `AGENTS.md` working rule 1 says to stop and ask when several
   interpretations exist; `foreman_inbox_send`, `foreman_task_add_comment` and
   `contact_supervisor` are all unavailable in this phase (the first two are not exposed here, the
   last errors outside a subagent context), and `ask_advisor` is unusable in this environment
   (Anthropic OAuth refresh returns 400 `invalid_grant` / "Refresh token expired"). Rather than
   guess a boundary, the unimplemented state is reported as an open finding.

## Verification

Commands run in this phase (worktree root unless noted; every exit code recorded):

| command | exit |
| --- | --- |
| `echo $FOREMAN_BASE_BRANCH` → `main` | 0 |
| `git diff -- "main...HEAD" --stat` (shell form) | 129 — git rejects `diff -- <ref>...<ref>`; re-run below without `--` |
| `git --no-pager diff --stat "origin/main...HEAD"` | 0 — 2 files, 44 insertions |
| `git rev-list --count origin/main..HEAD` / `HEAD..origin/main` | 0 → 14, 0 → 6 |
| `git status --short` and `git --no-pager diff --stat` | 0 — clean tree, empty uncommitted diff |
| `git merge-base main HEAD` | 0 → `4099cce4d820b64d386298dc902fe1a5e4a697fb` |
| `git show HEAD:docs/reports/foreman-beads:foreman:foreman-ch78x/REVIEW_CODERABBIT_REPORT.md` | 0 — 2600 B, no marker lines |
| `grep -rn RunBaseBranchRecorded packages/foreman_server/lib` | 0 — 4 files, payload is `%{run_id, base_branch}` only |
| `grep -rn "base_ref_policy" .` (repo, excl. `_build`/`deps`) | 1 — no matches anywhere |
| `grep -rn enseble …` | 0 — only report/history hits |
| `kata search "base branch fetch origin run worktree" --agent` | 0 — 1 unrelated closed issue; `kata search base_ref_policy` → 0 hits |
| `mix event_store.init` (at `packages/foreman_server`) | 0 — "already initialized" |
| `mix test test/foreman_server/workflow/catalog_test.exs test/foreman_server/workflow/bundled_workflow_models_test.exs` | 0 — **32 passed**, 0 failures |
| `mix run --no-start /tmp/ch78x_parse_check.exs` | 0 — `ReviewFindings.read/1` on the previous artifact → `{:error, {:unreadable, :enoent}}` at that relative path; judgement block absent from its committed bytes |

Full-suite run: not run here. `AGENTS.md` calls for the CI-equivalent suite before finishing; the
narrowest command for the files this phase actually touched is none, because no source file was
edited, so I ran the two workflow-manifest suites that would go red on any `fix.yaml` regression
(32 passed). Test DB env for this worktree: `DATABASE_URL` must be overridden to
`postgres://postgres:postgres@localhost:55432/foreman_test_ch78x` — the ambient
`DATABASE_URL` (port 55434) fails auth, and the suite takes a session advisory lock on
`foreman_test`.

**Open objective, unchanged (operator action required):** the task's own work is not on this
branch. Verified absent four ways — `grep -rn base_ref_policy` → no matches repo-wide;
`ForemanServer.Events.RunBaseBranchRecorded` (`packages/foreman_server/lib/foreman_server/events/run_base_branch_recorded.ex`)
still enforces `[:run_id, :base_branch]` with no commit SHA; the base-resolution path
(`packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:1540-1605` —
`source_branch/1`, `persisted_run_base_branch/1`, `dispatch_run_base_branch/2`, `checkout_branch/1`)
still resolves the base as `JobsiteGit.current_branch/1` on the registered checkout with no fetch,
which is exactly the symptom the task describes; and `foreman project recommend` /
`ProjectRecommendations` gained no "base is N commits behind origin/<base>" check. Remaining:
decide the EXPECTED variant, then implement base refresh + SHA recording + behind-count
surfacing with tests against a local bare remote ahead of the checkout, keeping Jujutsu working.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "major", "path": "packages/foreman_server/priv/defaults/workflows/fix.yaml", "line": 35, "description": "Carried from CodeRabbit: the bundled fix workflow ran command \"/enseble:merge-pr --foreman\", which exists in no command registry; declined because fix.yaml at HEAD and on main is byte-identical prompt-driven 3-phase manifest with no command: key.", "disposition": "declined", "source": "coderabbit"}, {"severity": "major", "path": "packages/foreman_server/lib/foreman_server/workflow/run_executor.ex", "line": 1589, "description": "The task's fix is entirely unimplemented on this branch: resolve_run_base still derives the base from the registered checkout's current branch via JobsiteGit.current_branch/1 with no git fetch of origin/<base>, which is the reported obsolete-base failure.", "disposition": "open", "source": "repo-rules"}, {"severity": "major", "path": "packages/foreman_server/lib/foreman_server/events/run_base_branch_recorded.ex", "line": 1, "description": "RunBaseBranchRecorded still carries only run_id and base_branch, so a run records no base commit SHA and cannot report or detect that its base is behind origin/<base>; the EXPECTED minimum remedy is absent.", "disposition": "open", "source": "repo-rules"}, {"severity": "major", "path": "docs/reports/foreman-beads:foreman:foreman-ch78x/REVIEW_CODERABBIT_REPORT.md", "line": 1, "description": "The previous review phase's committed artifact has no FOREMAN_REVIEW_FINDINGS or FOREMAN_RISK_JUDGEMENT block despite claiming both, and its prose is truncated mid-sentence, so its findings and risk level were machine-unreadable and had to be recovered by hand.", "disposition": "open", "source": "repo-rules"}, {"severity": "minor", "path": "packages/foreman_server/priv/defaults/workflows/fix.yaml", "line": 27, "description": "The bundled fix workflow has no plan phase producing PLAN.md while prompts/fix.md dispatches a planner that must read PLAN.md, the recurring structural cause of Blocked: no plan found phases; declined here as pre-existing on main and outside this run's diff.", "disposition": "declined", "source": "repo-rules"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "HIGH", "rationale": "The branch's whole diff against main is two report files with zero code, zero tests and zero docs, so the run delivers none of the base-refresh fix it was created for and phase 1 ended Blocked: no plan found. The branch base 4099cce4 is also 6 commits behind origin/main, the same stale-base condition the task is about, and the prior phase's artifact shipped without either machine-read block."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
