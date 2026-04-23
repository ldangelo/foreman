# TRD: Historical Context Banner System — Task Breakdown

**Document ID:** TRD-2026-010
**Version:** 1.0
**Status:** Draft
**Date:** 2026-04-15
**Author:** Planning Agent
**PRD:** PRD-2026-008

---

## Executive Summary

Decompose PRD-2026-008 into actionable tasks for implementing the Historical Context Banner System. Most implementation is complete; this TRD focuses on remaining CI validation and pre-commit hook work.

---

## Task Inventory

### Completed Tasks (from PRD-rerun artifacts)

| Task ID | Description | Status | Notes |
|---------|-------------|--------|-------|
| T1 | Create manifest.json with archival document list | ✅ Done | 9 documents, exclusions defined |
| T2 | Define banner-variants.json with canonical banner text | ✅ Done | 4 variants: standard, comparison, migration, beads-rust-only |
| T3 | Create manifest.schema.json for validation | ✅ Done | Full schema with enum constraints |
| T4 | Implement validate-historical-banners.ts | ✅ Done | Validates banners, --fix mode for injection |
| T5 | Inject banners into all 9 archived documents | ✅ Done | All banners present per validation |
| T6 | Validate no banners in excluded active docs | ✅ Done | guides/, current TRDs/PRD excluded |

### Pending Tasks

| Task ID | Priority | Description | Dependencies |
|---------|----------|-------------|--------------|
| T7 | P1 | Add CI validation step to existing CI workflow | T4 |
| T8 | P2 | Implement pre-commit hook (warning mode) | T7 |
| T9 | P3 | Add directory exclusion validation to script | T4 |
| T10 | P2 | Document CI integration in CLAUDE.md or docs | T7 |

---

## Task Details

### T7: Add CI Validation Step

**Priority:** P1
**Type:** task
**Status:** pending

**Description:**
Add a CI step that runs `validate-historical-banners.ts` to prevent regressions. The validation should:
- Run on every PR that modifies files in `docs/`
- Fail CI if any archival document is missing a banner
- Fail CI if any excluded active doc has a banner
- Use exit code semantics: 0=pass, 1=fail, 2=config error

**Implementation Notes:**
1. **CI system:** GitHub Actions (`.github/workflows/ci.yml`)
2. **Trigger:** Run on `pull_request` events when `docs/` files change
3. **Add a job** that:
   - Checks out code
   - Sets up Node.js
   - Runs `npx tsx docs/experiments/historical-context-prd-rerun/validate-historical-banners.ts`
   - Uses exit code for pass/fail

**Option A: Add to existing ci.yml**
```yaml
jobs:
  historical-context:
    name: Historical Context Banners
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: "20"
      - run: npx tsx docs/experiments/historical-context-prd-rerun/validate-historical-banners.ts
```

**Option B: Conditional step in test job**
Add as a step in the existing `test` job, only when docs/ files change.

**Acceptance Criteria:**
- [ ] CI step runs on docs/ changes
- [ ] CI fails when banner is missing from archived doc
- [ ] CI fails when banner exists in excluded doc
- [ ] CI passes when all validations pass

---

### T8: Implement Pre-commit Hook (Warning Mode)

**Priority:** P2
**Type:** task
**Status:** pending

**Description:**
Implement a pre-commit hook that warns (but does not block) when a commit would add a document that should have a banner. This enables gradual adoption without blocking contributors.

**Behavior:**
- **Warning only** (per PRD decision: warn locally, fail CI)
- Warns when committing new files in `docs/` that match archival criteria
- Does NOT block commits (no exit code != 0)
- Suggests running validation script with `--fix`

**Implementation Options:**
1. **Simple shell script** in `.git/hooks/pre-commit`
2. **Husky** integration if already in project
3. **detect-secrets style** custom hook

**Decision Needed:**
- Check if project uses Husky or similar
- Choose implementation based on existing tooling

**Acceptance Criteria:**
- [ ] Hook runs on `git commit` for docs/ changes
- [ ] Warns (does not block) when new archival doc missing banner
- [ ] Provides actionable message (what to run)
- [ ] Does not interfere with normal commits (no false positives)

---

### T9: Add Directory Exclusion Validation to Script

**Priority:** P3
**Type:** chore
**Status:** pending

**Description:**
The current validation script has placeholder logic for directory exclusions (`guides/`). Enhance to actually validate that no files in excluded directories have banners.

**Current Issue:**
```typescript
// Current placeholder in validate-historical-banners.ts:
if (exclusion.path.endsWith("/")) {
  const dirBannerCheck = allCanonicalBanners.some((banner) => {
    // This is a simplified check; full implementation would glob the directory
    return false; // Directory check handled separately
  });
  // ...
}
```

**Implementation:**
1. Use `glob` or `fs.readdirSync` to iterate files in directory
2. Check each file for banner content
3. Report any violations

**Acceptance Criteria:**
- [ ] `guides/` directory files are checked for banners
- [ ] Violations reported with file path
- [ ] Works recursively for nested directories

---

### T10: Document CI Integration

**Priority:** P2
**Type:** docs
**Status:** pending

**Description:**
Add documentation for how the CI validation step works and how to run validation locally.

**Location Options:**
- `docs/guides/` (active operator doc)
- `CLAUDE.md` (project context)
- `docs/troubleshooting.md` (if CI issues arise)

**Content:**
```markdown
## Historical Context Banners

Foreman uses automated validation to ensure archived documents have proper
historical context banners.

### Running Validation Locally

```bash
npx tsx docs/experiments/historical-context-prd-rerun/validate-historical-banners.ts
```

### Adding a Banner

```bash
npx tsx docs/experiments/historical-context-prd-rerun/validate-historical-banners.ts --fix
```

### Adding New Archived Documents

1. Add entry to `docs/experiments/historical-context-prd-rerun/manifest.json`
2. Run validation to inject banner
3. Commit changes
```

---

## Dependencies

```
T7 (CI step) ──────┬── T10 (docs)
                   │
T4 (validation) ───┤
                   │
T7 ────────────────┴── T8 (pre-commit hook)
```

**Dependency Graph:**
- T7 depends on T4 (validation script must exist)
- T8 depends on T7 (hook should mirror CI behavior)
- T10 depends on T7 (document the CI step)

---

## File Manifest

All files live in `/Users/ldangelo/Development/Fortium/foreman/docs/experiments/historical-context-trd-rerun/`:

| File | Purpose |
|------|---------|
| `TRD.md` | This document |
| `TASKS.md` | Detailed task specifications (future: generated from seeds) |

**Artifacts from PRD-rerun (reference only, do not modify):**
- `../historical-context-prd-rerun/manifest.json` — archival document list
- `../historical-context-prd-rerun/banner-variants.json` — banner text
- `../historical-context-prd-rerun/validate-historical-banners.ts` — validation script
- `../historical-context-prd-rerun/manifest.schema.json` — JSON schema

---

## Open Questions (Resolved)

| ID | Question | Disposition |
|----|----------|-------------|
| OQ-1 | Which CI system is used (GitHub Actions, CircleCI, other)? | **GitHub Actions** — `.github/workflows/ci.yml` exists |
| OQ-2 | Does project use Husky for pre-commit hooks? | **No** — no `.husky/` directory, no husky in package.json |
| OQ-3 | Should T9 be part of T4 or separate? | **Separate** — enhancement task for glob-based directory check |

---

## Milestones

| Milestone | Tasks | Target |
|-----------|-------|--------|
| M1: CI Integration | T7 | Required for ship |
| M2: Pre-commit Hook | T8 | Nice to have |
| M3: Documentation | T10 | After M1 |
| M4: Script Enhancement | T9 | Low priority |

---

*End of TRD*
