# PRD: Historical Context Banner System for Archived Documentation

**Document ID:** PRD-2026-008
**Version:** 1.0
**Status:** Draft
**Date:** 2026-04-15
**Author:** Planning Agent
**Type:** Documentation Infrastructure

---

## 1. Executive Summary

Foreman is actively migrating away from the **beads-first** architecture (beads_rust `br` as the sole task store, with `seeds` `sd` as a historical predecessor) toward **native task management** (SQLite-backed tasks in `foreman.db`, multi-project support). During this transition, a growing body of documentation describes the old architecture — creating a risk that operators confuse archived design documents with current operating procedures.

This PRD defines a **Historical Context Banner System** that injects a standardized notice into archived documents so readers immediately understand when they are reading a description of an older system state rather than current behavior. The system must be precise (touch only archival docs), low-noise (readers are not overwhelmed), and useful (the banner adds meaningful context without clutter).

**Key deliverable:** A machine-readable manifest of archival documents and an optional pre-commit hook that injects or validates the banner in archived documents, leaving active operator docs untouched.

---

## 2. Problem Statement

### 2.1 The Problem

Foreman's `docs/` directory contains documents at three different stages of architectural maturity:

1. **Current active docs** — `workflow-yaml-reference.md`, VCS guides under `docs/guides/`, CLAUDE.md
2. **Recently written PRDs/TRDs** — PRD-2026-005 through 007, TRD-2026-004 through 007
3. **Legacy and comparison docs** — documents written when Foreman was beads-first, before the native task management migration

A reader landing on `docs/migration-seeds-to-br.md`, `docs/PRD.md`, `docs/Overstory_comparison.md`, or `docs/flywheel_comparison.md` has no immediate signal that these describe an **older system state**. This leads to:
- Confusion about current behavior vs. historical behavior
- Operators following archived instructions that no longer apply
- Difficulty onboarding contributors who don't know which docs are current

### 2.2 Why Now

TRD-2026-006 (multi-project native task management) is actively shipping (Sprints 1–5, with P0 priority across the board). As the native task store lands:
- `BeadsRustClient` will be deprecated
- `br` will no longer be the sole task backend
- Dual-backend coexistence logic (`FOREMAN_TASK_BACKEND`) will be removed
- The term "beads-first architecture" will become a meaningful historical marker

This creates a natural archival boundary. Documents that predate the native task management feature describe the beads-first era and should be marked accordingly.

### 2.3 What Is NOT the Problem

This is not a content audit. We are not rewriting or deleting archived docs. We are adding a **structural signal** (the banner) so readers can self-assess relevance without reading the full document.

---

## 3. Goals and Non-Goals

### 3.1 Goals

- **Clarity:** A reader encountering any archived doc immediately knows it describes the beads-first era (pre-native-task-management) or an alternative comparison context
- **Precision:** Zero false positives — no active operator docs are modified
- **Low-noise:** The banner is visually prominent but does not clutter the document; it says one clear thing
- **Maintainable:** Adding the banner to future archived docs is obvious and requires no special tooling knowledge
- **Verifiable:** A CI check can confirm that all documents in archival directories either have the banner or are explicitly excluded

### 3.2 Non-Goals

- Rewriting or deleting archived documentation
- Translating old instructions to current architecture
- Adding banners to **active** operator docs (workflow YAML reference, VCS guides, CLAUDE.md, per-phase prompts)
- Automatically updating banners when architecture changes — this is a one-time archival flag, not a living tag
- Modifying the banner format for stylistic preference

---

## 4. Archival Directory Definitions

The following directories contain documents that **may** require historical context banners. Final inclusion is determined by the **Archival Eligibility Check** (Section 6).

### 4.1 Primary Archival Directories

| Directory | Rationale |
|-----------|----------|
| `docs/` (root) | Contains legacy comparison docs, migration guides, and draft PRDs written during the beads-first era |
| `docs/PRD/completed/` | Historical PRD artifacts from completed initiatives — these are by definition post-hoc records, not operating procedures |
| `docs/PRD/` (non-completed) | Draft PRDs that describe the old beads-first architecture before native task management. PRD-2026-005, -006, -007 are borderline (newer, may be partially current); PRD-2026-008+ would fall outside archival scope |

### 4.2 Secondary Archival Directories

| Directory | Rationale |
|-----------|----------|
| `docs/TRD/` | TRDs written before TRD-2026-006 (native task management). TRDs describing current pipeline phases (TRD-2026-007 epic execution) are not archival |
| `docs/guides/` | **NOT archival** — all guides in `docs/guides/` describe current operating procedures. Excluded from the banner system entirely |
| `docs/standards/` | Active standards documents — not archived |
| `src/defaults/` | Bundled workflow YAMLs, per-phase prompts — these are active runtime configs, not documentation |

### 4.3 Explicit Exclusions (Active Operator Docs)

The following are **never** candidates for banners, even if they sit inside an archival directory:

- `docs/guides/` — all files (`vcs-backend-interface.md`, `vcs-configuration.md`, `jujutsu-considerations.md`)
- `docs/workflow-yaml-reference.md` — current operating procedure
- `docs/troubleshooting.md` — current operational guidance
- `docs/windows-install.md`, `docs/homebrew-tap-setup.md` — platform setup guides
- `docs/cli-reference.md` — current CLI reference
- `docs/TEST-PLAN.md` — current testing strategy
- `docs/PRD/PRD-2026-007-epic-execution-mode.md` — describes current epic execution architecture
- `docs/TRD/TRD-2026-007-epic-execution-mode.md` — current TRD

---

## 5. Banner Text and Formatting

### 5.1 Banner Text (Single Standard Form)

```
> ⚠️ Historical Context
> This document describes Foreman's beads-first architecture, which has been
> superseded by native task management (TRD-2026-006). Some instructions,
> configurations, or comparisons in this document may no longer reflect
> current behavior.
```

### 5.2 Banner Variants

| Variant | Trigger condition | Text |
|---------|-------------------|------|
| **Standard** | Default archival banner | See 5.1 |
| **Comparison** | Document compares Foreman to an external tool (Overstory, Flywheel) | See 5.1, plus one line: `> Comparisons to external tools (e.g. Overstory, Flywheel) reflect Foreman at a specific historical point and may be outdated.` |
| **Migration** | Document is a migration guide | See 5.1, plus one line: `> This migration guide is preserved for historical reference. See TRD-2026-006 for current task management architecture.` |
| **Beads-Rust-Only** | Document describes the deprecated `BeadsRustClient` era (before coexistence fallback) | See 5.1, plus one line: `> The BeadsRustClient is deprecated. See TRD-2026-019 for deprecation schedule.` |

### 5.3 Placement

- The banner is placed **immediately after the first Markdown heading** (usually the H1 title) in the document
- If the document has a frontmatter block (YAML frontmatter `---`), the banner goes **after the closing `---`**
- If the document opens with a code block or table before any headings, the banner goes **before the first such block**, as close to the top as possible
- The banner is a Markdown blockquote (`>`) so it renders correctly in all Markdown viewers without special CSS

### 5.4 Visual Example

```markdown
# Overstory vs Foreman — Feature Comparison

> ⚠️ Historical Context
> This document describes Foreman's beads-first architecture, which has been
> superseded by native task management (TRD-2026-006). Some instructions,
> configurations, or comparisons in this document may no longer reflect
> current behavior.
> Comparisons to external tools (e.g. Overstory, Flywheel) reflect Foreman at
> a specific historical point and may be outdated.

## Overview
...
```

### 5.5 Banner Must Not Appear In

- `docs/guides/` (any file)
- `docs/workflow-yaml-reference.md`
- `docs/troubleshooting.md`
- `docs/PRD/PRD-2026-007-epic-execution-mode.md`
- `docs/TRD/TRD-2026-007-epic-execution-mode.md`
- Any file in `src/`

---

## 6. Archival Eligibility Check

A document is eligible for a banner if it meets **all three conditions**:

1. **Location:** The file lives in a Primary Archival Directory (Section 4.1) or Secondary Archival Directory (Section 4.2), and is not in the Explicit Exclusions list (Section 4.3)
2. **Content fingerprint:** The document contains at least one of the following historical reference patterns:
   - References `beads-first` or `beads_rust` as the current/proposed system
   - References `seeds` (`sd`) as an active task backend option
   - References `BeadsRustClient` without also referencing coexistence fallback (`hasNativeTasks()`, `FOREMAN_TASK_BACKEND`)
   - References a PRD or TRD that pre-dates TRD-2026-006's implementation start date (2026-03-30)
   - Contains feature comparisons with Overstory or Flywheel that assume beads-first as the default Foreman backend
3. **Temporal marker:** The document does not contain any of the following current-era markers:
   - References to `NativeTaskStore` as the primary task client
   - References to multi-project (`--project`) flag on foreman commands
   - References to TRD-2026-006 or PRD-2026-006 as already implemented

### 6.1 Canonical Archival Document List

Based on the current `docs/` tree, the following documents **are** archival and require banners:

| File | Banner Variant | Rationale |
|------|---------------|------------|
| `docs/migration-seeds-to-br.md` | Migration | Migration guide; describes `sd` → `br` transition; pre-native-task |
| `docs/Overstory_comparison.md` | Comparison | Feature comparison; assumes beads-first as default backend |
| `docs/flywheel_comparison.md` | Comparison | Feature comparison; assumes `sd` task backend and beads-first pipeline |
| `docs/mail-transport-plan.md` | Standard | Draft plan from 2026-03-21; references `seeds` CLI; no native task store mentions |
| `docs/PRD.md` | Standard | Draft PRD from 2026-03-10; assumes beads-first, Beads for task tracking |
| `docs/PRD/PRD-2026-005-mid-pipeline-rebase-and-shared-worktree.md` | Standard | Draft; references current pipeline but does not yet reflect native task management |
| `docs/PRD/PRD-2026-006-multi-project-native-task-management.md` | Standard (borderline) | Draft; describes native task management but may be superseded by implementation; flag for review |
| `docs/TRD/TRD-2026-004-vcs-backend-abstraction.md` | Standard | Draft from 2026-03-27; pre-native-task; may describe beads-first assumptions |
| `docs/TRD/TRD-2026-005-mid-pipeline-rebase.md` | Standard | Draft from 2026-03-29; same as PRD-005 |
| `docs/TRD/TRD-2026-006-multi-project-native-task-management.md` | **No banner** | TRD for the very feature this PRD is about; it IS current by definition |

The following documents **do not** require banners:

| File | Rationale |
|------|----------|
| `docs/workflow-yaml-reference.md` | Active operator doc |
| `docs/troubleshooting.md` | Active operator doc |
| `docs/guides/vcs-backend-interface.md` | Active operator doc |
| `docs/guides/vcs-configuration.md` | Active operator doc |
| `docs/guides/jujutsu-considerations.md` | Active operator doc |
| `docs/PRD/PRD-2026-007-epic-execution-mode.md` | Active epic execution TRD |
| `docs/TRD/TRD-2026-007-epic-execution-mode.md` | Current TRD |
| `docs/TRD/seeds-to-br-bv-migration.md` | Note: this file also exists at `docs/guides/seeds-to-br-bv-migration.md`; needs exclusion clarification — see Section 6.2 |

### 6.2 Ambiguity Notes

**`docs/TRD/seeds-to-br-bv-migration.md`** — This file is a TRD, but it is also a migration guide. Its location in `docs/TRD/` suggests archival, but its content (seeds → br → bv migration) is the direct precursor to the native task management work. It should be reviewed to determine if it describes beads-first as the "after" state (archival) or the baseline for native task management (current reference).

**`docs/TRD/TRD-2026-006-multi-project-native-task-management.md`** — As the TRD for the native task management feature, this document cannot receive a historical banner about pre-native-task architecture. However, once the feature ships, its own status should change from "Draft" to "Implemented" — a separate concern from the banner system.

---

## 7. Implementation Approach

### 7.1 Option A: Manual Banner Injection with Pre-commit Hook Validation (Recommended)

**Approach:** Authors manually add banners using a standard Markdown snippet. A pre-commit hook validates that all files in archival directories either (a) have a banner or (b) are on an exclusion list.

**Pros:**
- Simple to implement; no new build tooling
- Human-authors make contextual decisions about banner variant
- Pre-commit hook is auditable and runs in CI
- Works with any Markdown viewer

**Cons:**
- Relies on human discipline; easy to forget for new docs
- Pre-commit hook must be maintained as archival directory list changes

**Implementation:**
1. Create `docs/.historical-banners/manifest.json` — machine-readable list of archival documents with their banner variants (JSON Schema: see Section 7.3)
2. Create `docs/.historical-banners/banner-variants.json` — reusable banner text snippets
3. Create `scripts/validate-historical-banners.ts` — Node script that:
   - Reads the manifest
   - For each document in the manifest, checks whether the banner is present (exact string match)
   - Reports missing banners
   - Reports unexpected banners (in non-archival files)
4. Add a Husky pre-commit hook (`commit-msg` or `pre-commit`) that runs the validation script
5. Document the process in `CONTRIBUTING.md` or a `docs/README.md`

### 7.2 Option B: Automated Banner Injection via Build Script

**Approach:** A build-time script scans archival directories and injects banners into documents that lack them, using the manifest for variant selection.

**Pros:**
- No manual discipline required; banners are always present
- Consistent format

**Cons:**
- Modifies source files at build time — risky for git blame and merge conflicts
- Requires CI/CD pipeline changes
- Harder to audit which banners are "original" vs "injected"
- Overkill for a small document corpus (~10 files)

**Decision:** Rejected. Option A is sufficient for the scale of this problem.

### 7.3 Manifest JSON Schema

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["version", "generated", "documents"],
  "properties": {
    "version": {
      "type": "string",
      "description": "Schema version for forward compatibility"
    },
    "generated": {
      "type": "string",
      "format": "date-time",
      "description": "ISO 8601 timestamp when manifest was last generated"
    },
    "documents": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["path", "variant", "rationale"],
        "properties": {
          "path": {
            "type": "string",
            "description": "Relative path from docs/ directory, e.g. 'migration-seeds-to-br.md'"
          },
          "variant": {
            "type": "string",
            "enum": ["standard", "comparison", "migration", "beads-rust-only"],
            "description": "Which banner variant to use"
          },
          "rationale": {
            "type": "string",
            "description": "Why this document is archival — used for audit trail"
          },
          "lastReviewed": {
            "type": "string",
            "format": "date",
            "description": "ISO 8601 date this document was last reviewed for archival status"
          },
          "status": {
            "type": "string",
            "enum": ["archived", "review", "active"],
            "default": "archived",
            "description": "Whether the document is definitively archived or needs review"
          }
        }
      }
    },
    "exclusions": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["path", "reason"],
        "properties": {
          "path": { "type": "string" },
          "reason": {
            "type": "string",
            "enum": ["active-operator-doc", "active-trd", "generated", "not-applicable"]
          }
        }
      }
    }
  }
}
```

---

## 8. Edge Cases

### 8.1 New PRD/TRD Created in Archival Directory

If a contributor creates a new PRD or TRD in `docs/PRD/` or `docs/TRD/`, the pre-commit hook should warn but not block the commit. The banner requirement applies only to documents that are **confirmed archival**. A new draft PRD is not automatically archival.

**Resolution:** The validation script emits a warning for unlisted files in archival directories, suggesting review. A new file must be explicitly added to the manifest (as `status: archived`) or exclusions (as `status: active`) before the warning clears.

### 8.2 Document Promoted from Archival to Active

If a document previously flagged as archival is updated to describe current behavior (e.g., PRD-2026-006 implementation is completed and the TRD is updated), the banner must be removed and the document moved to the exclusions list.

**Resolution:** The manifest supports `status: review` for borderline documents. When a document is promoted, remove it from the manifest and add it to exclusions with reason `active-trd`.

### 8.3 Document That Already Has a Banner

Some documents may already have informal banners (e.g., `> Status: Draft` in `mail-transport-plan.md`). The validation script should check for the **canonical banner** (exact string match from `banner-variants.json`), not just any blockquote.

**Resolution:** The manifest doubles as an approval list — only documents in the manifest with `status: archived` need the canonical banner. Documents with informal banners but not in the manifest are not validated (and may be flagged for a separate review).

### 8.4 Git Conflict on Banner

If two agents editing archived docs in parallel both add banners to the same document (unlikely but possible), a git conflict on the banner block is straightforward to resolve — keep exactly one canonical banner.

**Resolution:** No special tooling needed; standard git conflict resolution.

### 8.5 Documents in `docs/TRD/completed/` vs `docs/PRD/completed/`

The `completed/` subdirectories contain post-hoc records of completed initiatives. These are prime candidates for archival banners because they describe what was done, not what is being done. However, the current tree shows only `.gitkeep` in those directories.

**Resolution:** If files are added to `completed/` in the future, the pre-commit hook should treat them as archival by default (any file in a `completed/` directory gets the standard banner).

---

## 9. Acceptance Criteria

### 9.1 Functional Acceptance Criteria

| ID | Criterion | Verification method |
|----|-----------|---------------------|
| AC-1 | Canonical archival document list exists in `docs/.historical-banners/manifest.json` with all ~10 documents listed, each with variant, rationale, and status | Read manifest; count entries |
| AC-2 | Each of the ~10 canonical archival documents has the correct banner variant injected at the top | Manual inspection of each file |
| AC-3 | All 7 explicitly excluded active operator docs have zero banners | Manual inspection of each excluded file |
| AC-4 | `docs/guides/` — all files — have zero banners | `grep -r "Historical Context" docs/guides/` returns empty |
| AC-5 | Banner is placed after H1 title or after YAML frontmatter in all injected documents | Visual review of each file |
| AC-6 | Banner uses the canonical blockquote format (`> ⚠️ Historical Context`) in all documents | `grep -r "⚠️ Historical Context" docs/` on archival docs only, count = archive count |
| AC-7 | `scripts/validate-historical-banners.ts` exits 0 when all archival docs have banners | Run script with all banners in place; expect exit code 0 |
| AC-8 | `scripts/validate-historical-banners.ts` exits non-zero when a banner is missing from any archival doc | Remove one banner; run script; expect non-zero exit |
| AC-9 | Pre-commit hook runs `validate-historical-banners.ts` and blocks commits with missing banners | Test with a temp file added to an archival dir without a banner |
| AC-10 | Pre-commit hook does NOT block commits for unlisted files in archival directories (warning only) | Create a temp file in `docs/PRD/` without adding to manifest; verify warning, not block |

### 9.2 Non-Functional Acceptance Criteria

| ID | Criterion |
|----|-----------|
| NF-1 | The banner text fits on 2–4 lines of 80-char display width — not overwhelming |
| NF-2 | The banner does not break rendering in GitHub, GitLab, Neovim (Markdown), or any common Markdown viewer |
| NF-3 | Adding a banner to a new archived doc requires only: (a) adding the file to manifest, (b) adding the banner to the file — no code changes |
| NF-4 | The system does not require any runtime dependencies; validation script uses only Node.js stdlib |
| NF-5 | The manifest is human-editable JSON — no binary or custom format |

### 9.3 Usefulness Criteria

| ID | Criterion |
|----|-----------|
| UC-1 | A new contributor reading `docs/migration-seeds-to-br.md` for the first time immediately understands it describes a past migration, not current behavior |
| UC-2 | A reader of `docs/Overstory_comparison.md` sees the Comparison banner and understands the comparison reflects a specific historical point |
| UC-3 | An operator who lands on an archived PRD/TRD via a search engine immediately sees the banner without reading the full document |
| UC-4 | The banners are low-noise enough that experienced operators are not annoyed by them; they appear only on older documents |

---

## 10. Open Questions

| ID | Question | Disposition |
|----|----------|-------------|
| OQ-1 | Should the manifest be auto-generated by scanning docs directories and applying the fingerprint rules (Section 6), or maintained manually? | **Manual** — auto-detection is unreliable (too many false positives/negatives); human review per document is the correct approach |
| OQ-2 | Should PRD-2026-006's own doc (`docs/PRD/PRD-2026-006-multi-project-native-task-management.md`) receive a banner? | **No** — as the PRD for the feature this banner system is about, it must describe the target state. Its `status` should be `review` in the manifest; once shipped, move to exclusions |
| OQ-3 | Does `docs/TRD/seeds-to-br-bv-migration.md` get a banner, and if so, which variant? | **Review needed** — this depends on whether it describes beads-first as the end state or the baseline for native task management. Recommend: Comparison variant, with status `review` until resolved |
| OQ-4 | Should the banner be added to documents in `docs/PRD/completed/` when they are moved there? | **Yes** — completed PRDs are by definition historical records; banner should be added at time of completion |
| OQ-5 | Does the pre-commit hook block the commit or just warn? | **Warn-only** — blocking commits for documentation issues is disruptive; the hook should fail CI on the validation step (which runs in CI), not locally |

---

## 11. Milestones

| Milestone | Deliverable | Owner |
|-----------|-------------|-------|
| M1 | Manifest created (`docs/.historical-banners/manifest.json`) with all ~10 archival docs listed | Planning / AI |
| M2 | Banners injected into all ~10 archival documents | AI |
| M3 | Validation script (`scripts/validate-historical-banners.ts`) implemented and tested | AI |
| M4 | Pre-commit hook wired up; CI validation step added | AI |
| M5 | Exclusion list verified (zero banners in active operator docs) | AI |
| M6 | OQ-3 resolved: `docs/TRD/seeds-to-br-bv-migration.md` status decided | Human |
| M7 | `mulch` records created; session log written | AI |

---

## Appendix A: Banner Text (Canonical Snippets)

These are the exact strings to inject. Do not modify spacing or emoji.

**Standard:**
```markdown
> ⚠️ Historical Context
> This document describes Foreman's beads-first architecture, which has been
> superseded by native task management (TRD-2026-006). Some instructions,
> configurations, or comparisons in this document may no longer reflect
> current behavior.
```

**Comparison:**
```markdown
> ⚠️ Historical Context
> This document describes Foreman's beads-first architecture, which has been
> superseded by native task management (TRD-2026-006). Some instructions,
> configurations, or comparisons in this document may no longer reflect
> current behavior.
> Comparisons to external tools (e.g. Overstory, Flywheel) reflect Foreman at
> a specific historical point and may be outdated.
```

**Migration:**
```markdown
> ⚠️ Historical Context
> This document describes Foreman's beads-first architecture, which has been
> superseded by native task management (TRD-2026-006). Some instructions,
> configurations, or comparisons in this document may no longer reflect
> current behavior.
> This migration guide is preserved for historical reference. See TRD-2026-006
> for current task management architecture.
```

**Beads-Rust-Only:**
```markdown
> ⚠️ Historical Context
> This document describes Foreman's beads-first architecture, which has been
> superseded by native task management (TRD-2026-006). Some instructions,
> configurations, or comparisons in this document may no longer reflect
> current behavior.
> The BeadsRustClient is deprecated. See TRD-2026-019 for deprecation schedule.
```

---

*End of PRD*
