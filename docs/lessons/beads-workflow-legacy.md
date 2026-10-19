# Beads workflow integration (2026-Q3 narrative)

> Archived verbatim from the former monolithic `AGENTS.md` (2026-10-18) to keep the always-loaded agent context small. Older narrative Beads/`bd`/`br` workflow; the current quickstart lives in `beads-runtime-and-dispatch.md`.
> Section-number references inside (e.g. "section 4", "§5.4") point at the pre-split `AGENTS.md`; the §5 rules are summarised in `AGENTS.md` and full text is in `typed-boundaries-full.md`.

## Beads Workflow Integration

This project uses [beads_rust](https://github.com/Dicklesworthstone/beads_rust) (`br`/`bd`) for issue tracking. Issues are stored in `.beads/` and tracked in git.

### Essential Commands

```bash
# View ready issues (open, unblocked, not deferred)
br ready              # or: bd ready

# List and search
br list --status=open # All open issues
br show <id>          # Full issue details with dependencies
br search "keyword"   # Full-text search

# Create and update
br create --title="..." --description="..." --type=task --priority=2
br update <id> --status=in_progress
br close <id> --reason="Completed"
br close <id1> <id2>  # Close multiple issues at once

# Sync with git
br sync --flush-only  # Export DB to JSONL (exits 0 even when it exports nothing)
br sync --status      # Check sync status — the ONLY place COVERAGE DRIFT is reported
```

### Workflow Pattern

1. **Start**: Run `br ready` to find actionable work
2. **Claim**: Use `br update <id> --status=in_progress`
3. **Work**: Implement the task
4. **Complete**: Use `br close <id>`
5. **Sync**: Run the **Session Protocol** block as a single fail-closed script
   (`set -euo pipefail`), not as separate steps — the flush alone reports
   success while exporting a fraction of the DB, and a FAILED flush leaves an
   older certified JSONL that still passes the gate, which compares row counts
   rather than content. Stage `.beads/issues.jsonl` after the flush, never
   before: `br` rewrites it on every mutation.

### Key Concepts

- **Dependencies**: Issues can block other issues. `br ready` shows only open, unblocked work.
- **Priority**: P0=critical, P1=high, P2=medium, P3=low, P4=backlog (use numbers 0-4, not words)
- **Types**: task, bug, feature, epic, chore, docs, question
- **Blocking**: `br dep add <issue> <depends-on>` to add dependencies

### Session Protocol

**Before ending any session, run this checklist:**

```bash
set -euo pipefail       # a failed flush MUST stop the session, not fall through to the gate
git status              # Check what changed
br sync --flush-only    # Export beads changes to JSONL — WRITES .beads/issues.jsonl
br sync --status --json | jq -e '.coverage_drift == false'   # REQUIRED gate, see below
git add <files> .beads/issues.jsonl                         # Stage AFTER the flush, never before
git commit -m "..."     # Commit everything
git push                # Push to remote
```

**Two ordering rules, both learned the hard way in this repo.**

*Stage after flushing.* `br` writes `.beads/issues.jsonl` — not only on an
explicit flush but on EVERY mutation, since auto-flush is on by default
(`--no-auto-flush` opts out). Staging before the flush therefore commits code
while leaving the export unstaged, which happened repeatedly across this
session's commits and had to be corrected by hand each time.

*Fail closed on the flush.* The two commands are independent, so without
`set -euo pipefail` a FAILED flush falls straight through to a gate that can
still pass — because `coverage_drift` compares COUNTS
(`db_exportable_issues` vs `jsonl_unique_ids`), not content. An older export
with all the right ids but stale bodies satisfies it. The gate catches MISSING
ROWS, which is the 23%-export failure below; it cannot catch a stale row, so
the flush actually has to succeed.

One caveat on verifying that, because it bit the check itself: `set -e` is
DISABLED inside a compound command that forms part of a `&&`/`||` list, so
`( set -euo pipefail; br sync --flush-only; ... ) || echo failed` silently
runs the gate anyway. Confirmed both ways — as a real script the failing flush
aborts at exit 1 and the gate never runs; wrapped in `|| true` the following
line executes regardless. Run the block as a script, not as a `||`-guarded
subshell.

**`br sync --flush-only` is not self-verifying, and the coverage gate is not
optional.** The flush prints `Nothing to export (no dirty issues)` and exits
**0** whenever the JSONL's certified hash matches the file on disk — even when
that certified file holds a fraction of the database. `br` tracks the export in
`metadata` (`needs_flush`, `jsonl_content_hash`, `jsonl_size`), so once a
partial JSONL is certified, every later flush is a successful-looking no-op and
the shortfall is invisible to the one command this protocol used to mandate.

This is not hypothetical and it is not a small margin. In this workspace
`issues.jsonl` — the git-tracked source of truth — carried **174 of 752 issues
and 268 of 1122 dependencies**, and had done so across at least the last 8
commits that touched it, while `br sync --flush-only` reported success every
time. Reproduced deliberately in a sandbox: certify a 100-row JSONL against a
754-issue DB and the flush answers "Nothing to export" at exit 0, leaving 654
issues unexported indefinitely.

The danger is that the JSONL is what a rebuild reads. `br sync --merge
--force-jsonl` (and `--import-only --rebuild`) treat it as authoritative, so
running the documented recovery against a silently-partial export DESTROYS
every issue missing from it — here that would have been ~580 issues, ~39 of
them open. Always compare row counts before any JSONL-authoritative recovery;
see `skill://beads-corrupt-db-recovery-safe`.

Detection exists, but in commands the protocol never told you to run:
`br sync --status` prints `COVERAGE DRIFT — JSONL has N unique ids but the
database holds M exportable issues` (exit **0** — do not gate on its status
code), `br sync --status --json` exposes `coverage_drift` plus
`coverage.db_exportable_issues` / `coverage.jsonl_unique_ids`, and `br doctor`
reports `degraded` and exits **1**. The `--json` form is the gate to automate
on because it is the only one that is both machine-readable and specific to
this failure.

On drift, reconcile — do NOT reflexively `--force`:

```bash
br sync --reconcile --dry-run   # lossless preview of what each side holds
br sync --flush-only --force    # DB-authoritative: only after confirming the DB is complete
```

### Best Practices

- Check `br ready` at session start to find available work
- Update status as you work (in_progress → closed)
- Create new issues with `br create` when you discover tasks
- Use descriptive titles and set appropriate priority/type
- Always sync before ending session — and verify the export covered the DB, because a flush that exported nothing still exits 0

---

