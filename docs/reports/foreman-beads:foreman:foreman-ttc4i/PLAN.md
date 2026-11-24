Plan written. No code touched.

**Verdict: real bug.**

- `skill_resolver.ex:123` `Keyword.get_lazy(opts, :home, &System.user_home!/0)` raises `RuntimeError` when VM has no home; `resolve_pi`'s `else _ -> :unverifiable` (`:133-135`) matches values, not exceptions → crash propagates through `RunExecutor.kickoff_skill_preflight/1` (`run_executor.ex:563`).
- Second path on same line: explicit `home: nil` bypasses lazy default → `Path.type(nil)` → `FunctionClauseError`. Both verified in devbox.
- **Correction to the bead's prescribed test:** `System.user_home/0` reads `:init.get_argument(:home)`, captured at VM boot — `System.delete_env("HOME")` in a test does NOT yield nil (verified). So "test with HOME unset" is not reachable in-process; plan uses explicit `home: nil`, keeps the file `async: true`, no env mutation.
- Fix: one `with home when is_binary(home) <- Keyword.get_lazy(opts, :home, &System.user_home/0)` clause + moduledoc `:82` + 1 test. Baseline confirmed green: 52 passed.
- Doc gate: zero externally visible identifiers changed; greps of `SkillResolver`/`skill_home`/`user_home` in CLAUDE.md, README.md, user-guide.md, cli-reference.md → existing text stays accurate, no edits. TRD limitation (xl) is about `project_env/1`, still true → not edited.

Artifact: `docs/reports/foreman-beads:foreman:foreman-ttc4i/PLAN.md` (134 lines). Only untracked change in tree. `foreman_inbox_send`/`foreman_task_add_comment` not exposed in this phase; no progress notes sent.