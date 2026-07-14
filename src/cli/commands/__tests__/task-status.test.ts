import { describe, expect, it } from "vitest";
import { renderRunStatusLine } from "../task.js";

describe("renderRunStatusLine", () => {
  describe("workflow phases display", () => {
    it("displays full workflow phase sequence when workflowPhases is provided", () => {
      const activity = {
        runId: "run-123",
        status: "in_progress",  // Elixir backend uses "in_progress"
        currentPhase: "developer",
        workflowPhases: ["explorer", "developer", "qa", "finalize", "create-pr", "pr-wait", "merge"],
        lastActivity: new Date().toISOString(),
        lastActivityElapsed: "5m ago",
        isStuck: false,
        isStale: false,
        toolCalls: 10,
        costUsd: 0.5,
        turns: 5,
        startedAt: null,
        completedAt: null,
        totalDurationMs: null,
        costPerTurn: null,
        timePerTurn: null,
      };

      const output = renderRunStatusLine(activity);

      // Should show running status (Elixir uses "in_progress")
      expect(output).toContain("IN_PROGRESS");

      // Should display all workflow phases
      expect(output).toContain("explorer");
      expect(output).toContain("developer");
      expect(output).toContain("qa");
      expect(output).toContain("finalize");
      expect(output).toContain("create-pr");
      expect(output).toContain("pr-wait");
      expect(output).toContain("merge");

      // Should show arrows between phases
      expect(output).toContain("→");
    });

    it("highlights current phase with brackets", () => {
      const activity = {
        runId: "run-123",
        status: "in_progress",
        currentPhase: "qa",
        workflowPhases: ["explorer", "developer", "qa", "finalize"],
        lastActivity: new Date().toISOString(),
        lastActivityElapsed: "2m ago",
        isStuck: false,
        isStale: false,
        toolCalls: 5,
        costUsd: 0.25,
        turns: 3,
        startedAt: null,
        completedAt: null,
        totalDurationMs: null,
        costPerTurn: null,
        timePerTurn: null,
      };

      const output = renderRunStatusLine(activity);

      // Current phase should be highlighted with brackets
      expect(output).toContain("[qa]");
    });

    it("shows completed phases in dim style", () => {
      const activity = {
        runId: "run-123",
        status: "in_progress",
        currentPhase: "developer",
        workflowPhases: ["explorer", "developer", "qa"],
        lastActivity: new Date().toISOString(),
        lastActivityElapsed: "1m ago",
        isStuck: false,
        isStale: false,
        toolCalls: 2,
        costUsd: 0.1,
        turns: 1,
        startedAt: null,
        completedAt: null,
        totalDurationMs: null,
        costPerTurn: null,
        timePerTurn: null,
      };

      const output = renderRunStatusLine(activity);

      // explorer should be completed (before developer)
      expect(output).toContain("explorer");
      // developer is current, should be highlighted
      expect(output).toContain("[developer]");
      // qa is future
      expect(output).toContain("qa");
    });

    it("falls back to currentPhase only when workflowPhases is not available", () => {
      const activity = {
        runId: "run-123",
        status: "in_progress",
        currentPhase: "developer",
        workflowPhases: null,
        lastActivity: new Date().toISOString(),
        lastActivityElapsed: "3m ago",
        isStuck: false,
        isStale: false,
        toolCalls: 8,
        costUsd: 0.4,
        turns: 4,
        startedAt: null,
        completedAt: null,
        totalDurationMs: null,
        costPerTurn: null,
        timePerTurn: null,
      };

      const output = renderRunStatusLine(activity);

      // Should still show the current phase
      expect(output).toContain("developer");
      // Should NOT show workflow phase arrows
      expect(output).not.toContain("→");
    });

    it("handles empty workflowPhases array", () => {
      const activity = {
        runId: "run-123",
        status: "in_progress",
        currentPhase: "developer",
        workflowPhases: [],
        lastActivity: new Date().toISOString(),
        lastActivityElapsed: "1m ago",
        isStuck: false,
        isStale: false,
        toolCalls: 1,
        costUsd: 0.05,
        turns: 1,
        startedAt: null,
        completedAt: null,
        totalDurationMs: null,
        costPerTurn: null,
        timePerTurn: null,
      };

      const output = renderRunStatusLine(activity);

      // Should fall back to currentPhase display
      expect(output).toContain("developer");
      expect(output).not.toContain("→");
    });

    it("handles troubleshoothooter phase with red color", () => {
      const activity = {
        runId: "run-123",
        status: "in_progress",
        currentPhase: "troubleshooter",
        workflowPhases: ["explorer", "developer", "troubleshooter", "finalize"],
        lastActivity: new Date().toISOString(),
        lastActivityElapsed: "10s ago",
        isStuck: false,
        isStale: false,
        toolCalls: 15,
        costUsd: 0.75,
        turns: 7,
        startedAt: null,
        completedAt: null,
        totalDurationMs: null,
        costPerTurn: null,
        timePerTurn: null,
      };

      const output = renderRunStatusLine(activity);

      // Should show troubleshooter phase
      expect(output).toContain("troubleshooter");
      expect(output).toContain("[troubleshooter]");
    });
  });

  describe("status display", () => {
    it("shows STUCK warning for stuck runs", () => {
      const activity = {
        runId: "run-123",
        status: "running",
        currentPhase: "developer",
        workflowPhases: ["explorer", "developer"],
        lastActivity: new Date(Date.now() - 20 * 60 * 1000).toISOString(), // 20 mins ago
        lastActivityElapsed: "20m ago",
        isStuck: true,
        isStale: false,
        toolCalls: 3,
        costUsd: 0.15,
        turns: 2,
        startedAt: null,
        completedAt: null,
        totalDurationMs: null,
        costPerTurn: null,
        timePerTurn: null,
      };

      const output = renderRunStatusLine(activity);
      expect(output).toContain("STUCK");
    });

    it("shows FAILED for failed runs", () => {
      const activity = {
        runId: "run-123",
        status: "failed",
        currentPhase: "developer",
        workflowPhases: ["explorer", "developer"],
        lastActivity: new Date().toISOString(),
        lastActivityElapsed: "1m ago",
        isStuck: false,
        isStale: false,
        toolCalls: 5,
        costUsd: 0.25,
        turns: 3,
        startedAt: null,
        completedAt: null,
        totalDurationMs: null,
        costPerTurn: null,
        timePerTurn: null,
      };

      const output = renderRunStatusLine(activity);
      expect(output).toContain("FAILED");
    });

    it("shows COMPLETED for completed runs", () => {
      const activity = {
        runId: "run-123",
        status: "completed",
        currentPhase: "merge",
        workflowPhases: ["explorer", "developer", "qa", "finalize", "create-pr", "pr-wait", "merge"],
        lastActivity: new Date().toISOString(),
        lastActivityElapsed: "1m ago",
        isStuck: false,
        isStale: false,
        toolCalls: 50,
        costUsd: 2.5,
        turns: 25,
        startedAt: null,
        completedAt: null,
        totalDurationMs: null,
        costPerTurn: null,
        timePerTurn: null,
      };

      const output = renderRunStatusLine(activity);
      expect(output).toContain("COMPLETED");
    });

    it("shows MERGED for merged runs", () => {
      const activity = {
        runId: "run-123",
        status: "merged",
        currentPhase: "merge",
        workflowPhases: ["explorer", "developer", "qa", "finalize", "create-pr", "pr-wait", "merge"],
        lastActivity: new Date().toISOString(),
        lastActivityElapsed: "30s ago",
        isStuck: false,
        isStale: false,
        toolCalls: 60,
        costUsd: 3.0,
        turns: 30,
        startedAt: null,
        completedAt: null,
        totalDurationMs: null,
        costPerTurn: null,
        timePerTurn: null,
      };

      const output = renderRunStatusLine(activity);
      expect(output).toContain("MERGED");
    });
  });
});
