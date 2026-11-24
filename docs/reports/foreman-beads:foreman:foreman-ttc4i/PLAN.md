# PLAN — foreman-ttc4i: SkillResolver must answer `:unverifiable` for an unusable home, not raise

Branch base: `0988b071`. One source file + one test file. No refactors.

## 1. Verdict

**Real bug.** `packages/foreman_server/lib/foreman_server/agent_runtime/jido_harness/skill_resolver.ex:123`:

```elixir
home = Keyword.get_lazy(opts, :home, &System.user_home!/0)
```

`System.user_home!/0` raises `RuntimeError` ("could not find the user home, please set the HOME environment variable") when the home is unknown (verified: `devbox run -- bash -c 'env -u HOME elixir -e "System.user_home!()"'` raises; `System.user_home/0` returns `nil` there).

The raise is **not** caught: `resolve_pi/2`'s `else _ -> :unverifiable` (`:133-135`) only matches *values*, not exceptions. `RunExecutor.kickoff_skill_preflight/1` (`packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:563`, called from `:553`) has no rescue since PR 8 (AGENTS.md 5.2), so the exception kills the executor at kickoff before any claim instead of recording a verdict.

Second, smaller defect on the same line: a caller that passes `home: nil` explicitly gets `nil` from `Keyword.get_lazy/3` (the lazy default only fires on an **absent** key), and `Path.type(nil)` at `:128` raises `FunctionClauseError` — same crash, different exception.

**Correction to the bead/triage text:** the new test must **not** try to unset `HOME`. `System.user_home/0` reads `:init.get_argument(:home)`, captured at VM boot (Elixir 1.20.4 `lib/elixir/lib/system.ex:372-381`); `System.delete_env("HOME")` inside a running test does **not** make it `nil` (verified). So the default branch is not reachable in-process, the test exercises the same guard through an explicit `home: nil`, and the test file stays `async: true` with no env manipulation. Do not add `async: false` and do not touch `System.put_env/delete_env`.

## 2. Root cause

`resolve_pi/2` treats an unknown/unusable home as a programmer error (`user_home!`) while every other unresolvable input in this module answers `:unverifiable` (module doc "Verdicts and the fail-safe rule", `skill_resolver.ex:20-33`). A missing or relative home is an expected input.

## 3. Failing check first

New test in the existing file `packages/foreman_server/test/foreman_server/agent_runtime/jido_harness/skill_resolver_test.exs`, inside the existing `describe "agent directory" do` block (it already holds `test "a relative home is unverifiable even with an absolute agent dir"` at `:488`). Add directly after that test:

```elixir
    # `System.user_home/0` is nil when the VM has no home (HOME unset at boot).
    # That is an expected input, not a bug: it must answer like every other
    # unresolvable input, never raise into the caller's kickoff (foreman-ttc4i).
    test "a home that is nil is unverifiable", ctx do
      put_skill!(Path.join(ctx.agent, "skills"), "fix-issue")

      assert resolve("fix-issue", Keyword.put(ctx.opts, :home, nil)) == :unverifiable
      assert resolve("absent", Keyword.put(ctx.opts, :home, nil)) == :unverifiable
    end
```

Command that shows it failing **before** the edit in §4:

```
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test test/foreman_server/agent_runtime/jido_harness/skill_resolver_test.exs'
```

Expected failure before the fix: `** (FunctionClauseError) no function clause matching in Path.type/1`. Expected after: `53 passed`.

(If `mix` reports missing dependencies, run `devbox run -- bash -c 'cd packages/foreman_server && mix deps.get'` once first. No `DATABASE_URL` is needed for this file.)

## 4. Edits

### Edit 1 — `packages/foreman_server/lib/foreman_server/agent_runtime/jido_harness/skill_resolver.ex`, `resolve_pi/2` (lines 122-136)

Replace lines 122-129, exactly:

```elixir
  defp resolve_pi(skill, opts) do
    home = Keyword.get_lazy(opts, :home, &System.user_home!/0)
    project_root = Keyword.get(opts, :project_root)

    # `~/.agents/skills` and every `~` expansion need an absolute home: a
    # relative one would resolve against the server's cwd, not pi's.
    with :absolute <- Path.type(home),
         {:ok, agent_dir} <- agent_dir(opts, home),
```

with:

```elixir
  defp resolve_pi(skill, opts) do
    project_root = Keyword.get(opts, :project_root)

    # `~/.agents/skills` and every `~` expansion need an absolute home: a
    # relative one would resolve against the server's cwd, not pi's. A home the
    # VM does not know (`System.user_home/0` is nil when HOME was unset at boot)
    # is an expected input, not a bug: it answers `:unverifiable` like every
    # other unresolvable input, and never raises into the caller.
    with home when is_binary(home) <-
           Keyword.get_lazy(opts, :home, &System.user_home/0),
         :absolute <- Path.type(home),
         {:ok, agent_dir} <- agent_dir(opts, home),
```

Leave lines 130-136 (`ctx = %{home: home, ...}` through `end`) unchanged — `home` is now bound by the `with` clause and is still in scope for `ctx`. The existing `else _ -> :unverifiable` already absorbs the non-binary case.

### Edit 2 — same file, moduledoc `## Options` (line 82)

Replace:

```elixir
    * `:home` - the home directory (default `System.user_home!/0`).
```

with:

```elixir
    * `:home` - the home directory (default `System.user_home/0`). A home that
      is nil (HOME unset when the VM booted) or not absolute makes the answer
      `:unverifiable`; it is never an error.
```

### Edit 3 — the test from §3

Add it as written in §3. No other test changes; the module stays `async: true` and `@moduletag :tmp_dir`.

## 5. Verification

```
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors test/foreman_server/agent_runtime/jido_harness/skill_resolver_test.exs test/foreman_server/workflow/run_executor_skill_preflight_test.exs'
devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted'
```

Success means: the skill-resolver file reports **53 passed** (52 before, +1 new), `run_executor_skill_preflight_test.exs` passes unchanged, zero warnings, and `mix format --check-formatted` exits 0.

`run_executor_skill_preflight_test.exs` needs the test database; if it is not up, run it as
`devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test --warnings-as-errors <files>'`
(docker container `foreman-postgres`). Allow >60s for that run.

## 6. Documentation gate

Externally visible identifiers added, removed or renamed: **none**. `SkillResolver.resolve/4`'s signature, verdict atoms (`:available` / `:missing` / `:unverifiable`), the `:home` / `:agent_dir` / `:project_root` options and the `config :foreman_server, :skill_home` key are all unchanged; only a crash becomes an existing verdict.

Greps run: `SkillResolver`, `skill_home`, `user_home` in `CLAUDE.md`, `README.md`, `docs/user-guide.md`, `docs/cli-reference.md`. Hits: `CLAUDE.md:800-822` and `docs/user-guide.md:1935` describe the preflight order and `:skill_home`; both remain accurate (an unresolvable home was already documented as "anything unresolvable is `:unverifiable`"). `user_home` appears in none of the four. **No edits needed in any of the four files.**

`docs/TRD/TRD-2026-a804d1c7-phase-0-durable-execution.md` limitation (xl) (lines 619 and 645) is about an exception from `project_env/1`, a different call site that still propagates — the claim stays true, so per AGENTS.md ("point-in-time specs; leave their claims as written") **do not edit the TRD**.

## 7. Out of scope — do NOT touch

- `RunExecutor` (`run_executor.ex`), including `kickoff_skill_preflight/1`, `skill_resolve_opts/1` and `project_launch_env/1`. No rescue anywhere; no change to how opts are built (it already drops `nil` values).
- The other `System.user_home!/0` call sites (`secret_store/file.ex:57`, `workflow/install.ex:352`, `workflow/asset_catalog.ex:33`, `workflow/run_worktree_layout.ex:36`, `skills/installer.ex:284`). Different beads; leave them raising.
- `agent_dir/2`, `collect_sources/1`, `verdict/2` and every other function in `skill_resolver.ex`.
- The TRD, PRD and the four operator docs (see §6).
- Branch, commits, PR: none of the above is this phase's or the implementer's job beyond the single commit the workflow makes.
