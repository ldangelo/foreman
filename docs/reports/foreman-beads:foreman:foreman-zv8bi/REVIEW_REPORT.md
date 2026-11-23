

Phase 4 done.

## What I found
`main...HEAD` = 3 report files only, **zero production code** — the bead was unimplemented (phase 2 shipped a 1-line `FIX_REPORT.md`). Plan was this run's own product (commit `9db30e48`), so I implemented the surface rather than reporting an empty run.

## Fixed (repo-rules violations)
- **Feature absent** → implemented `base_ref_policy` (`:origin`/`:checkout`, default `:origin`, stored as strings like `notification_preference`): `Settings` key+validator+`base_ref_policies/0`, `Events.ProjectUpdated` typed field, `ProjectSettings` field, `project_settings_live` select.
- **CLAUDE.md §26** demands flag + settings-table row for a new setting → added `--base-ref-policy` (Go CLI), `docs/user-guide.md:736`, `docs/cli-reference.md:24,330`, `CLAUDE.md:1240`. README has no settings table → no edit (audit/acceptance docs are point-in-time records).
- **MCP silently dropped atom-keyed `:base_ref_policy`** → now `INVALID_PARAMS "Unknown arguments: base_ref_policy"` (new `operator_only_atom_arg/1`; clear stays allowed, matching `repo_allowlist`).
- **Help text promised unimplemented behaviour** → "Registered only: no run reads it yet."
- **user-guide row orphaned** after a blank line (broke the table) → re-seated.
- **Foreman's phase-3 commit clobbered `REVIEW_CODERABBIT_REPORT.md`** and dropped both marker blocks → restored from `c678205f`, rationale rewritten (stored one was a `<<ccr:...>>` placeholder).

## Declined
Atom-keyed `:repo_allowlist`/`:max_repos_per_run` still dropped silently — pre-existing, out of bead scope (new key is loud; that's what review required).

## Open (major)
Setting registered but **inert**: no run/worktree/PR code reads it — consumer is the sibling bead. Docs + CLI help + form say so.

## Verification
`mix format --check-formatted` clean · 129 server tests, 0 failures (aggregate, MCP, live, read-model, replay, coordinator) · `gofmt` clean · `go test ./cmd/foreman` ok · both blocks parse via `ReviewFindings.read/1` (11 findings) + `PrRisk.parse_judgement/1` (MEDIUM).

**Uncommitted** (15 files) — Foreman commits. Operator inbox note + task Work Log sent. Kata `qsfy` closed with test evidence. No PR opened/merged by me (phase owns commit + stack PR).