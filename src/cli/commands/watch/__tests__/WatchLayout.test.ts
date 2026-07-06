/**
 * Unit tests for WatchLayout.ts
 */

import { describe, it, expect } from "vitest";
import {
  computeLayoutSections,
  detectLayoutMode,
  getPanelWidths,
  renderWatchLayout,
  type LayoutMode,
} from "../WatchLayout.js";
import type { WatchState } from "../WatchState.js";

function makeState(overrides: Partial<WatchState> = {}): WatchState {
  return {
    dashboard: {
      projects: [{ name: "proj-1" }],
      activeRuns: new Map(),
      completedRuns: new Map(),
      progresses: new Map(),
      metrics: new Map(),
      events: new Map(),
      lastUpdated: new Date("2026-01-01T00:00:00.000Z"),
    } as WatchState["dashboard"],
    agents: [],
    board: null,
    inbox: null,
    events: null,
    taskCounts: null,
    lastPollMs: 0,
    lastInboxPollMs: 0,
    inboxLastSeenId: null,
    eventsLastSeenId: null,
    focusedPanel: "agents",
    expandedAgentIndices: new Set(),
    selectedTaskIndex: -1,
    showHelp: false,
    errorMessage: null,
    agentsOffline: false,
    boardOffline: false,
    inboxOffline: false,
    eventsOffline: false,
    ...overrides,
  };
}

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

  describe("computeLayoutSections", () => {
    it("returns a terminal width warning section when too narrow", () => {
      const sections = computeLayoutSections(makeState(), 70);
      expect(sections).toHaveLength(1);
      expect(sections[0]?.panel).toBe("agents");
      expect(sections[0]?.lines.join("\n")).toContain("Terminal too narrow");
    });

    it("renders visible stacked sections for narrow mode with board/inbox/events data", () => {
      const sections = computeLayoutSections(makeState({
        board: {
          counts: { backlog: 1, ready: 2, in_progress: 0, needs_attention: 1, closed: 3 },
          total: 7,
          ready: 2,
          needsAttention: [{ id: "task-1", title: "Needs retry", status: "failed", priority: 1 }] as any,
        },
        inbox: {
          messages: [{
            message: {
              id: "msg-1",
              run_id: "run-1",
              sender_agent_type: "developer",
              recipient_agent_type: "foreman",
              subject: "phase-complete",
              body: "{}",
              read: 0,
              created_at: "2026-01-01T00:00:00.000Z",
              deleted_at: null,
            },
            isNew: true,
          }],
          totalCount: 1,
          newestTimestamp: "2026-01-01T00:00:00.000Z",
          oldestTimestamp: "2026-01-01T00:00:00.000Z",
        },
        events: {
          events: [{
            id: "evt-1",
            eventType: "phase-complete",
            runId: "run-1",
            details: { phase: "developer" },
            createdAt: "2026-01-01T00:00:01.000Z",
            isNew: true,
          } as any],
          totalCount: 1,
          newestTimestamp: "2026-01-01T00:00:01.000Z",
          oldestTimestamp: "2026-01-01T00:00:01.000Z",
        },
      }), 85);

      expect(sections.map((section) => section.panel)).toEqual(["agents", "board", "inbox", "events"]);
      expect(sections.find((section) => section.panel === "agents")?.lines.join("\n")).toContain("no agents running");
      expect(sections.find((section) => section.panel === "board")?.lines.join("\n")).toContain("Needs attention");
      expect(sections.find((section) => section.panel === "inbox")?.lines.join("\n")).toContain("phase-complete");
      expect(sections.find((section) => section.panel === "events")?.lines.join("\n")).toContain("Complete: developer");
    });

    it("filters out unavailable optional panels", () => {
      const sections = computeLayoutSections(makeState({
        board: null,
        inbox: null,
        events: null,
        agentsOffline: true,
        boardOffline: true,
        inboxOffline: true,
        eventsOffline: true,
      }), 120);

      expect(sections.map((section) => section.panel)).toEqual(["agents"]);
    });
  });

  describe("renderWatchLayout", () => {
    it("renders a too-narrow warning", () => {
      const rendered = renderWatchLayout(makeState(), 70);
      expect(rendered).toContain("Terminal too narrow");
      expect(rendered).toContain("foreman dashboard");
    });

    it("renders wide side-by-side layout plus error and last-updated footer", () => {
      const rendered = renderWatchLayout(makeState({
        agents: [{
          run: {
            id: "run-1",
            project_id: "proj-1",
            task_id: "task-1",
            agent_type: "developer",
            session_key: null,
            worktree_path: "/tmp/wt",
            status: "running",
            started_at: "2026-01-01T00:00:00.000Z",
            completed_at: null,
            created_at: "2026-01-01T00:00:00.000Z",
            progress: null,
          },
          progress: null,
        }] as any,
        board: {
          counts: { backlog: 1, ready: 1, in_progress: 1, needs_attention: 0, closed: 0 },
          total: 3,
          ready: 1,
          needsAttention: [],
        },
        inbox: {
          messages: [],
          totalCount: 0,
          newestTimestamp: null,
          oldestTimestamp: null,
        },
        errorMessage: "boom",
        lastPollMs: new Date("2026-01-01T12:34:56.000Z").getTime(),
      }), 120);

      expect(rendered).toContain("FOREMAN WATCH");
      expect(rendered).toContain("AGENTS");
      expect(rendered).toContain("BOARD");
      expect(rendered).toContain("INBOX");
      expect(rendered).toContain("Error: boom");
      expect(rendered).toContain("Last updated:");
      expect(rendered).toContain("task-1");
    });
  });
});
