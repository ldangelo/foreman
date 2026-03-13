import { describe, it, expect } from "vitest";
import {
  parseTableHeader,
  parseTableRow,
  splitTableRow,
  parseEpic,
  parseSprintHeader,
  parseStoryHeader,
  parseAcceptanceCriteria,
  parseRiskRegister,
  parseQualityRequirements,
  parseSprintSummary,
  parseTrd,
} from "../trd-parser.js";

// ── splitTableRow ────────────────────────────────────────────────────────

describe("splitTableRow", () => {
  it("splits a standard table row", () => {
    expect(splitTableRow("| A | B | C |")).toEqual(["A", "B", "C"]);
  });

  it("handles cells with backtick content", () => {
    const row = "| MQ-T001 | Do something | `src/foo.ts` |";
    const cells = splitTableRow(row);
    expect(cells[0]).toBe("MQ-T001");
    expect(cells[2]).toBe("`src/foo.ts`");
  });

  it("handles whitespace variations", () => {
    expect(splitTableRow("|A|B|C|")).toEqual(["A", "B", "C"]);
  });
});

// ── parseTableHeader ─────────────────────────────────────────────────────

describe("parseTableHeader", () => {
  it("detects standard column order", () => {
    const header = "| ID | Task | Est. | Deps | Files | Status |";
    const map = parseTableHeader(header);
    expect(map.id).toBe(0);
    expect(map.task).toBe(1);
    expect(map.estimate).toBe(2);
    expect(map.deps).toBe(3);
    expect(map.files).toBe(4);
    expect(map.status).toBe(5);
  });

  it("detects reordered columns", () => {
    const header = "| Task | ID | Status | Deps |";
    const map = parseTableHeader(header);
    expect(map.id).toBe(1);
    expect(map.task).toBe(0);
    expect(map.status).toBe(2);
    expect(map.deps).toBe(3);
    expect(map.files).toBeNull();
    expect(map.estimate).toBeNull();
  });

  it("handles missing optional columns", () => {
    const header = "| ID | Task |";
    const map = parseTableHeader(header);
    expect(map.id).toBe(0);
    expect(map.task).toBe(1);
    expect(map.estimate).toBeNull();
    expect(map.deps).toBeNull();
    expect(map.files).toBeNull();
    expect(map.status).toBeNull();
  });

  it("throws SLING-010 when ID column is missing", () => {
    const header = "| Task | Estimate |";
    expect(() => parseTableHeader(header)).toThrow("SLING-010");
  });

  it("throws SLING-010 when Task column is missing", () => {
    const header = "| ID | Files |";
    expect(() => parseTableHeader(header)).toThrow("SLING-010");
  });

  it("is case-insensitive", () => {
    const header = "| id | TASK | EST. | DEPS |";
    const map = parseTableHeader(header);
    expect(map.id).toBe(0);
    expect(map.task).toBe(1);
  });
});

// ── parseTableRow ────────────────────────────────────────────────────────

describe("parseTableRow", () => {
  const columns = parseTableHeader("| ID | Task | Est. | Deps | Files | Status |");

  it("parses a complete row", () => {
    const row = "| MQ-T001 | Implement autoCommitStateFiles() | 3h | -- | `src/orchestrator/refinery.ts` | [x] |";
    const task = parseTableRow(row, columns);
    expect(task.trdId).toBe("MQ-T001");
    expect(task.title).toBe("Implement autoCommitStateFiles()");
    expect(task.estimateHours).toBe(3);
    expect(task.dependencies).toEqual([]);
    expect(task.files).toEqual(["src/orchestrator/refinery.ts"]);
    expect(task.status).toBe("completed");
  });

  it("parses dependencies", () => {
    const row = "| MQ-T002 | Wire function | 2h | MQ-T001 | `src/foo.ts` | [ ] |";
    const task = parseTableRow(row, columns);
    expect(task.dependencies).toEqual(["MQ-T001"]);
  });

  it("parses multiple dependencies", () => {
    const row = "| MQ-T005 | Update callers | 2h | MQ-T001, MQ-T004 | `src/foo.ts` | [ ] |";
    const task = parseTableRow(row, columns);
    expect(task.dependencies).toEqual(["MQ-T001", "MQ-T004"]);
  });

  it("parses multiple files", () => {
    const row = "| MQ-T005 | Do thing | 2h | -- | `src/a.ts`, `src/b.ts` | [ ] |";
    const task = parseTableRow(row, columns);
    expect(task.files).toEqual(["src/a.ts", "src/b.ts"]);
  });

  it("parses in_progress status", () => {
    const row = "| SL-T001 | Working | 4h | -- | `src/foo.ts` | [~] |";
    const task = parseTableRow(row, columns);
    expect(task.status).toBe("in_progress");
  });

  it("parses open status", () => {
    const row = "| SL-T001 | Todo | 4h | -- | `src/foo.ts` | [ ] |";
    const task = parseTableRow(row, columns);
    expect(task.status).toBe("open");
  });

  it("handles -- as no deps", () => {
    const row = "| SL-T001 | Do something | 3h | -- | `src/foo.ts` | [ ] |";
    const task = parseTableRow(row, columns);
    expect(task.dependencies).toEqual([]);
  });

  it("handles missing optional fields with minimal columns", () => {
    const minColumns = parseTableHeader("| ID | Task |");
    const row = "| SL-T001 | Do something |";
    const task = parseTableRow(row, minColumns);
    expect(task.trdId).toBe("SL-T001");
    expect(task.title).toBe("Do something");
    expect(task.estimateHours).toBe(0);
    expect(task.dependencies).toEqual([]);
    expect(task.files).toEqual([]);
    expect(task.status).toBe("open");
  });
});

// ── parseEpic ────────────────────────────────────────────────────────────

describe("parseEpic", () => {
  it("extracts title and document ID", () => {
    const content = `# TRD: Merge Queue Epic

**Document ID:** TRD-MERGE-QUEUE
**Version:** 1.2
**Epic ID:** bd-uba

---

## 1. System Architecture`;

    const epic = parseEpic(content);
    expect(epic.title).toBe("TRD: Merge Queue Epic");
    expect(epic.documentId).toBe("TRD-MERGE-QUEUE");
    expect(epic.version).toBe("1.2");
    expect(epic.epicId).toBe("bd-uba");
  });

  it("captures description between H1 and first H2", () => {
    const content = `# My TRD

**Document ID:** TRD-TEST

Some description text here.
More description.

## Section 1`;

    const epic = parseEpic(content);
    expect(epic.description).toContain("Some description text here.");
    expect(epic.description).toContain("More description.");
  });
});

// ── parseSprintHeader ────────────────────────────────────────────────────

describe("parseSprintHeader", () => {
  it("parses standard sprint header", () => {
    const result = parseSprintHeader("### 2.1 Sprint 1: Foundation (FR-2, FR-4) -- Quick Wins");
    expect(result).not.toBeNull();
    expect(result!.number).toBe(1);
    expect(result!.title).toBe("Sprint 1: Foundation");
    expect(result!.frRefs).toEqual(["FR-2", "FR-4"]);
  });

  it("parses sub-sprint (3a, 3b)", () => {
    const result = parseSprintHeader("### 2.3 Sprint 3a: Deterministic Resolution (FR-1, Tier 1-2)");
    expect(result).not.toBeNull();
    expect(result!.number).toBe(3);
    expect(result!.suffix).toBe("a");
  });

  it("parses sprint without FR refs", () => {
    const result = parseSprintHeader("### 2.8 Sprint 8: Health Checks, Edge Cases, Polish (FR-9, FR-10)");
    expect(result).not.toBeNull();
    expect(result!.number).toBe(8);
    expect(result!.frRefs).toEqual(["FR-9", "FR-10"]);
  });

  it("returns null for non-sprint headers", () => {
    expect(parseSprintHeader("### 1.1 Architecture Overview")).toBeNull();
    expect(parseSprintHeader("## Some Section")).toBeNull();
  });

  it("applies ordinal priority fallback", () => {
    const s1 = parseSprintHeader("### 2.1 Sprint 1: Foundation");
    expect(s1!.priority).toBe("critical");

    const s3 = parseSprintHeader("### 2.3 Sprint 3: Middle");
    expect(s3!.priority).toBe("high");

    const s7 = parseSprintHeader("### 2.7 Sprint 7: Late");
    expect(s7!.priority).toBe("medium");
  });
});

// ── parseStoryHeader ─────────────────────────────────────────────────────

describe("parseStoryHeader", () => {
  it("parses standard story header", () => {
    const result = parseStoryHeader("#### Story 1.1: Auto-Commit State Files Before Merge");
    expect(result).not.toBeNull();
    expect(result!.ref).toBe("1.1");
    expect(result!.title).toBe("Auto-Commit State Files Before Merge");
  });

  it("returns null for non-story headers", () => {
    expect(parseStoryHeader("#### Some Other Section")).toBeNull();
  });
});

// ── parseAcceptanceCriteria ──────────────────────────────────────────────

describe("parseAcceptanceCriteria", () => {
  it("parses AC section by FR number", () => {
    const content = `## 5. Acceptance Criteria (Technical Validation)

### 5.1 FR-1: AI-Powered Conflict Resolution

- [ ] AC-1.1: Clean merges complete without invoking any resolution tier
- [ ] AC-1.2: Tier 2 per-file auto-resolve succeeds

### 5.2 FR-2: Auto-Commit State Files

- [ ] AC-2.1: Uncommitted changes auto-committed before merge

## 6. Quality Requirements`;

    const acs = parseAcceptanceCriteria(content);
    expect(acs.has("FR-1")).toBe(true);
    expect(acs.get("FR-1")).toContain("AC-1.1");
    expect(acs.get("FR-1")).toContain("AC-1.2");
    expect(acs.has("FR-2")).toBe(true);
    expect(acs.get("FR-2")).toContain("AC-2.1");
  });

  it("returns empty map when no Section 5", () => {
    const acs = parseAcceptanceCriteria("# Some TRD\n\n## 1. Architecture");
    expect(acs.size).toBe(0);
  });
});

// ── parseRiskRegister ────────────────────────────────────────────────────

describe("parseRiskRegister", () => {
  it("parses risks and maps to task IDs", () => {
    const content = `## 7. Risk Register

| Risk | Likelihood | Impact | Mitigation | Tasks Affected |
|------|-----------|--------|------------|---------------|
| AI produces invalid code | Medium | High | Validation | MQ-T030 to MQ-T037 |
| Cost escalation | Low | Medium | Budget cap | MQ-T032, MQ-T052 |

## 8. Files`;

    const risks = parseRiskRegister(content);
    expect(risks.get("MQ-T030")).toBe("high");
    expect(risks.get("MQ-T037")).toBe("high");
    expect(risks.get("MQ-T032")).toBe("medium");
    expect(risks.get("MQ-T052")).toBe("medium");
  });

  it("returns empty map when no Section 7", () => {
    const risks = parseRiskRegister("# TRD\n## 1. Foo");
    expect(risks.size).toBe(0);
  });
});

// ── parseQualityRequirements ─────────────────────────────────────────────

describe("parseQualityRequirements", () => {
  it("extracts Section 6 content", () => {
    const content = `## 6. Quality Requirements

### 6.1 Testing Standards

| Type | Target |
|------|--------|
| Unit test coverage | >= 80% |

## 7. Risk Register`;

    const quality = parseQualityRequirements(content);
    expect(quality).toBeDefined();
    expect(quality).toContain("Testing Standards");
    expect(quality).toContain(">= 80%");
  });

  it("returns undefined when no Section 6", () => {
    const quality = parseQualityRequirements("# TRD\n## 1. Foo");
    expect(quality).toBeUndefined();
  });
});

// ── parseSprintSummary ───────────────────────────────────────────────────

describe("parseSprintSummary", () => {
  it("parses sprint planning summary table", () => {
    const content = `## 3. Sprint Planning Summary

| Sprint | Focus | Tasks | Est. Hours | Key Deliverables |
|--------|-------|-------|-----------|-----------------|
| 1 | Foundation | MQ-T001 to MQ-T006 | 16h | Auto-commit, safe deletion |
| 2 | Merge Queue Core | MQ-T007 to MQ-T020 | 37h | SQLite queue, CLI integration |

## 4. Dependency Graph`;

    const summary = parseSprintSummary(content);
    expect(summary.size).toBe(2);
    expect(summary.get(1)!.focus).toBe("Foundation");
    expect(summary.get(1)!.estimatedHours).toBe(16);
    expect(summary.get(1)!.deliverables).toContain("Auto-commit");
    expect(summary.get(2)!.focus).toBe("Merge Queue Core");
    expect(summary.get(2)!.estimatedHours).toBe(37);
  });
});

// ── parseTrd (end-to-end) ────────────────────────────────────────────────

describe("parseTrd", () => {
  const minimalTrd = `# TRD: Test Project

**Document ID:** TRD-TEST

---

## 2. Master Task List

### 2.1 Sprint 1: Foundation

#### Story 1.1: First Story

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| TP-T001 | First task | 3h | -- | \`src/foo.ts\` | [ ] |
| TP-T002 | Second task | 2h | TP-T001 | \`src/bar.ts\` | [x] |

#### Story 1.2: Second Story

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| TP-T003 | Third task | 1h | -- | \`src/baz.ts\` | [ ] |

### 2.2 Sprint 2: Advanced

#### Story 2.1: Third Story

| ID | Task | Est. | Deps | Files | Status |
|----|------|------|------|-------|--------|
| TP-T004 | Fourth task | 4h | TP-T001 | \`src/qux.ts\` | [ ] |
`;

  it("extracts correct number of sprints, stories, and tasks", () => {
    const plan = parseTrd(minimalTrd);
    expect(plan.sprints).toHaveLength(2);
    expect(plan.sprints[0].stories).toHaveLength(2);
    expect(plan.sprints[0].stories[0].tasks).toHaveLength(2);
    expect(plan.sprints[0].stories[1].tasks).toHaveLength(1);
    expect(plan.sprints[1].stories).toHaveLength(1);
    expect(plan.sprints[1].stories[0].tasks).toHaveLength(1);
  });

  it("preserves task IDs and dependencies", () => {
    const plan = parseTrd(minimalTrd);
    const task1 = plan.sprints[0].stories[0].tasks[0];
    expect(task1.trdId).toBe("TP-T001");
    expect(task1.dependencies).toEqual([]);

    const task2 = plan.sprints[0].stories[0].tasks[1];
    expect(task2.dependencies).toEqual(["TP-T001"]);

    const task4 = plan.sprints[1].stories[0].tasks[0];
    expect(task4.dependencies).toEqual(["TP-T001"]);
  });

  it("extracts epic metadata", () => {
    const plan = parseTrd(minimalTrd);
    expect(plan.epic.title).toBe("TRD: Test Project");
    expect(plan.epic.documentId).toBe("TRD-TEST");
  });

  it("extracts status correctly", () => {
    const plan = parseTrd(minimalTrd);
    expect(plan.sprints[0].stories[0].tasks[0].status).toBe("open");
    expect(plan.sprints[0].stories[0].tasks[1].status).toBe("completed");
  });

  it("throws SLING-002 on empty TRD", () => {
    const empty = `# TRD: Empty

**Document ID:** TRD-EMPTY

## 1. Nothing here`;

    expect(() => parseTrd(empty)).toThrow("SLING-002");
  });
});
