import { describe, expect, it } from "vitest";
import { inboxCommand, selectRecentMessages } from "../commands/inbox.js";
import type { Message } from "../../lib/store.js";

describe("inbox command", () => {
  it("loads the production command", () => {
    expect(inboxCommand.name()).toBe("inbox");
  });

  it("keeps the most recent messages when applying a limit", () => {
    const messages = Array.from({ length: 5 }, (_, index) => ({
      id: String(index),
      run_id: "run-1",
      sender_agent_type: "sender",
      recipient_agent_type: "receiver",
      subject: "subject",
      body: "{}",
      read: 0,
      created_at: `2026-01-01T00:00:0${index}.000Z`,
      deleted_at: null,
    })) as Message[];

    expect(selectRecentMessages(messages, 2).map((message) => message.id)).toEqual(["3", "4"]);
  });
});
