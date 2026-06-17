# Validation Ledger

This ledger tracks test validation runs across pipeline phases to prevent redundant test execution.

**Policy:** Each phase should check this ledger before running tests. If the same scope was already validated by a prior phase, skip or limit re-validation.

## Ledger Entry Format

| Phase | Timestamp | Scope | Files/Modules | Result | Notes |
|-------|-----------|-------|---------------|--------|-------|
| developer | ISO | targeted | src/cli.ts | PASS | |
| qa | ISO | expanded | src/ | PASS | |
| finalize | ISO | skipped (no drift) | - | N/A | |

## Scope Definitions

| Scope | Description | Typical Use |
|-------|-------------|-------------|
| `targeted` | Single file or specific test | Developer verification |
| `expanded` | Module or feature area | QA default |
| `full` | Complete test suite | QA (with justification) or finalize (on drift) |
| `skipped` | No validation run | Finalize (no drift), verification beads |

## Phase-Specific Guidance

### Developer Phase
- Write entry after targeted verification
- Scope should be `targeted`
- Only tests related to changed files

### QA Phase
- Check ledger before running tests
- Expand scope only if needed
- Write entry after validation

### Finalize Phase
- Check ledger and `shouldRunFinalizeValidation`
- Skip if QA already passed and no drift
- Write entry with actual scope or "skipped"

## Example Ledger Entries

```markdown
| developer | 2024-01-01T10:00:00Z | targeted | src/cli.ts | PASS | |
| qa | 2024-01-01T10:15:00Z | expanded | src/cli.ts,src/lib/ | PASS | |
| finalize | 2024-01-01T10:30:00Z | skipped (no drift) | - | N/A | QA passed, target unchanged |
```

## Rules

1. **Check before running tests** — Read the ledger and skip redundant validation
2. **Document scope accurately** — Be specific about what was tested
3. **Justify full suite runs** — QA must explain why expanded wasn't sufficient
4. **Mark skipped appropriately** — Finalize should explain why tests were skipped
