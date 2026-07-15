import { describe, expect, it } from "vitest";

import type { Message } from "../../../../lib/store.js";
import { selectInboxMessages } from "../WatchState.js";

function message(id: string, created_at: string): Message {
  return {
    id,
    run_id: "run-1",
    sender_agent_type: "developer",
    recipient_agent_type: "foreman",
    subject: id,
    body: id,
    read: 0,
    created_at,
    deleted_at: null,
  };
}

describe("selectInboxMessages", () => {
  it("keeps the newest limited window in chronological order", () => {
    const result = selectInboxMessages([
      message("msg-new", "2026-01-01T00:03:00.000Z"),
      message("msg-oldest", "2026-01-01T00:01:00.000Z"),
      message("msg-newest", "2026-01-01T00:04:00.000Z"),
      message("msg-old", "2026-01-01T00:02:00.000Z"),
    ], 3, "msg-new");

    expect(result.totalCount).toBe(4);
    expect(result.newestId).toBe("msg-newest");
    expect(result.messages.map((entry) => entry.message.id)).toEqual(["msg-old", "msg-new", "msg-newest"]);
    expect(result.messages.map((entry) => entry.isNew)).toEqual([false, false, true]);
  });

  it("returns an empty window when the inbox limit is zero", () => {
    const result = selectInboxMessages([
      message("msg-old", "2026-01-01T00:01:00.000Z"),
      message("msg-new", "2026-01-01T00:02:00.000Z"),
    ], 0, "msg-old");

    expect(result.totalCount).toBe(2);
    expect(result.newestId).toBeNull();
    expect(result.messages).toEqual([]);
  });
});
