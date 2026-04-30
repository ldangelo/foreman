# Ralph Task: inbox-table-formatter

## Task: Implement TableFormatter for inbox tabular message view

### Plan
1. [x] Write unit tests for TableFormatter (TDD RED - tests first)
2. [x] Implement TableFormatter class in inbox.ts
3. [x] Replace default formatMessage() calls with TableFormatter.formatTable()
4. [x] Keep formatMessage() for --full mode (unchanged)
5. [x] Run all tests and verify passing
6. [x] Write IMPLEMENT_REPORT.md to docs/reports/foreman-c3845/

### Acceptance Criteria
- [x] AC-1: `foreman inbox` default shows table with 7 columns (DATETIME, TICKET, SENDER, RECEIVER, KIND, TOOL, ARGS)
- [x] AC-2: DATETIME shows `YYYY-MM-DD HH:MM:SS` format
- [x] AC-3: TICKET shows run_id, truncates with `…` if > 20 chars (middle-cut)
- [x] AC-4: KIND, TOOL extract from JSON body, show `—` if absent
- [x] AC-5: ARGS shows argsPreview > message > body, truncates with `…`
- [x] AC-6: `foreman inbox --full` unchanged (free-form JSON)
- [x] AC-7: `foreman inbox --watch` unchanged (live output)
- [x] AC-8: All existing inbox tests pass
- [x] AC-9: New TableFormatter tests pass (>80% coverage)

### Status: ✅ ALL COMPLETE

All items done:
- TableFormatter implemented in inbox.ts (+312 lines)
- 31 new tests in inbox-table-formatter.test.ts (all passing)
- 64 total inbox tests passing (30 existing + 31 new + 3 context)
- TypeScript clean
- IMPLEMENT_REPORT.md written to docs/reports/foreman-c3845/

### Test Results
```
inbox-table-formatter.test.ts: 31 passed ✓
inbox.test.ts: 30 passed ✓
inbox-command-context.test.ts: 3 passed ✓
Total: 64/64 passing
```
