# Documentation Report: FT-001: CLI implement foreman run task command

## Verdict: PASS

## Documentation Updated
- `docs/cli-reference.md` — Updated in prior commits (`e475496a`, `3088ceae`):
  - `foreman run task` section fully documented with all options, examples, and deprecation note
  - `foreman run` section updated: `--skip-explore`/`--skip-review` moved to deprecation notice, `--workflow <name>` flag added
  - `foreman run task` table updated: `--skip-explore`/`--skip-review` removed (now hidden no-ops with deprecation note)
- `docs/workflow-yaml-reference.md` — Updated in prior commit (`e475496a`):
  - Bundled `quick` workflow documented as YAML-first replacement for retired `--skip-explore`/`--skip-review` flags
  - Workflow selection order updated: `--workflow <name>` CLI override now has top priority
- `docs/user-guide.md` — Updated in prior commit (`e475496a`):
  - `foreman run --workflow quick` variant documented in dispatch section

## Documentation Not Needed
- `README.md` — Already had `foreman run task <task-id> <workflow-name-or-path>` example in the "Configuration > Workflow YAML" section (line 852). No user-facing behavior changed — the command existed before this task.
- `CLAUDE.md` — Developer operating rules unchanged. `--skip-explore`/`--skip-review` deprecation is an internal implementation detail; agents don't use these flags.
- `AGENTS.md` — Agent workflow patterns unchanged. Direct task execution (`foreman run task`) bypasses state gates as designed and expected.

## Checks
- Diff reviewed: yes — implementation changes span `e475496a` and `3088ceae`
- User-facing behavior changed: yes — `--skip-explore`/`--skip-review` now hidden deprecation no-ops; `quick` workflow available; `--workflow <name>` override added to `foreman run`
- Workflow/prompt behavior changed: yes — workflow selection order now prioritizes `--workflow <name>` CLI override over labels and task-type mapping

## Summary
The implementation was already complete and committed before this session. All affected documentation was updated in the same PR (`e475496a` + `3088ceae`). The `foreman run task` command has:
- Full CLI reference in `docs/cli-reference.md`
- Context-aware deprecation warnings for `--skip-explore`/`--skip-review`
- Worktree locking, dry-run mode, watch mode, and all project targeting options
- 8 passing tests covering command structure, error handling, state-gating bypass, and deprecation behavior