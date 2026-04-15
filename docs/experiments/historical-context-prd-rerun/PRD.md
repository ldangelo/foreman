# PRD: Historical Context Banner System

**Document ID:** PRD-2026-008
**Version:** 2.1 (Refined)
**Status:** Complete
**Date:** 2026-04-15
**Author:** Planning Agent

---

## Executive Summary

Foreman is migrating from the **beads-first architecture** (beads_rust `br` as the sole task store) to **native task management** (SQLite-backed tasks in `foreman.db`, multi-project support). During this transition, many documents describe the older system state. Readers need an immediate visual signal to distinguish archived design documents from current operating procedures.

**This PRD defines a Historical Context Banner System** that injects standardized notices into archived documents while leaving active operator docs untouched.

---

## Problem Statement

Foreman's `docs/` directory contains three types of documents:

1. **Active operator docs** — current procedures and references
2. **Draft PRDs/TRDs** — describing current work
3. **Legacy and comparison docs** — describing beads-first era

Readers landing on legacy documents (e.g., `migration-seeds-to-br.md`, `Overstory_comparison.md`) have no immediate signal that these describe an older system state. This causes:
- Confusion about current vs. historical behavior
- Operators following archived instructions that no longer apply
- Difficulty onboarding contributors

**Why Now:** TRD-2026-006 (native task management) is actively shipping. This creates a natural archival boundary.

---

## Key Decisions

### Q1: Which Directories Count as Archival?

| Directory | Archival? | Rationale |
|-----------|-----------|-----------|
| `docs/` (root) | **Yes** | Contains legacy comparison docs, migration guides, draft PRDs from beads-first era |
| `docs/PRD/` | **Partial** | Draft PRDs describing beads-first era need banners; PRD-2026-007 describes current architecture (excluded) |
| `docs/PRD/completed/` | **Yes** | Historical PRD artifacts from completed initiatives |
| `docs/TRD/` | **Partial** | TRDs prior to TRD-2026-006 need review; TRD-2026-007 describes current architecture (excluded) |
| `docs/guides/` | **No — Never** | All guides describe current operating procedures |
| `docs/standards/` | **No — Never** | Active standards documents |

**Decision Rule:** Any document that references beads-first as the default/proposed architecture, references `seeds` (`sd`) as an active backend option, or pre-dates the native task management initiative is a candidate for archival status.

### Q2: What Should the Banner Text Say?

| Variant | Trigger | Canonical Text |
|---------|---------|----------------|
| `standard` | Default archival | ⚠️ Historical Context — describes beads-first architecture superseded by native task management (TRD-2026-006) |
| `comparison` | Compares Foreman to external tools | + Comparisons to external tools reflect Foreman at a specific historical point and may be outdated. |
| `migration` | Migration guide | + This migration guide is preserved for historical reference. See TRD-2026-006 for current task management architecture. |
| `beads-rust-only` | Deprecated BeadsRustClient era | + The BeadsRustClient is deprecated. See TRD-2026-019 for deprecation schedule. |

**Exact banner text is maintained in [banner-variants.json](./banner-variants.json).**

**Placement Rules:**
- Immediately after the first Markdown heading (usually H1 title)
- If document has YAML frontmatter (`---`), place after closing `---`
- Uses Markdown blockquote (`>`) for universal renderer compatibility

### Q3: How to Avoid Touching Active Operator Docs?

**Explicit Exclusion List** (never receives banners):

| File/Directory | Reason |
|----------------|--------|
| `docs/guides/` (all files) | Current operating procedures |
| `docs/workflow-yaml-reference.md` | Current operating procedure |
| `docs/troubleshooting.md` | Current operational guidance |
| `docs/cli-reference.md` | Current CLI reference |
| `docs/TEST-PLAN.md` | Current testing strategy |
| `docs/windows-install.md` | Platform setup guide |
| `docs/homebrew-tap-setup.md` | Platform setup guide |
| `docs/PRD/PRD-2026-007-epic-execution-mode.md` | Current epic execution TRD |
| `docs/TRD/TRD-2026-007-epic-execution-mode.md` | Current TRD |
| `docs/TRD/TRD-2026-006-multi-project-native-task-management.md` | Target architecture TRD |
| `docs/PRD/PRD-2026-006-multi-project-native-task-management.md` | Target feature PRD |
| `src/` (any file) | Not documentation |

### Q4: What Acceptance Criteria Prove the System Is Useful and Low-Noise?

**Usefulness Criteria:**

| ID | Criterion | Verification |
|----|-----------|--------------|
| UC-1 | New contributor reading `migration-seeds-to-br.md` immediately understands it describes a past migration | Banner visible on first 5 lines |
| UC-2 | Reader of `Overstory_comparison.md` sees Comparison variant with tool-specific notice | Comparison variant used, not standard |
| UC-3 | Banner text is scannable — no more than 4-6 lines | Visual inspection |

**Low-Noise Criteria:**

| ID | Criterion | Verification |
|----|-----------|--------------|
| LN-1 | Zero banners in `docs/guides/` | `grep -r "Historical Context" docs/guides/` returns empty |
| LN-2 | Banner uses blockquote format — no custom HTML/CSS | Standard Markdown blockquote (`>`) only |
| LN-3 | Banner does not appear on current-era TRDs | Manual verification |

**Functional Criteria:**

| ID | Criterion | Verification |
|----|-----------|--------------|
| FC-1 | Validation script exits 0 when all banners present | Run script |
| FC-2 | Validation script exits non-zero when banner missing | Remove one banner, verify non-zero exit |
| FC-3 | Validation script detects unexpected banners in excluded files | Add banner to active doc, verify error |

---

## Canonical Archival Document List

### Requires Banner (status: archived)

| File | Variant | Status |
|------|---------|--------|
| `docs/migration-seeds-to-br.md` | migration | ✅ Injected |
| `docs/Overstory_comparison.md` | comparison | ✅ Injected |
| `docs/flywheel_comparison.md` | comparison | ✅ Injected |
| `docs/mail-transport-plan.md` | standard | ✅ Injected |
| `docs/PRD.md` | standard | ✅ Injected |
| `docs/PRD/PRD-2026-005-mid-pipeline-rebase-and-shared-worktree.md` | standard | ✅ Injected |
| `docs/TRD/TRD-2026-004-vcs-backend-abstraction.md` | standard | ✅ Injected |
| `docs/TRD/TRD-2026-005-mid-pipeline-rebase.md` | standard | ✅ Injected |
| `docs/TRD/seeds-to-br-bv-migration.md` | comparison | ✅ Injected |

### Explicitly Excluded (active docs — zero banners)

| File/Directory | Reason |
|----------------|--------|
| `docs/guides/` (all) | Active operator docs |
| `docs/workflow-yaml-reference.md` | Active operator doc |
| `docs/troubleshooting.md` | Active operator doc |
| `docs/cli-reference.md` | Active operator doc |
| `docs/TEST-PLAN.md` | Active operator doc |
| `docs/PRD/PRD-2026-006-multi-project-native-task-management.md` | Target feature PRD |
| `docs/PRD/PRD-2026-007-epic-execution-mode.md` | Current epic execution |
| `docs/TRD/TRD-2026-006-multi-project-native-task-management.md` | Target feature TRD |
| `docs/TRD/TRD-2026-007-epic-execution-mode.md` | Current TRD |
| `src/` (all) | Not documentation |

---

## Implementation

### File Structure

```
docs/experiments/historical-context-prd-rerun/
├── PRD.md                      # This document
├── README.md                   # Human-readable summary
├── manifest.json               # Archival document list + exclusions
├── manifest.schema.json        # JSON Schema for manifest validation
├── banner-variants.json        # Canonical banner text for each variant
└── validate-historical-banners.ts  # Validation + injection script

scripts/
└── validate-historical-banners.ts  # (symlink or copy from above)
```

### Validation Script Behavior

```bash
# Validate all banners
npx tsx docs/experiments/historical-context-prd-rerun/validate-historical-banners.ts

# Inject missing banners (dry run shows what would change)
npx tsx docs/experiments/historical-context-prd-rerun/validate-historical-banners.ts --fix

# Exit codes
0 = all validations pass
1 = missing banners or unexpected banners detected
2 = manifest or variants file not found
```

---

## Open Questions (Resolved)

| ID | Question | Disposition |
|----|----------|-------------|
| OQ-1 | Manual vs. auto-generated manifest? | **Manual** — human review per document is correct for this scale |
| OQ-2 | Should `docs/TRD/seeds-to-br-bv-migration.md` get a banner? | **Yes** — apply `comparison` variant |
| OQ-3 | Does the pre-commit hook block or warn? | **Warn locally, fail CI** |
| OQ-4 | How to handle TRDs with frontmatter? | Banner goes after frontmatter `---` closing delimiter |

---

## Milestones

| Milestone | Deliverable | Status |
|-----------|-------------|--------|
| M1 | Manifest created with all ~9 archival docs + exclusions | ✅ Complete |
| M2 | Banners injected into all archived documents | ✅ Complete |
| M3 | Validation script implemented and tested | ✅ Complete |
| M4 | JSON Schema for manifest | ✅ Complete |
| M5 | CI validation step | Pending |
| M6 | Pre-commit hook (warning mode) | Pending |

---

## Changes from v2.0

| Change | Rationale |
|--------|-----------|
| Consolidated Q1-Q4 into single Key Decisions section | Cleaner structure |
| Removed verbose acceptance criteria tables | Simplified for maintainability |
| Added JSON Schema reference | Enables programmatic validation |
| Added explicit file structure | Clarifies where each artifact lives |
| Resolved all Open Questions | Moved to "Resolved" section |
| Updated milestone status | All completed items marked ✅ |

---

*End of PRD*
