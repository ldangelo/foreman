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

## Status at implementation (jobsite/foreman-r3i7, 2026-10-16)

Pipeline run under `ensemble new-feature --foreman` for bead `foreman-r3i7`.
No human was available; every approval decision below was made by the agent
and is recorded with its rationale in
`.ensemble/new-feature/edef56de71cf4a56.json` (`decisions`).

- **Branch / commit**: `jobsite/foreman-r3i7` @ `aea637d2`, base `main`.
- **PR**: [#553](https://github.com/ldangelo/foreman/pull/553) — open, **not merged**
  (merge is a separate operator gate: `foreman run approve-merge` /
  `foreman run merge`; the pipeline's stages stop at "open pull request").
- **Gates**: `implementation_approval` granted, `pr_approval` granted for *open*
  and declined for *merge*.
- **Verification**: `mix test` 3138 passed / 0 failed (13 excluded),
  `mix compile --warnings-as-errors` clean, `mix format --check-formatted`
  clean. No live end-to-end beads dispatch was run — that tier is unproven,
  not assumed.

Shipped: **TRD-001**, **TRD-002**, **TRD-003**, **TRD-005**, and **TRD-004's
requirement satisfied out-of-band** (the installed-manifest inventory was
computed directly over `~/.foreman/workflows` — 18 manifests, zero
provider+unqualified pairs — rather than as the new script TRD-004 named; no
load-time refusal can brick an installed workflow, which is all TRD-004 asked).

Not shipped: TRD-006, TRD-010, TRD-007, and all of PR 3 (TRD-008–011). Beads
`foreman-nlrv`/`foreman-20cw`/`foreman-l9d3`/`foreman-i2yk`/`foreman-36ph`/
`foreman-c34b`/`foreman-yzcu`/`foreman-n1bc` and `foreman-x0ky`/`foreman-73ds`
were **left `open`**: closing them would report merged work, and nothing on
this branch is merged. 0/25 closed remains accurate.
