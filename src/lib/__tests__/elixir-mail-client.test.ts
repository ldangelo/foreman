import { describe, expect, it, vi } from "vitest";

import { ElixirMailClient } from "../elixir-mail-client.js";

function makeClient() {
  return {
    sendCommand: vi.fn().mockResolvedValue({ ok: true, events: [], projection_version: 1, correlation_id: "c1" }),
    listInbox: vi.fn().mockResolvedValue([
      {
        message_id: "m1",
        from: "qa",
        to: "foreman",
        subject: "handoff",
        body: "done",
        created_at: "2026-07-03T00:00:00.000Z",
        unread: true,
      },
      {
        message_id: "m2",
        from: "foreman",
        to: "qa",
        subject: "nudge",
        body: "continue",
        created_at: "2026-07-03T00:01:00.000Z",
        unread: false,
      },
    ]),
  };
}

describe("ElixirMailClient", () => {
  it("sends agent mail through the Elixir inbox command boundary", async () => {
    const client = makeClient();
    const mail = new ElixirMailClient(client as never);
    mail.setRunId("run-1");
    await mail.ensureAgentRegistered("qa");

    await mail.sendMessage("finalize", "handoff", "QA PASS");

    expect(client.sendCommand).toHaveBeenCalledWith(expect.objectContaining({
      command_type: "inbox.send",
      payload: expect.objectContaining({
        run_id: "run-1",
        from: "qa",
        to: "finalize",
        subject: "handoff",
        body: "QA PASS",
      }),
    }));
  });

  it("reads only messages addressed to the requested agent", async () => {
    const client = makeClient();
    const mail = new ElixirMailClient(client as never);
    mail.setRunId("run-1");

    const inbox = await mail.fetchInbox("qa", { limit: 10 });

    expect(client.listInbox).toHaveBeenCalledWith({ runId: "run-1", limit: 10 });
    expect(inbox).toEqual([
      {
        id: "m2",
        from: "foreman",
        to: "qa",
        subject: "nudge",
        body: "continue",
        receivedAt: "2026-07-03T00:01:00.000Z",
        acknowledged: true,
      },
    ]);
  });
});
