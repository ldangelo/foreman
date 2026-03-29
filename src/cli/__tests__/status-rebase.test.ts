/**
 * Tests for foreman status display of rebase statuses (TRD-012-TEST).
 *
 * Verifies:
 * - AC-T-012-1: rebase_conflict run -> output includes 'REBASE CONFLICT'
 * - AC-T-012-2: rebase_resolving run -> output includes 'RESOLVING'
 */

import { describe, it, expect } from "vitest";
import { statusLabel } from "../watch-ui.js";

describe("statusLabel — rebase status display", () => {
  it("AC-T-012-1: rebase_conflict maps to 'REBASE CONFLICT'", () => {
    expect(statusLabel("rebase_conflict")).toBe("REBASE CONFLICT");
  });

  it("AC-T-012-2: rebase_resolving maps to 'RESOLVING'", () => {
    expect(statusLabel("rebase_resolving")).toBe("RESOLVING");
  });

  it("existing statuses still render as uppercase", () => {
    expect(statusLabel("running")).toBe("RUNNING");
    expect(statusLabel("failed")).toBe("FAILED");
    expect(statusLabel("completed")).toBe("COMPLETED");
    expect(statusLabel("stuck")).toBe("STUCK");
  });
});
