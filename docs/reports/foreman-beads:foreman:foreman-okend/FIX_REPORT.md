**Report written: `Blocked: no plan found`** (sole content, per the phase contract).

Two independent triggers fired:

1. **`PLAN.md` is not on disk at phase start.** It *is* committed at `HEAD` (`52ae3b14`, 149 lines), but the plan phase never wrote it into this run's worktree — `test -f` fails, `find -name PLAN.md` over the whole repo is empty, `git status` shows 14 unrelated untracked files and no deleted entry. I did recover it from the git object (`git restore --source=HEAD`) and read all 149 lines, so the contract's stop condition is about tooling, not a genuinely missing plan. That distinction is recorded in memory, not padded into the artifact.
2. **The plan's own verdict is "no code change"** for 3 of the 4 subjects, so it licenses no edits even when read.

No code, docs, or `PLAN.md` changed on the branch; `HEAD` is still `52ae3b14` with `docs/user-guide.md` byte-identical to `origin/main`. Only untracked file added is the report itself.

**Why I did not implement anything:** `base_ref_policy` (zv8bi, PR #943), `base_sha` on `RunBaseBranchRecorded` (i3qol, PR #945), and `branch.behind_origin` (qdt14, `295155d0`, **no PR**) are all absent from `HEAD` and from `origin/main` — I re-verified that `packages/foreman_server/lib/foreman_server/aggregates/settings.ex:31` `@keys` has no `base_ref_policy` and that `run_base_branch_recorded.ex:23` is still `[:run_id, :base_branch, :repo_id, :sequence]`. Documenting them here would describe flags the server rejects with `{:unknown_setting, :base_ref_policy}` — AGENTS.md §5.2 plausible-looking success — and the prose already exists on those branches, so it would conflict on merge.

**Operator action needed (three items, one urgent):**
- **qdt14 has zero open PR** and carries both the `branch.behind_origin` code and its doc paragraph — that work is at real risk of loss. Open a PR for `foreman/foreman-qdt14/run-0c30344c74abc80ba7c2b40090d98819`.
- Decide whether this bug stays open (PLAN.md's disposition) or this branch cherry-picks `c489c0f3` + `b7b7b974` + `295155d0` and becomes the single doc PR. I asked; no answer arrived, so I held at the contract.
- `fetch-before-run` genuinely has no implementation anywhere and no plan (§4.1 forbids inventing it).
- Tooling bug worth filing: a plan-phase `PLAN.md` commit does not materialise in the next phase's worktree, which sends every `fix` run down the `Blocked` path.

`ask_advisor` and all escalation tools remain unavailable (`contact_supervisor` refuses outside a subagent; `foreman_inbox_send` / `foreman_task_add_comment` are not exposed here), so this report is the only channel that reached you.