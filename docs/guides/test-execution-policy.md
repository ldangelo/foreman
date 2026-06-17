# Test Execution Policy

This document defines the test ownership and execution policy for Foreman workflows to prevent redundant test runs and ensure efficient validation.

## Test Ownership by Phase

Each pipeline phase has a defined role in the test execution lifecycle:

| Phase | Primary Responsibility | Full Suite Policy |
|-------|----------------------|-------------------|
| **Explorer** | Analyze scope, identify affected files | Never runs tests |
| **Developer/Fix** | Implement changes, run targeted verification | Never runs full suite |
| **QA** | Validate implementation, detect regressions | Full suite only with justification |
| **Finalize** | Verify target integration, run tests on drift only | Only if target drift exists |
| **PR Review** | Triage GitHub checks, read-only status review | Never runs local tests |
| **Troubleshooter** | Diagnose failures, run targeted tests | Runs as needed for diagnosis |

## Test Execution Hierarchy

```
1. Targeted Verification (fastest, most focused)
   └── Only tests related to changed files/behaviors
   └── Used by: Developer, Troubleshooter (initial diagnosis)

2. Expanded Targeted Validation (moderate scope)
   └── Tests for affected modules or feature areas
   └── Used by: QA (default for most tasks)

3. Full Test Suite (slowest, most expensive)
   └── Complete npm test run
   └── Used by: QA (only with explicit justification), Finalize (only on drift)
```

## Phase-Specific Rules

### Developer/Fix Phases

**Policy:** Run targeted verification only.

```
- Run targeted tests for changed files: npm test -- path/to/changed.test.ts
- Or targeted module tests: npm test -- --grep "feature name"
- NEVER run: npm test (full suite)
```

**Rationale:** QA phase is responsible for comprehensive validation. Developer should verify their specific changes work.

### QA Phase

**Policy:** Run the narrowest verification that proves correctness.

**Default:** Expanded targeted validation
- Run module-level or feature-level tests
- Use `--grep` to target relevant test files

**Full Suite (requires justification):**
Use `npm test -- --reporter=dot` only when:
1. Task scope is broad (epic, large feature)
2. Targeted verification reveals regression risk
3. Changes affect core/shared code
4. Task explicitly requests full validation

**Required in QA Report:**
```
## Test Scope Justification
- Scope: <targeted|expanded|full>
- Justification (if full): <why full suite was necessary>
```

### Finalize Phase

**Policy:** Run tests only if target branch drifted after QA. Prefer targeted-affected tests before full suite.

```
Condition: shouldRunFinalizeValidation === true
  └── Step 1: Read VALIDATION_LEDGER.md to see what QA already validated
  └── Step 2: Run targeted-affected tests first (npm test -- path/to/affected.test.ts)
  └── Step 3: Run full suite only if targeted reveals broader regression risk or core/shared code affected
  └── Run: npm test -- --reporter=dot 2>&1
Else:
  └── Skip tests entirely
```

**Rationale:** If the target branch hasn't moved since QA, no new test run is needed. When drift exists, targeted-affected tests catch most regressions faster than full suite.

### PR Review Phase

**Policy:** Read-only GitHub check triage. Never run local tests.

```
Allowed:
- gh pr view (read PR metadata)
- gh api (read check statuses, comments)
- Read CodeRabbit reports via gh or artifact files

Forbidden:
- npm test (local test execution)
- npm run build (local build)
```

**Rationale:** GitHub CI/CD is the source of truth for PR validation. PR review should not duplicate CI checks locally.

### Troubleshooter Phase

**Policy:** Run tests as needed for diagnosis.

- Run targeted tests to reproduce failures
- Run full suite only when diagnosing systemic issues
- Document test findings in TROUBLESHOOTER_REPORT.md

## Validation Ledger

The validation ledger prevents redundant test runs by tracking what has been validated. See [validation-ledger-template.md](../../src/defaults/prompts/default/validation-ledger-template.md) for the canonical format.

### Ledger Entry Format

Each phase writes a validation entry to `VALIDATION_LEDGER.md`:

```markdown
## Validation Ledger

| Phase | Timestamp | Scope | Files/Modules | Result | Notes |
|-------|-----------|-------|---------------|--------|-------|
| developer | 2024-01-01T10:00:00Z | targeted | src/cli.ts | PASS | |
| qa | 2024-01-01T10:15:00Z | expanded | src/cli.ts,src/lib/ | PASS | |
| finalize | 2024-01-01T10:30:00Z | skipped (no drift) | - | N/A | QA passed, target unchanged |
```

### Ledger Persistence

- Written to `{task.projectReportsDir}/VALIDATION_LEDGER.md`
- Consumed by downstream phases to avoid duplicate work
- Finalize uses ledger to determine if tests were run after target drift
- Template reference: [validation-ledger-template.md](../../src/defaults/prompts/default/validation-ledger-template.md)

## Guardrails Summary

| Phase | Guardrail |
|-------|-----------|
| Developer | "DO NOT run the full test suite — the QA agent handles that" |
| QA | Must justify full suite runs in report |
| Finalize | "Run tests only if the target branch changed after QA" |
| PR Review | "Do not fix files in this phase. Do not commit. Do not push." |
| Troubleshooter | No restriction (diagnostic phase) |

## Anti-Patterns to Avoid

1. **Running full suite in Developer phase** - QA will run it anyway
2. **Running full suite in PR Review** - GitHub CI is the source of truth
3. **Duplicate full suite runs** - Check validation ledger first
4. **Running tests without target drift** - Finalize should skip if no drift
5. **Running tests for verification beads** - No code changes expected

## Workflow-Specific Considerations

### Bug Workflow
- Developer runs targeted bug-path tests
- QA runs targeted tests for the fix
- Finalize skips tests if no target drift; runs targeted-affected tests first when drift exists
- Uses `finalize-bug.md` prompt (lighterweight than `finalize.md`)

### Epic Workflow
- QA may run full suite more frequently due to broad scope
- Justification required in QA report

### Smoke Workflow
- All phases are noop - tests are not expected
- Skip validation ledger entries

## References

- QA Prompt: `src/defaults/prompts/default/qa.md`
- Finalize Prompt: `src/defaults/prompts/default/finalize.md`
- Finalize-Bug Prompt: `src/defaults/prompts/default/finalize-bug.md`
- PR Review Prompt: `src/defaults/prompts/default/pr-review.md`
- Developer Prompt: `src/defaults/prompts/default/developer.md`
- Validation Ledger Template: `src/defaults/prompts/default/validation-ledger-template.md`
