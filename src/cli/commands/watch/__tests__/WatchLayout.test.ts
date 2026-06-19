/**
 * Unit tests for WatchLayout.ts
 */

import { describe, it, expect } from "vitest";
import {
  detectLayoutMode,
  getPanelWidths,
  type LayoutMode,
} from "../WatchLayout.js";

describe("WatchLayout", () => {
  describe("detectLayoutMode", () => {
    it("returns too-narrow for < 80 columns", () => {
      expect(detectLayoutMode(60)).toBe("too-narrow");
      expect(detectLayoutMode(79)).toBe("too-narrow");
    });

    it("returns narrow for 80-89 columns", () => {
      expect(detectLayoutMode(80)).toBe("narrow");
      expect(detectLayoutMode(89)).toBe("narrow");
    });

    it("returns medium for 90-119 columns", () => {
      expect(detectLayoutMode(90)).toBe("medium");
      expect(detectLayoutMode(119)).toBe("medium");
    });

    it("returns wide for 120+ columns", () => {
      expect(detectLayoutMode(120)).toBe("wide");
      expect(detectLayoutMode(200)).toBe("wide");
    });
  });

  describe("getPanelWidths", () => {
    it("gives equal widths in narrow (stacked) mode", () => {
      const widths = getPanelWidths("narrow", 80);
      // In stacked mode, each panel gets full available width minus 4
      // So agents, board, inbox all get the same width
      expect(widths.agents).toBe(widths.board);
      expect(widths.board).toBe(widths.inbox);
    });

    it("board and inbox widths are both nonzero in wide mode", () => {
      const widths = getPanelWidths("wide", 120);
      expect(widths.agents).toBeGreaterThan(widths.board);
      expect(widths.board).toBeGreaterThan(0);
      expect(widths.inbox).toBeGreaterThan(0);
    });

    it("board and inbox widths are both nonzero in medium mode", () => {
      const widths = getPanelWidths("medium", 100);
      expect(widths.agents).toBeGreaterThan(widths.board);
      expect(widths.board).toBeGreaterThan(0);
      expect(widths.inbox).toBeGreaterThan(0);
    });

    it("subtracts 4 from total width for borders", () => {
      const totalWidth = 120;
      const widths = getPanelWidths("wide", totalWidth);
      const sum = widths.agents + widths.board + widths.inbox + widths.events;
      expect(sum).toBe(totalWidth - 4);
    });
  });
});
