import { afterEach, describe, expect, it, vi } from "vitest";

const queryMock = vi.hoisted(() => vi.fn());

vi.mock("../../lib/db/pool-manager.js", () => ({
  PoolManager: {
    getPool: () => ({ query: queryMock }),
  },
}));

const store = await import("../jira-debounce-store.js");

afterEach(() => {
  queryMock.mockReset();
});

describe("jira debounce store", () => {
  it("bypasses debounce checks and cleanup when the debounce window is disabled", async () => {
    await expect(store.isDebounced("jira-1", "ABC-1", 0)).resolves.toBe(false);
    await expect(store.cleanup(0)).resolves.toBe(0);
    expect(queryMock).not.toHaveBeenCalled();
  });

  it("reads debounce status from jira_issue_states", async () => {
    const lastTriggeredAt = new Date("2026-01-02T03:04:05Z");
    queryMock.mockResolvedValueOnce({ rows: [{ is_debounced: true }] });
    queryMock.mockResolvedValueOnce({ rows: [{ last_triggered_at: lastTriggeredAt }] });
    queryMock.mockResolvedValueOnce({ rows: [] });

    await expect(store.isDebounced("jira-1", "ABC-1", 60)).resolves.toBe(true);
    await expect(store.getDebounceStatus("jira-1", "ABC-1")).resolves.toEqual({
      isDebounced: true,
      lastTriggeredAt,
    });
    await expect(store.getDebounceStatus("jira-1", "ABC-2")).resolves.toEqual({
      isDebounced: false,
      lastTriggeredAt: null,
    });
  });

  it("upserts triggered and last-known status state", async () => {
    queryMock.mockResolvedValue({ rows: [], rowCount: 0 });

    await store.setDebounced("jira-1", "ABC-1", "Ready");
    await store.updateStatus("jira-1", "ABC-1", "In Progress");

    expect(queryMock).toHaveBeenNthCalledWith(1, expect.stringContaining("last_triggered_at"), ["jira-1", "ABC-1", "Ready"]);
    expect(queryMock).toHaveBeenNthCalledWith(2, expect.stringContaining("last_known_status"), ["jira-1", "ABC-1", "In Progress"]);
  });

  it("returns last known status and detects new transitions", async () => {
    queryMock.mockResolvedValueOnce({ rows: [{ last_known_status: "Backlog" }] });
    await expect(store.getLastKnownStatus("jira-1", "ABC-1")).resolves.toBe("Backlog");

    queryMock.mockResolvedValueOnce({ rows: [] });
    await expect(store.getLastKnownStatus("jira-1", "ABC-2")).resolves.toBeNull();

    queryMock.mockResolvedValueOnce({ rows: [] });
    await expect(store.isNewTransition("jira-1", "ABC-3", ["Ready"])).resolves.toBe(false);

    queryMock.mockResolvedValueOnce({ rows: [{ last_known_status: "Ready" }] });
    await expect(store.isNewTransition("jira-1", "ABC-4", ["Ready"])).resolves.toBe(false);

    queryMock.mockResolvedValueOnce({ rows: [{ last_known_status: "Backlog" }] });
    await expect(store.isNewTransition("jira-1", "ABC-5", ["Ready"])).resolves.toBe(true);
  });

  it("cleans expired entries and maps issue state rows", async () => {
    const lastTriggeredAt = new Date("2026-01-02T03:04:05Z");
    queryMock.mockResolvedValueOnce({ rows: [{ id: 1 }, { id: 2 }], rowCount: 2 });
    await expect(store.cleanup(120)).resolves.toBe(2);

    queryMock.mockResolvedValueOnce({
      rows: [
        { issue_key: "ABC-1", last_known_status: "Ready", last_triggered_at: lastTriggeredAt },
        { issue_key: "ABC-2", last_known_status: null, last_triggered_at: null },
      ],
    });

    await expect(store.getIssueStates("jira-1")).resolves.toEqual([
      { issueKey: "ABC-1", lastKnownStatus: "Ready", lastTriggeredAt },
      { issueKey: "ABC-2", lastKnownStatus: "", lastTriggeredAt: null },
    ]);
  });
});
