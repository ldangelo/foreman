# Spike E9-SP2: can a fix jobsite attach to the PR head branch and resume the provider session?

Method: a scratch repo (bare `origin.git`, a clone, a linked worktree) driven
with plain `git` (the same commands `Jobsite.Git`/`Worktree` issue), plus a live
`pi` run (`minimax/MiniMax-M2.7-highspeed`, the only working provider here) for
session behaviour. Claude OAuth is expired, so Claude is **UNVERIFIED**.

## Findings (observed)

1. **Branch survives cleanup.** `RunExecutor.cleanup_run_worktree/2` removes the
   worktree, not the branch; the head branch `foreman/<run>/<phase>` still
   exists locally and on origin after cleanup (scratch: `worktree remove` left
   `refs/heads/...` and the pushed origin ref).
2. **Stale checkout today.** After a reviewer pushed one more commit to origin,
   `git worktree add <path> <existing-local-branch>` (exactly what
   `Git.worktree_add/4` does when `branch_exists?/2`) checked out the OLD local
   tip (no `rev` file). A branch that exists only on origin would instead be
   created from repo HEAD by `Worktree.do_create/3` (`resolve_base(nil)`): the
   wrong base. Both are wrong for a fix.
3. **Fetch + fast-forward works.** `git fetch origin <branch>` then, when the
   local tip is an ancestor of `FETCH_HEAD` (`merge-base --is-ancestor`),
   `branch -f`/`merge --ff-only` yields the origin tip; a branch only on origin
   is attached with `worktree add -b <branch> <path> FETCH_HEAD`.
4. **Diverged local branch** (unpushed local commit AND origin ahead): `is-ancestor`
   fails; a plain `Git.push` is a non-fast-forward rejection. Policy: refuse
   with a typed error (`:worktree_create_failed`, "local branch has unpushed
   commits"), never merge/discard silently.
5. **pi sessions are cwd-bound.** A session created in directory A resumes with
   `pi -p --session <id>` from A; from directory B pi prints "Session found in
   different project ... Fork this session into current directory? [y/N]" and
   waits for input: non-interactively that is a hang/abort, not a resume. A
   fresh worktree path therefore CANNOT resume the original session.
6. Claude (`--resume <id>`): **measured, claude 2.1.308 does NOT behave like pi.** It looks a session up by
   id across project directories: a plain `--resume <id>` resumed the SAME session from a git worktree of
   the repo, from an unrelated directory, after the original directory was deleted, and at the recreated
   original path (`scripts/e2e/claude_resume_cwd_probe.sh`, 10 PASS). The design below does not depend on
   it (recreating the worktree at the original path stays correct and sufficient for claude).
7. **Forking is not cwd-bound for either provider** (measured, same session of a deleted directory too):
   `claude --resume <id> --fork-session` and `pi --fork <id>` from another directory answer from the copied
   history with a NEW session id and no prompt; only a plain pi `--session <id>` from another directory
   asks ("Fork this session into current directory? [y/N]", point 5). `adopt --continue --fork` relies on
   this (`AgentRuntime.JidoHarness.ForkSession`).

## Decision

* **GO for resume, only when the fix runs at the ORIGINAL worktree path.**
  `WorktreeCreated` recorded the run's `worktree_path`; the directory is gone
  after cleanup, so the fix jobsite recreates the worktree at the same path
  (`Jobsite` already accepts `path:`; `Jobsite.Spec` forbids it for remote
  callers, the system-spawned fix adds it as a keyword). Same cwd means the
  provider finds its session. If that path is occupied by something that is
  not a worktree of the branch, or no session id was persisted (E0-S1), the
  plan omits `resume_session` and the prompt carries the context instead.
* **NO-GO for resuming across different worktree paths** (pi proven; Claude
  unverified, treated the same). Fallback: new session + context-rich prompt
  (PR checks/comments/base), never an interactive fork.
* **Worktree/Git changes (E9-S3-T1):** `Git.fetch_branch/3` (ref-guarded argv),
  and `Worktree.create(strategy: {:branch, name}, sync_remote: "origin")`:
  fetch; no local branch -> create from the fetched tip; local behind ->
  fast-forward; local diverged -> typed error; a still-registered linked worktree
  for the branch is reused after a fast-forward inside it (clean tree only).
  `sync_remote` is not a remote-callable spec key.
* Provider ids: the fix agent provider/model come from the run's persisted
  `provider_sessions` entry (so the resumed session and the CLI match); absent
  that, from `config :foreman_server, :pr_fix, agent:` then project settings.
