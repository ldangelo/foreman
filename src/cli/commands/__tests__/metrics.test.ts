import { afterEach, describe, expect, it, vi } from "vitest";
import chalk from "chalk";

// Create mock functions at module level using vi.hoisted
const { mockEnsureRunning, mockGetMetrics } = vi.hoisted(() => ({
  mockEnsureRunning: vi.fn(),
  mockGetMetrics: vi.fn(),
}));

// Mock ElixirServerManager
vi.mock("../../../lib/elixir-server-manager.js", () => ({
  ElixirServerManager: vi.fn().mockImplementation(function MockElixirServerManager() {
    return { ensureRunning: mockEnsureRunning };
  }),
}));

// Mock ElixirServerClient
vi.mock("../../../lib/elixir-server-client.js", () => ({
  ElixirServerClient: vi.fn().mockImplementation(function MockElixirServerClient() {
    return { getMetrics: mockGetMetrics };
  }),
}));

describe("metrics command", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  describe("displayMetrics", () => {
    it("displays all metrics when data is available", async () => {
      const { displayMetrics } = await import("../metrics.js");

      mockEnsureRunning.mockResolvedValue({ url: "http://localhost:4000" });
      mockGetMetrics.mockResolvedValue({
        total_cost: 42.5,
        total_turns: 100,
        cost_per_turn: 0.425,
        total_time_seconds: 3600,
        time_per_turn_seconds: 36,
      });

      const log = vi.spyOn(console, "log").mockImplementation(() => {});
      const error = vi.spyOn(console, "error").mockImplementation(() => {});

      await displayMetrics();

      expect(log).toHaveBeenCalledWith(chalk.bold("Task Metrics\n"));
      expect(log).toHaveBeenCalledWith(`  Total Cost: ${chalk.yellow("$42.50")}`);
      expect(log).toHaveBeenCalledWith(`  Total Turns: ${chalk.white("100")}`);
      expect(log).toHaveBeenCalledWith(`  Cost per Turn: ${chalk.yellow("$0.4250")}`);
      expect(log).toHaveBeenCalledWith(expect.stringContaining("  Total Time:"));
      expect(log).toHaveBeenCalledWith(expect.stringContaining("  Time per Turn:"));
      expect(error).not.toHaveBeenCalled();
    });

    it("handles zero turns gracefully", async () => {
      const { displayMetrics } = await import("../metrics.js");

      mockEnsureRunning.mockResolvedValue({ url: "http://localhost:4000" });
      mockGetMetrics.mockResolvedValue({
        total_cost: 0,
        total_turns: 0,
        cost_per_turn: 0,
        total_time_seconds: 0,
        time_per_turn_seconds: 0,
      });

      const log = vi.spyOn(console, "log").mockImplementation(() => {});
      const error = vi.spyOn(console, "error").mockImplementation(() => {});

      await displayMetrics();

      expect(log).toHaveBeenCalledWith(`  Cost per Turn: ${chalk.dim("—")}`);
      expect(log).toHaveBeenCalledWith(`  Time per Turn: ${chalk.dim("—")}`);
      expect(error).not.toHaveBeenCalled();
    });

    it("handles string values from the API", async () => {
      const { displayMetrics } = await import("../metrics.js");

      mockEnsureRunning.mockResolvedValue({ url: "http://localhost:4000" });
      mockGetMetrics.mockResolvedValue({
        total_cost: "123.456",
        total_turns: 50,
        cost_per_turn: "2.46912",
        total_time_seconds: 7200,
        time_per_turn_seconds: "144",
      });

      const log = vi.spyOn(console, "log").mockImplementation(() => {});
      const error = vi.spyOn(console, "error").mockImplementation(() => {});

      await displayMetrics();

      expect(log).toHaveBeenCalledWith(`  Total Cost: ${chalk.yellow("$123.46")}`);
      expect(log).toHaveBeenCalledWith(`  Cost per Turn: ${chalk.yellow("$2.4691")}`);
      expect(error).not.toHaveBeenCalled();
    });

    it("handles missing/undefined values gracefully", async () => {
      const { displayMetrics } = await import("../metrics.js");

      mockEnsureRunning.mockResolvedValue({ url: "http://localhost:4000" });
      mockGetMetrics.mockResolvedValue({
        total_cost: undefined,
        total_turns: undefined,
        cost_per_turn: undefined,
        total_time_seconds: undefined,
        time_per_turn_seconds: undefined,
      });

      const log = vi.spyOn(console, "log").mockImplementation(() => {});
      const error = vi.spyOn(console, "error").mockImplementation(() => {});

      await displayMetrics();

      expect(log).toHaveBeenCalledWith(`  Total Cost: ${chalk.yellow("$0.00")}`);
      expect(log).toHaveBeenCalledWith(`  Total Turns: ${chalk.white("0")}`);
      expect(log).toHaveBeenCalledWith(`  Cost per Turn: ${chalk.dim("—")}`);
      expect(log).toHaveBeenCalledWith(`  Total Time: ${chalk.dim("—")}`);
      expect(log).toHaveBeenCalledWith(`  Time per Turn: ${chalk.dim("—")}`);
      expect(error).not.toHaveBeenCalled();
    });

    it("throws error on API failure", async () => {
      const { displayMetrics } = await import("../metrics.js");

      mockEnsureRunning.mockResolvedValue({ url: "http://localhost:4000" });
      mockGetMetrics.mockRejectedValue(new Error("Connection refused"));

      await expect(displayMetrics()).rejects.toThrow("Connection refused");
    });
  });
});
