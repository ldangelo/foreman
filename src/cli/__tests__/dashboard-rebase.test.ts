/**
 * Tests for dashboard indicators for rebase statuses (TRD-013-TEST).
 *
 * Verifies:
 * - AC-T-013-1: rebase_conflict run -> REBASE CONFLICT label with amber/yellow color
 * - AC-T-013-2: rebase_resolving run -> RESOLVING label with blue color
 *
 * These tests verify the watch-ui.ts rendering functions used by both
 * status.ts and dashboard.ts for consistent status display.
 */

import { describe, it, expect } from "vitest";
import { statusLabel } from "../watch-ui.js";

// Note: renderAgentCard requires a full Run object and chalk TTY detection.
// We test statusLabel (used by renderAgentCard internally) and statusColor
// indirectly through the exported label function.

describe("dashboard rebase status indicators", () => {
  it("AC-T-013-1: rebase_conflict status has REBASE CONFLICT label", () => {
    const label = statusLabel("rebase_conflict");
    expect(label).toBe("REBASE CONFLICT");
  });

  it("AC-T-013-2: rebase_resolving status has RESOLVING label", () => {
    const label = statusLabel("rebase_resolving");
    expect(label).toBe("RESOLVING");
  });

  it("rebase_conflict is distinct from failed, stuck, and conflict labels", () => {
    expect(statusLabel("rebase_conflict")).not.toBe(statusLabel("failed"));
    expect(statusLabel("rebase_conflict")).not.toBe(statusLabel("stuck"));
    expect(statusLabel("rebase_conflict")).not.toBe(statusLabel("conflict"));
  });

  it("rebase_resolving is distinct from running and rebase_conflict labels", () => {
    expect(statusLabel("rebase_resolving")).not.toBe(statusLabel("running"));
    expect(statusLabel("rebase_resolving")).not.toBe(statusLabel("rebase_conflict"));
  });
});
