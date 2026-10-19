# Documentation discipline — post-mortems and CLI-reference corrections

> Archived verbatim from the former monolithic `AGENTS.md` (2026-10-18) to keep the always-loaded agent context small. Background for the documentation gate summarised in `AGENTS.md` §Documentation Gate.
> Section-number references inside (e.g. "section 4", "§5.4") point at the pre-split `AGENTS.md`; the §5 rules are summarised in `AGENTS.md` and full text is in `typed-boundaries-full.md`.

## Documentation Discipline

Every fix or feature must consider documentation before finalization. Update `CLAUDE.md`, `AGENTS.md`, `README.md`, the Foreman User Guide (`docs/user-guide.md`), and the CLI Reference (`docs/cli-reference.md`) when behavior, commands, workflows, prompts, setup, troubleshooting, or operator expectations change. Keep edits surgical; document only real behavior.

**This is a gate, not a suggestion — it blocks calling the task done, same as
running the tests.** "Consider documentation" was tried and failed: an entire
work-dispatch unification (new command type, retired command type, renamed
MCP tools, changed CLI envelope) shipped with all five doc files unedited,
caught only because the user asked afterward. The fix is mechanical, not a
reminder to be more careful:

1. Before treating any change as complete, list every externally-visible
   identifier your diff added, removed, or renamed — command/event types
   (`"foo.bar"` strings), MCP tool names (`foreman_*`), HTTP routes, CLI
   flags/verbs, env vars, config keys, workflow/prompt names.
2. `grep` each removed or renamed identifier across `CLAUDE.md`, `AGENTS.md`,
   `README.md`, `docs/user-guide.md`, `docs/cli-reference.md`. A hit is a
   stale reference — fix or explicitly annotate it as historical (see below),
   never leave it silently wrong.
3. `grep` each added identifier's *replaced* counterpart (the old name/route
   it supersedes) the same way, so the replacement gets documented in the
   same place the old one was.
4. State which of the five files needed edits and which didn't, and why —
   "no operator-visible change" is a valid reason; silence is not. This
   statement is part of the deliverable, not optional narration.

`docs/PRD/*` and `docs/TRD/*` are point-in-time design specs, not living docs —
leave their historical claims as written even after the code they describe
changes; a short forward-pointer note (as done elsewhere in this file) is
the right fix, never rewriting them to match later reality.

Runtime prompt/workflow safety: after editing bundled source workflows or prompts, run `foreman init --force`. Dispatch paths (`foreman run`, `foreman run --watch`, and direct worker startup) fail fast when installed runtime prompts/workflows are stale.

Verify a CLI command against the Go source or a fresh `go build ./cmd/foreman`, never against whichever `./foreman` binary happens to be on disk. The checked-in root binary is a build artifact and goes stale, so a real command reads as nonexistent: `foreman init --force` is registered at `packages/foreman_cli/cmd/foreman/main.go:94` and covered by `init_test.go`, yet the stale root binary's help omits it entirely and `./foreman init` answers `unknown command "init"`. Do not document a command as missing, or replace it with a substitute, on that evidence — believing a stale artifact over the source is the same error as the `FOREMAN_ARTIFACT_PATH` claim in section 4.

**The same error runs in the opposite direction, and `docs/cli-reference.md` is
where it lives.** That file documented 30 top-level verbs; the Go CLI dispatches
five. Twenty-six — `abandon`, `attach`, `board`, `clean-state`, `debug`,
`doctor`, `import`, `inbox`, `issue`, `logs`, `merge`, `metrics`, `monitor`,
`plan`, `pr`, `purge`, `recover`, `reset`, `retry`, `sentinel`, `server`,
`sling`, `status`, `stop`, `watch`, `worktree` — had full sections with flag
tables, examples and behavioral prose, and none of them route. So did a
fabricated `foreman --help` domain-grouping and deprecated-alias table (`main.go`
has no alias machinery whatsoever), `foreman init -n`/`--wizard` (`init.go`
declares one flag, `--force`), four `*_projections` tables (the repository has
two migrations), and `devbox run dev:up`/`db:up` (not among the 22 scripts in
`devbox.json`). Believing the stale *document* over the source is the identical
failure to believing the stale binary, and it is the more dangerous one, because
a reference file is what an operator or agent reaches for first. It is not
hypothetical: REQ-007 of `PRD-2026-d306444f-phase-commit-control.md` was
specified against the documented `foreman inbox` surface as though it worked and
had to be dropped once the aggregate behind it proved unreachable.

Those sections are annotated, not deleted — they read as a record of intended
design, and one apparent duplicate turned out to carry a command the other did
not (`foreman issue webhook`), so deleting on a glance would have lost content.
The annotations are also the reason the file is now trustworthy about what is
real, which it was not: it still has no section for `task approve`, `task get`,
`task retry`, `run get`, `run cancel`, `run pause`, `run resume`, `run reset`,
`workflow install` or `workflow remove`, all of which exist. `run pause` and
`run resume` are new (unattended-run-control, 2026-09). To re-verify any of
this, read the `switch` in `main.go` and the `case` lists in
`runProject`/`runTask`/`runRun`/
`runWorkflow` — that is the whole surface, and it takes one grep.

