---
name: foreman-doc-gate
description: "Use when a Foreman change may affect documentation, commands, workflows, prompts, setup, troubleshooting, operator expectations, or skill inventory/package behavior."
---

# Foreman Documentation Gate

## When to Use

Use this skill for any fix/feature that changes behavior, commands/flags, workflows, prompts, setup, troubleshooting, operator expectations, runtime assets, or skill inventory.

## Documentation Decision Matrix

- `README.md`: user-facing overview, architecture, installation, feature bullets, quickstart.
- `docs/user-guide.md`: day-to-day operator workflows and expectations.
- `docs/cli-reference.md`: exact commands, flags, side effects, examples.
- `docs/workflow-yaml-reference.md`: workflow YAML schema, phase contracts, artifact/retry/PR behavior.
- `docs/troubleshooting.md`: failure modes, diagnosis, recovery, stale assets.
- `docs/skill-integration.md`: skill inventory, packaging, invocation, impact table.
- `CLAUDE.md`: project architecture/developer conventions when they change.
- `AGENTS.md`: repository-level agent instructions only when the agent operating policy itself changes.

## Report Contract

- Documentation phase writes `{{reportDir}}/DOCUMENTATION_REPORT.md`; do not write it at repository root.
- Update only real behavior; do not document speculative future behavior.
- Keep docs surgical and synchronized with actual command syntax/source behavior.

## This Task's Documentation Rule

- Adding bundled skills must update `docs/skill-integration.md`, `README.md`, `docs/user-guide.md`, `docs/cli-reference.md`, and `CLAUDE.md`; leave `AGENTS.md` unchanged because no repository-level agent policy changes.
