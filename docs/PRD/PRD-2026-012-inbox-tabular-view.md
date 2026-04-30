# PRD: Inbox Command — Tabular Message View

**Author:** Lead Agent (PRD Phase)
**Created:** 2026-04-30
**Status:** Draft
**Priority:** Medium
**Project:** Foreman — Inbox UX Enhancement

---

## 1. Executive Summary

The `foreman inbox` command currently renders messages in a free-form text style that makes it difficult to quickly scan multiple messages. This PRD defines a tabular view as the default output format, with columns for date/time, ticket ID, sender, receiver, kind, tool, and args. The existing `--full` raw/payload mode remains available for detailed inspection.

**Goal:** Default `foreman inbox` output shows a readable table where agents can quickly assess message flow across runs.

---

## 2. Problem Statement

Current inbox output (screenshot style):

```
[2024-01-01 12:00:00] explorer → developer  |  phase=developer, status=running, seedId=abc123

[2024-01-01 12:00:05] developer → qa  |  verdict=PASS, message=All checks passed, currentPhase=qa
```

**Pain points:**
- Messages render vertically, taking many lines per message
- Hard to compare fields across messages (e.g., which agent sent what to whom)
- No column alignment — scanning requires reading each line start-to-end
- Ticket ID (seed/run context) is buried in parsed JSON body
- Long args overflow without truncation

**Target experience (tabular):**

```
DATE/TIME          TICKET       FROM      TO        KIND    TOOL     ARGS
────────────────── ──────────── ───────── ──────── ─────── ──────── ───────
2026-04-30 09:15   foreman-1a2b explorer  developer update  bash     cd <worktree>
2026-04-30 09:17   foreman-1a2b developer qa        result  -        Tests: 42
```

---

## 3. User Analysis

### Target Users
- **Lead agent** — Monitor pipeline progress, spot stuck agents
- **Developer agent** — Check incoming messages from lead/explorer
- **QA agent** — Review test results and verdicts from developer

### Pain Points per User
| User | Pain Point |
|------|------------|
| Lead | Hard to see which agents are active and what messages are pending |
| Lead | Must scroll through verbose multi-line message blocks |
| All | "What was that message about?" requires re-reading full format |
| All | No quick way to see message kind/tool without parsing JSON |

### Current Workflow
1. Run `foreman inbox` → see free-form text output
2. Parse each message visually to extract key fields
3. Use `--full` only when detailed inspection needed

### Desired Workflow
1. Run `foreman inbox` → see compact table
2. Scan columns for relevant values (kind, tool, sender)
3. Use `--full` or `--raw` for deep inspection

---

## 4. Goals & Non-Goals

### Goals
- Default inbox output uses a readable table layout for message rows
- date/time is shown in a compact sortable format (YYYY-MM-DD HH:MM)
- ticket ID/run context is visible per row (from `seedId` in body or run_id)
- kind, tool, and args are extracted from structured payloads when present
- Graceful degradation when payload lacks structured fields
- Long args are truncated safely for table display (max ~40 chars visible)
- Existing `--full` output mode remains available for detailed inspection

### Non-Goals
- Do NOT change message storage format (SQLite schema unchanged)
- Do NOT remove `--full` or existing flags
- Do NOT add new filtering flags (scope: output format only)
- Do NOT change `--watch` behavior (remains unchanged)

---

## 5. Functional Requirements

### 5.1 Tabular Output Format

**Columns (in order):**
| Column | Source | Width | Notes |
|--------|--------|-------|-------|
| DATE/TIME | `created_at` | 16 chars | Format: `YYYY-MM-DD HH:MM` (compact, sortable) |
| TICKET | `seedId` from body or `run_id` | 12 chars | Fallback to `run_id` prefix if no `seedId` |
| FROM | `sender_agent_type` | 10 chars | Truncate if longer |
| TO | `recipient_agent_type` | 10 chars | Truncate if longer |
| KIND | `kind` from body JSON | 8 chars | Fallback to `-` if absent |
| TOOL | `tool` from body JSON | 8 chars | Fallback to `-` if absent |
| ARGS | `argsPreview` or `args` from body JSON | 40 chars | Truncate with `…` if longer |

**Row separator:** ASCII line using `─` (standard box drawing)

**Header:** Printed once at top, same format as data rows but bold/underlined

**Example:**
```
DATE/TIME          TICKET       FROM      TO        KIND    TOOL     ARGS
────────────────── ──────────── ───────── ──────── ─────── ──────── ───────
2026-04-30 09:15   foreman-1a2b explorer  developer update  bash     cd <worktree> &&…
2026-04-30 09:17   foreman-1a2b developer qa        result  -        verdict=PASS
2026-04-30 09:20   foreman-1a2b qa       reviewer  update  -        verdict=PASS
```

### 5.2 Graceful Degradation

When a message body is not structured JSON or lacks the expected fields:

| Missing Field | Display Value |
|--------------|---------------|
| `seedId` in body | Use `run_id` first 8 chars + `…` |
| `kind` | `-` |
| `tool` | `-` |
| `argsPreview`/`args` | `-` |
| Body is not JSON | Truncate body to 40 chars as-is |

### 5.3 Truncation Rules

- Args column: max 40 visible characters, suffix `…` if truncated
- From/To columns: max 10 chars, suffix `…` if truncated
- Date/Time: fixed 16 chars, no truncation needed
- Ticket: max 12 chars, suffix `…` if truncated

### 5.4 Existing `--full` Mode (No Change)

When `--full` is passed, output reverts to the current free-form multi-line format:
```
[2026-04-30 09:15:00] explorer → developer  |  phase=developer
  kind=update, tool=bash, args=cd <worktree> && grep -n "foreman board" README.md
```

### 5.5 `--raw` Flag (New)

Add `--raw` flag for minimal processing (shows raw body, no JSON parsing):
```
[2026-04-30 09:15] explorer → developer  |  Raw body shown as-is, truncated at 200 chars
```

---

## 6. Non-Functional Requirements

### 6.1 Performance
- Table rendering should not be significantly slower than current text rendering
- Target: < 50ms additional overhead for 100 messages

### 6.2 Compatibility
- Must work with existing `--agent`, `--run`, `--bead`, `--watch`, `--unread`, `--limit`, `--ack` flags
- Must work in both SQLite-store mode and daemon/trpc-client mode

### 6.3 Output Width
- Detect terminal width via `process.stdout.columns`
- When terminal is < 80 chars wide, collapse to minimal columns (DATE, FROM, TO, ARGS only)
- When terminal is ≥ 80 chars, show all 7 columns

---

## 7. Acceptance Criteria

| # | Criterion | Test Scenario |
|---|-----------|---------------|
| AC1 | Default inbox output uses a readable table layout for message rows | Run `foreman inbox` with 5+ messages → output contains header row + separator + data rows |
| AC2 | date/time is shown in a compact sortable format | Message timestamps render as `YYYY-MM-DD HH:MM` |
| AC3 | ticket ID/run context is visible per row | Row shows seedId (from body) or run_id prefix when seedId absent |
| AC4 | kind, tool, and args are extracted from structured payloads when present | Send message with `{"kind":"update","tool":"bash","argsPreview":"cd /repo"}` → table shows `update`, `bash`, `cd /repo` |
| AC5 | Degrades gracefully when fields are absent | Send message with plain text body → table shows `-` for missing fields |
| AC6 | Long args are truncated safely for table display | Send message with args > 40 chars → visible portion ends with `…` |
| AC7 | existing `--full` output mode remains available | Run `foreman inbox --full` → old free-form format shown |
| AC8 | `--raw` flag shows minimal processing | Run `foreman inbox --raw` → raw body truncated at 200, no JSON parsing |

---

## 8. Implementation Notes

### 8.1 File: `src/cli/commands/inbox.ts`

New function: `formatMessageTable(messages: Message[]): string`

```typescript
function formatMessageTable(messages: Message[]): string {
  // Determine columns to show based on terminal width
  // Build header row
  // Build separator row
  // For each message, parse body JSON and extract fields
  // Build data rows with truncation
  // Return joined string
}
```

### 8.2 Parsing Strategy

```typescript
interface ParsedMessage {
  dateTime: string;    // YYYY-MM-DD HH:MM from created_at
  ticket: string;      // seedId from body or run_id prefix
  from: string;        // sender_agent_type
  to: string;          // recipient_agent_type
  kind: string;         // from body.kind or '-'
  tool: string;         // from body.tool or '-'
  args: string;         // from body.argsPreview or body.args or '-'
}

function parseMessageForTable(msg: Message): ParsedMessage {
  let body: Record<string, unknown> = {};
  try {
    body = JSON.parse(msg.body);
  } catch {
    // not JSON — use raw body truncated
  }

  const seedId = typeof body.seedId === 'string' ? body.seedId : null;
  return {
    dateTime: formatTimestampCompact(msg.created_at),
    ticket: seedId ?? msg.run_id.slice(0, 8) + '…',
    from: truncate(msg.sender_agent_type, 10),
    to: truncate(msg.recipient_agent_type, 10),
    kind: typeof body.kind === 'string' ? body.kind : '-',
    tool: typeof body.tool === 'string' ? body.tool : '-',
    args: extractArgs(body) ?? '-',
  };
}
```

### 8.3 Column Width Constants

```typescript
const COLUMNS = {
  DATE_TIME: 16,
  TICKET: 12,
  FROM: 10,
  TO: 10,
  KIND: 8,
  TOOL: 8,
  ARGS: 40,
} as const;

const NARROW_COLUMNS = ['DATE_TIME', 'FROM', 'TO', 'ARGS']; // when < 80 cols
```

---

## 9. File Structure

```
src/cli/commands/inbox.ts         # Add formatMessageTable(), modify inboxCommand default
src/cli/__tests__/inbox.test.ts   # Add tests for table format
src/cli/__tests__/inbox-tabular.test.ts  # NEW: table-specific tests
```

---

## 10. Open Questions

1. **Should `--raw` show the raw body or raw body + subject?** — Currently leaning toward raw body only (subject already in header).
2. **Should table include a # row number column?** — Leaning against for simplicity; can add later.
3. **Should `--watch` use table format or keep current streaming text format?** — Table format; watch should render each new message as a table row as it arrives.