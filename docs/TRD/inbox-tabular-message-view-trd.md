# TRD: Inbox Tabular Message View

**Author:** Leo D'Angelo / Foreman TRD Agent
**Created:** 2026-04-30
**Status:** Draft
**Parent PRD:** `docs/PRD.md` — "Improve inbox output with tabular message view"
**Model:** minimax/MiniMax-M2.7
**Worktree:** `foreman-c3845`

---

## 1. Problem Statement

The `foreman inbox` command currently renders messages as free-form text blocks:

```
[2024-01-01 12:00:00] explorer → developer  |  work started [read]
  phase=explorer, status=in_progress, seedId=foreman-x7k2m, runId=run-abc123
```

This format makes it difficult to:
- Scan many messages quickly
- Compare fields across rows
- Sort by date or ticket ID

Users need a **tabular layout** that displays structured message data in aligned columns with proper truncation.

---

## 2. Goals & Non-Goals

### Goals
1. Default inbox output renders as a table with aligned columns
2. Date/time in compact sortable format (`YYYY-MM-DD HH:MM:SS`)
3. Ticket ID (run ID) visible per row for context
4. Structured payload fields (`kind`, `tool`, `args`) extracted and displayed in dedicated columns
5. Long `args` values truncated safely (with `…` indicator) to fit column width
6. `--full` flag preserved for detailed payload inspection (no change)

### Non-Goals
- Do NOT change the underlying data model or SQLite schema
- Do NOT add new filtering capabilities
- Do NOT change `--watch` mode behavior (live output stays as-is)
- Do NOT modify the dashboard inbox panel

---

## 3. System Architecture

### 3.1 Component Design

```
src/cli/commands/inbox.ts
├── formatMessage()         → REMOVE (replaced by table formatter)
├── TableFormatter class    → NEW: builds aligned table rows
│   ├── formatRow(msg)      → formats single message as table row
│   ├── formatHeader()      → column headers
│   ├── calcWidths(msgs)    → auto-size columns to content
│   └── truncate(str, n)    → safe truncation with ellipsis
├── formatMessageRaw()      → KEEP: --full mode (existing function)
└── formatRunStatus()       → KEEP: unchanged
```

### 3.2 Table Column Specification

| Column | Source Field | Min | Max | Default | Truncation |
|---|---|---|---|---|---|
| DATETIME | `created_at` (ISO) | 19 | 19 | 19 | — (fixed) |
| TICKET | `run_id` | 8 | 20 | 12 | Middle-cut if >20 |
| SENDER | `sender_agent_type` | 8 | 15 | 10 | Right-pad |
| RECEIVER | `recipient_agent_type` | 8 | 15 | 10 | Right-pad |
| KIND | `body.kind` (JSON) | 0 | 10 | 8 | — |
| TOOL | `body.tool` (JSON) | 0 | 12 | 8 | — |
| ARGS | `body.argsPreview \|\| body.message \|\| body` | 0 | 40 | 30 | Right-truncate + `…` |

**Fallback behavior**: When `kind`, `tool`, or `args` fields are absent from JSON body, column shows `—`.

### 3.3 Width Calculation Algorithm

1. Collect all messages for the current view
2. For each column, compute max content width across all rows
3. Clamp each column to its min/max constraints
4. Respect overall terminal width (cap total at `getTerminalWidth()`)
5. Distribute extra space to ARGS column (most flexible)

### 3.4 Data Flow

```
store.getAllMessagesGlobal(limit)
  → messages: Message[]
  → TableFormatter.formatTable(messages, options)
  → string output (ANSI-escaped)
```

---

## 4. Task Breakdown

- [ ] TASK-001: Add `TableFormatter` class in `src/cli/commands/inbox.ts`
- [ ] TASK-002: Implement `formatHeader()` returning column headers string
- [ ] TASK-003: Implement `formatRow(msg)` extracting all 7 columns with JSON parsing
- [ ] TASK-004: Implement `calcWidths(messages)` auto-sizing logic
- [ ] TASK-005: Implement `truncate(str, max)` safe truncation helper
- [ ] TASK-006: Replace `formatMessage()` default invocation with `TableFormatter.formatTable()`
- [ ] TASK-007: Keep `formatMessage()` as `--full` fallback (existing behavior unchanged)
- [ ] TASK-008: Add unit tests for `TableFormatter` methods
- [ ] TASK-009: Add integration tests verifying table layout for mixed-payload messages
- [ ] TASK-010: Verify `--full` mode still works (existing tests + manual check)

---

## 5. Detailed Column Extraction Logic

### JSON Payload Parsing

```typescript
function extractBodyFields(body: string): { kind: string | null; tool: string | null; args: string | null } {
  try {
    const parsed = JSON.parse(body) as Record<string, unknown>;
    return {
      kind: typeof parsed["kind"] === "string" ? parsed["kind"] : null,
      tool: typeof parsed["tool"] === "string" ? parsed["tool"] : null,
      args: parsed["argsPreview"] as string | null
         ?? (parsed["message"] as string | null)
         ?? (typeof parsed["args"] === "string" ? parsed["args"] : null),
    };
  } catch {
    return { kind: null, tool: null, args: null };
  }
}
```

### Truncation Rules

- **ARGS column**: If `args.length > maxWidth`, truncate to `maxWidth - 1` + `…`
- **TICKET column**: If `run_id.length > 20`, show middle-cut: `run_i…d` (7+1+rest)
- **Never break mid-word** for args — stop at last space before max

### Graceful Degradation

If JSON body is absent or malformed, all three payload columns show `—`.

---

## 6. Sprint Planning

### Sprint 1: Core Implementation (TASK-001 through TASK-007)

| Task | ID | Estimate | Dependencies |
|---|---|---|---|
| TableFormatter class skeleton | TASK-001 | 1h | — |
| formatHeader() | TASK-002 | 0.5h | TASK-001 |
| formatRow() with JSON extraction | TASK-003 | 1.5h | TASK-001 |
| calcWidths() auto-sizing | TASK-004 | 1h | TASK-003 |
| truncate() helper | TASK-005 | 0.5h | — |
| Replace default formatMessage() call | TASK-006 | 0.5h | TASK-002, TASK-004 |
| Keep formatMessage() for --full | TASK-007 | 0.5h | TASK-006 |

**Total:** ~5.5h

### Sprint 2: Testing & Validation (TASK-008 through TASK-010)

| Task | ID | Estimate | Dependencies |
|---|---|---|---|
| Unit tests for TableFormatter | TASK-008 | 1.5h | TASK-005 |
| Integration tests for table layout | TASK-009 | 1h | TASK-008 |
| Verify --full mode regression | TASK-010 | 0.5h | TASK-008 |

**Total:** ~3h

---

## 7. Testing Strategy

### Unit Tests (TASK-008)

- `formatHeader()` returns correct column headers
- `formatRow()` extracts `kind`, `tool`, `args` from JSON body
- `formatRow()` returns `—` for missing JSON fields
- `calcWidths()` returns correct min/max per column
- `truncate()` respects max length and adds `…`
- `truncate()` stops at word boundary when possible
- `truncate()` handles empty string
- Long `run_id` gets middle-cut treatment

### Integration Tests (TASK-009)

- Table output contains all 7 column headers
- Message rows align under correct headers
- Mixed payloads (some with JSON, some without) render correctly
- ARGS column truncation shows `…` for long values
- Empty table renders header with no data rows

### Regression Tests (TASK-010)

- `formatMessage(msg, true)` still shows full JSON payload
- Existing `inbox.test.ts` tests still pass (formatMessage is kept as-is for `--full` mode)

---

## 8. Output Format

### Default Table Output (new)

```
DATETIME            TICKET       SENDER     RECEIVER   KIND       TOOL       ARGS
-------------------- ------------ ---------- ---------- ---------- ---------- ------------------------------
2026-04-30 10:23:45 run-abc123    explorer   developer  —          —          work started
2026-04-30 10:24:12 run-abc123    developer  qa         update     bash       cd /tmp && grep -n "foo" x
2026-04-30 10:25:01 run-abc123    qa         reviewer   —          —          Tests passed
2026-04-30 10:25:30 run-def456    reviewer   foreman    verdict    —          PASS
```

### `--full` Mode Output (unchanged)

```
[2026-04-30 10:23:45] explorer → developer  |  work started
  {
    "phase": "explorer",
    "status": "in_progress",
    "seedId": "foreman-x7k2m",
    "runId": "run-abc123"
  }
```

---

## 9. Acceptance Criteria

- [ ] AC-1: Running `foreman inbox` without flags displays a table with 7 columns (DATETIME, TICKET, SENDER, RECEIVER, KIND, TOOL, ARGS)
- [ ] AC-2: DATETIME column shows `YYYY-MM-DD HH:MM:SS` format
- [ ] AC-3: TICKET column shows `run_id` and truncates with `…` if longer than 20 chars
- [ ] AC-4: KIND, TOOL columns extract from JSON `body.kind` and `body.tool`; show `—` if absent
- [ ] AC-5: ARGS column shows `body.argsPreview`, `body.message`, or raw body (in that priority); truncates at column boundary with `…`
- [ ] AC-6: `foreman inbox --full` shows existing free-form JSON payload format (no changes)
- [ ] AC-7: `foreman inbox --watch` keeps existing live-update behavior (unchanged)
- [ ] AC-8: All existing `inbox.test.ts` tests pass
- [ ] AC-9: New `TableFormatter` unit tests pass (>80% coverage on new class)

---

## 10. File Changes

| File | Change |
|---|---|
| `src/cli/commands/inbox.ts` | Add `TableFormatter` class; replace `formatMessage()` default with table output |
| `src/cli/__tests__/inbox.test.ts` | Add `TableFormatter` unit tests |

No other files modified.

---

## 11. Risks & Mitigations

| Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|
| Terminal width detection fails in CI | Output wraps incorrectly | Low | `getTerminalWidth()` already has 80-col fallback |
| JSON payload fields non-standard | Columns show `—` when data exists | Medium | Extract from `argsPreview`, `message`, `body` in order; test with real payloads |
| Column alignment breaks on Unicode | SENDER/RECEIVER misaligned | Low | Use `String.prototype.padEnd()` which handles Unicode correctly |

---

*Cross-reference: PRD.md §4 (Architecture) — existing `formatMessage()` function to be replaced*