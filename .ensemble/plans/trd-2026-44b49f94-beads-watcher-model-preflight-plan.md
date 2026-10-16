# Bead Plan: TRD-2026-44b49f94 (BeadsWatcher preflight model_not_found)

Scaffolded by `/ensemble-implement-trd-beads --plan --foreman` on 2026-10-15.
Source: `docs/TRD/TRD-2026-44b49f94-beads-watcher-model-preflight.md` v1.0.1
from `docs/PRD/PRD-2026-44b49f94-beads-watcher-model-preflight.md` v1.0.1 (Locked).
TRD slug: `trd-2026-44b49f94-beads-watcher-model-preflight`.

| Level | Bead | Scope |
|---|---|---|
| Epic | foreman-pfta | Implement TRD: Fix BeadsWatcher Preflight `:model_not_found` |
| Story (PR 1) | foreman-7b8b | Correct the catalog matcher without changing what preflight refuses |
| Story (PR 2) | foreman-k9zf | Refuse an unqualified model declaration at load time, with the operator inventory |
| Story (PR 3) | foreman-btpo | Make the next occurrence self-explaining, and make bead eligibility loud |

Task beads (22; each implementation task has an explicit `-TEST` sibling,
`synthesizedTests: 0`):

| TRD id | Bead | Story |
|---|---|---|
| TRD-001 / -TEST | foreman-nlrv / foreman-20cw | PR 1 |
| TRD-002 / -TEST | foreman-l9d3 / foreman-i2yk | PR 1 |
| TRD-003 / -TEST | foreman-36ph / foreman-c34b | PR 1 |
| TRD-004 / -TEST | foreman-x0ky / foreman-73ds | PR 2 |
| TRD-005 / -TEST | foreman-yzcu / foreman-n1bc | PR 2 |
| TRD-006 / -TEST | foreman-e69d / foreman-aj2b | PR 2 |
| TRD-007 / -TEST | foreman-88us / foreman-7uxo | PR 3 |
| TRD-008 / -TEST | foreman-s4kk / foreman-ihe2 | PR 3 |
| TRD-009 / -TEST | foreman-95pt / foreman-03wi | PR 3 |
| TRD-010 / -TEST | foreman-54zt / foreman-7bm7 | PR 3 |
| TRD-011 / -TEST | foreman-armo / foreman-5ffs | PR 3 |

Dependency edges wired: 45/45 from `trd-cli scaffold-plan` (story-blocks-epic,
task-blocks-story, explicit task-depends). `bv --robot-insights`:
`cycle_count: 0`, `Cycles: []`. All 22 task beads carry `foreman-exec`
(`br update --add-label`, never `--labels`).

## Execution waves (`bv --robot-plan`, whole-DB)

Wave 1 (parallel-safe): `foreman-nlrv` (TRD-001, matcher),
`foreman-x0ky` (TRD-004, installed-manifest inventory),
`foreman-s4kk` (TRD-008, watcher outcome split) — the three TRD-scoped beads bv
places in `track-A`. Everything else is blocked behind one of these.
PR 2's validator change (TRD-005) is gated on TRD-004 by design: it is the
breaking change and must not precede the inventory.

## Status at plan completion

0/25 closed, 25 open. No implementation started; no feature branch created;
no PR opened. `implementation_approved` deliberately not set.
