import { describe, it, expect, vi } from "vitest";
import type { TmuxClient, TmuxSessionInfo } from "../../lib/tmux.js";
import { cleanupTmuxSessions } from "../../cli/commands/reset.js";

function makeTmux() {
  const tmux: {
    isAvailable: ReturnType<typeof vi.fn>;
    listForemanSessions: ReturnType<typeof vi.fn>;
    killSession: ReturnType<typeof vi.fn>;
  } = {
    isAvailable: vi.fn(async () => true),
    listForemanSessions: vi.fn(async (): Promise<TmuxSessionInfo[]> => []),
    killSession: vi.fn(async () => true),
  };
  return tmux;
}

describe("Reset — tmux cleanup (AT-T036 / AT-T037)", () => {
  it("kills all foreman tmux sessions", async () => {
    const tmux = makeTmux();
    tmux.listForemanSessions.mockResolvedValue([
      { sessionName: "foreman-seeds-001", created: 1234, attached: false, windowCount: 1 },
      { sessionName: "foreman-seeds-002", created: 1234, attached: false, windowCount: 1 },
      { sessionName: "foreman-seeds-003", created: 1234, attached: false, windowCount: 1 },
    ]);

    const result = await cleanupTmuxSessions(tmux as unknown as TmuxClient);

    expect(result.killed).toBe(3);
    expect(tmux.killSession).toHaveBeenCalledTimes(3);
    expect(tmux.killSession).toHaveBeenCalledWith("foreman-seeds-001");
    expect(tmux.killSession).toHaveBeenCalledWith("foreman-seeds-002");
    expect(tmux.killSession).toHaveBeenCalledWith("foreman-seeds-003");
  });

  it("returns zero when no sessions exist", async () => {
    const tmux = makeTmux();
    tmux.listForemanSessions.mockResolvedValue([]);

    const result = await cleanupTmuxSessions(tmux as unknown as TmuxClient);

    expect(result.killed).toBe(0);
    expect(tmux.killSession).not.toHaveBeenCalled();
  });

  it("skips silently when tmux is unavailable", async () => {
    const tmux = makeTmux();
    tmux.isAvailable.mockResolvedValue(false);

    const result = await cleanupTmuxSessions(tmux as unknown as TmuxClient);

    expect(result.killed).toBe(0);
    expect(result.skipped).toBe(true);
    expect(tmux.listForemanSessions).not.toHaveBeenCalled();
  });

  it("individual kill failure does not abort cleanup of remaining sessions", async () => {
    const tmux = makeTmux();
    tmux.listForemanSessions.mockResolvedValue([
      { sessionName: "foreman-seeds-001", created: 1234, attached: false, windowCount: 1 },
      { sessionName: "foreman-seeds-002", created: 1234, attached: false, windowCount: 1 },
      { sessionName: "foreman-seeds-003", created: 1234, attached: false, windowCount: 1 },
    ]);
    // Second kill fails
    tmux.killSession
      .mockResolvedValueOnce(true)
      .mockResolvedValueOnce(false) // this one fails
      .mockResolvedValueOnce(true);

    const result = await cleanupTmuxSessions(tmux as unknown as TmuxClient);

    // Should still try all three
    expect(tmux.killSession).toHaveBeenCalledTimes(3);
    // Only 2 were successfully killed
    expect(result.killed).toBe(2);
    expect(result.errors).toBe(1);
  });
});
