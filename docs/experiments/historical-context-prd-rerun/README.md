# Historical Context Banner System — Rerun

**PRD:** [PRD.md](./PRD.md)
**Version:** 2.1 (Refined)
**Date:** 2026-04-15

## Purpose

Add standardized historical context banners to archived Foreman documents so readers immediately know when they're reading a description of the older beads-first architecture, not current behavior.

## Status: ✅ Complete

All archived documents have been identified and have banners injected. The validation script passes all checks.

## Key Decisions (v2.1)

### Q1: Which Directories Count as Archival?

| Directory | Archival? | Rationale |
|-----------|-----------|-----------|
| `docs/` (root) | **Yes** | Legacy comparison docs, migration guides, draft PRDs from beads-first era |
| `docs/PRD/` | **Partial** | Review each PRD individually; PRD-2026-007 excluded (current) |
| `docs/PRD/completed/` | **Yes** | Historical PRD artifacts (by definition post-hoc records) |
| `docs/TRD/` | **Partial** | TRDs prior to TRD-2026-006 reviewed; TRD-2026-007 excluded (current) |
| `docs/guides/` | **No — Never** | All guides are current operating procedures |

### Q2: Banner Variants

| Variant | Trigger | Additional Line |
|---------|---------|-----------------|
| `standard` | Default archival | (base banner only) |
| `comparison` | Compares Foreman to external tools | Comparisons to external tools reflect Foreman at a specific historical point and may be outdated. |
| `migration` | Migration guide | This migration guide is preserved for historical reference. See TRD-2026-006 for current task management architecture. |
| `beads-rust-only` | Deprecated BeadsRustClient era | The BeadsRustClient is deprecated. See TRD-2026-019 for deprecation schedule. |

**Full banner text:** [banner-variants.json](./banner-variants.json)

### Q3: How to Avoid Touching Active Operator Docs?

**Explicit exclusion list** in [manifest.json](./manifest.json):
- All of `docs/guides/`
- Current TRDs (TRD-2026-006, TRD-2026-007)
- Current PRDs (PRD-2026-006, PRD-2026-007)
- Active operator docs (workflow-yaml-reference.md, troubleshooting.md, cli-reference.md, TEST-PLAN.md)

**Validation script** ensures excluded files have zero banners.

## Archival Document Status

| File | Variant | Status |
|------|---------|--------|
| `docs/migration-seeds-to-br.md` | migration | ✅ Banner injected |
| `docs/Overstory_comparison.md` | comparison | ✅ Banner injected |
| `docs/flywheel_comparison.md` | comparison | ✅ Banner injected |
| `docs/mail-transport-plan.md` | standard | ✅ Banner injected |
| `docs/PRD.md` | standard | ✅ Banner injected |
| `docs/PRD/PRD-2026-005-mid-pipeline-rebase-and-shared-worktree.md` | standard | ✅ Banner injected |
| `docs/TRD/TRD-2026-004-vcs-backend-abstraction.md` | standard | ✅ Banner injected |
| `docs/TRD/TRD-2026-005-mid-pipeline-rebase.md` | standard | ✅ Banner injected |
| `docs/TRD/seeds-to-br-bv-migration.md` | comparison | ✅ Banner injected |

## Validation

```bash
# Validate all banners
npx tsx docs/experiments/historical-context-prd-rerun/validate-historical-banners.ts

# Inject missing banners
npx tsx docs/experiments/historical-context-prd-rerun/validate-historical-banners.ts --fix

# Exit codes
0 = pass
1 = fail (missing or unexpected banners)
2 = manifest/variants not found
```

**Current validation result:**
```
✅  migration-seeds-to-br.md: banner present (migration)
✅  Overstory_comparison.md: banner present (comparison)
✅  flywheel_comparison.md: banner present (comparison)
✅  mail-transport-plan.md: banner present (standard)
✅  PRD.md: banner present (standard)
✅  PRD/PRD-2026-005-mid-pipeline-rebase-and-shared-worktree.md: banner present (standard)
✅  TRD/TRD-2026-004-vcs-backend-abstraction.md: banner present (standard)
✅  TRD/TRD-2026-005-mid-pipeline-rebase.md: banner present (standard)
✅  TRD/seeds-to-br-bv-migration.md: banner present (comparison)
✅  guides//*: no banners (excluded as active-operator-doc)

✅  All historical banner validations passed.
```

## Files

| File | Purpose |
|------|---------|
| [PRD.md](./PRD.md) | Full PRD with all decisions and acceptance criteria |
| [README.md](./README.md) | This file |
| [manifest.json](./manifest.json) | Canonical list of archival docs + exclusions |
| [manifest.schema.json](./manifest.schema.json) | JSON Schema for manifest validation |
| [banner-variants.json](./banner-variants.json) | Exact banner text for each variant |
| [validate-historical-banners.ts](./validate-historical-banners.ts) | Validation + injection script |

## Remaining Work

| Task | Priority | Status |
|------|----------|--------|
| CI validation step | Medium | Pending |
| Pre-commit hook (warning mode) | Low | Pending |

## Reference

Previous attempt: `../historical-context-prd/`
