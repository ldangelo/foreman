# Historical Context Banner System — Experiment Output

## What This Is

This directory contains the complete PRD and implementation artifacts for **PRD-2026-008: Historical Context Banner System**. The goal: add standardized notices to archived Foreman documents so readers immediately know when they're reading a description of an older (beads-first) architecture.

## Files

| File | Purpose |
|------|---------|
| `PRD.md` | Full PRD with all sections, acceptance criteria, open questions, and milestones |
| `manifest.json` | Canonical list of ~10 archival documents with banner variants and statuses |
| `banner-variants.json` | Exact banner text for each of the 4 variants (standard, comparison, migration, beads-rust-only) |
| `validate-historical-banners.ts` | Node script that validates banner presence in archival docs and checks exclusions |
| `README.md` | This file |

## Banner Variants

| Variant | Used for |
|---------|---------|
| `standard` | Default archival docs (PRD drafts, older TRDs) |
| `comparison` | Feature comparison docs (Overstory, Flywheel) |
| `migration` | Migration guides (seeds → br) |
| `beads-rust-only` | Docs describing deprecated BeadsRustClient era |

Canonical banner text:

```markdown
> ⚠️ Historical Context
> This document describes Foreman's beads-first architecture, which has been
> superseded by native task management (TRD-2026-006). Some instructions,
> configurations, or comparisons in this document may no longer reflect
> current behavior.
```

## Archival Document List (from manifest)

**Requires banners (status: archived):**
- `docs/migration-seeds-to-br.md` — Migration
- `docs/Overstory_comparison.md` — Comparison
- `docs/flywheel_comparison.md` — Comparison
- `docs/mail-transport-plan.md` — Standard
- `docs/PRD.md` — Standard
- `docs/PRD/PRD-2026-005-mid-pipeline-rebase-and-shared-worktree.md` — Standard
- `docs/TRD/TRD-2026-004-vcs-backend-abstraction.md` — Standard
- `docs/TRD/TRD-2026-005-mid-pipeline-rebase.md` — Standard

**Review needed (status: review) — do not banner yet:**
- `docs/PRD/PRD-2026-006-multi-project-native-task-management.md` — Standard (borderline; describes target state)
- `docs/TRD/seeds-to-br-bv-migration.md` — Comparison (OQ-3 unresolved)

**Explicitly excluded (active docs, zero banners):**
- All of `docs/guides/`
- `docs/workflow-yaml-reference.md`
- `docs/troubleshooting.md`
- `docs/PRD/PRD-2026-007-epic-execution-mode.md`
- `docs/TRD/TRD-2026-007-epic-execution-mode.md`
- Plus 5 more (see `manifest.json` exclusions list)

## Validation

```bash
# Validate all banners
npx tsx docs/experiments/historical-context-prd/validate-historical-banners.ts

# Inject missing banners
npx tsx docs/experiments/historical-context-prd/validate-historical-banners.ts --fix
```

Exit codes: `0` = pass, `1` = fail, `2` = manifest/variants not found.

## Next Steps

1. **Human review** — Resolve OQ-3 (`docs/TRD/seeds-to-br-bv-migration.md`)
2. **Decision** — Decide on PRD-2026-006 status: banner it as `review` or move to exclusions
3. **Install** — Wire validation into CI; add to pre-commit hook
4. **Inject** — Run `--fix` to add banners to all archived documents
5. **Verify** — Confirm zero banners in active operator docs

## Open Questions (from PRD)

| ID | Question | Disposition |
|----|----------|-------------|
| OQ-1 | Manual vs. auto-generated manifest? | Manual |
| OQ-2 | Does PRD-2026-006's doc get a banner? | No — describe target state |
| OQ-3 | Does `docs/TRD/seeds-to-br-bv-migration.md` get a banner? | Review needed |
| OQ-4 | Banners on `PRD/completed/` docs when moved? | Yes |
| OQ-5 | Pre-commit hook: block or warn? | Warn locally; fail CI |
