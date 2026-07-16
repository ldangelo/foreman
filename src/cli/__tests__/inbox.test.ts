import { describe, expect, it } from "vitest";
import { inboxCommand, selectRecentMessages, formatLogTimestamp, colorForStream } from "../commands/inbox.js";
import type { Message } from "../../lib/store.js";

describe("structured log rendering", () => {
  describe("formatLogTimestamp", () => {
    it("formats ISO8601 timestamps correctly", () => {
      const result = formatLogTimestamp("2026-07-16T15:30:00.000Z");
      expect(result).toMatch(/^2026-07-16 15:30:00/);
    });

    it("handles unix timestamps in seconds", () => {
      const result = formatLogTimestamp("1752676200");
      expect(result).toMatch(/^20\d{2}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/);
    });

    it("handles unix timestamps in milliseconds", () => {
      const result = formatLogTimestamp("1752676200000");
      expect(result).toMatch(/^20\d{2}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/);
    });

    it("returns input on invalid format", () => {
      const result = formatLogTimestamp("not-a-date");
      expect(result).toBe("not-a-date");
    });
  });

  describe("colorForStream", () => {
    it("returns red colorizer for stderr", () => {
      const colorFn = colorForStream("stderr");
      const result = colorFn("test");
      expect(typeof result).toBe("string");
    });

    it("returns dim colorizer for stdout", () => {
      const colorFn = colorForStream("stdout");
      const result = colorFn("test");
      expect(typeof result).toBe("string");
    });

    it("returns cyan colorizer for tool", () => {
      const colorFn = colorForStream("tool");
      const result = colorFn("test");
      expect(typeof result).toBe("string");
    });

    it("returns green colorizer for assistant", () => {
      const colorFn = colorForStream("assistant");
      const result = colorFn("test");
      expect(typeof result).toBe("string");
    });

    it("returns identity function for unknown streams", () => {
      const colorFn = colorForStream("unknown");
      const result = colorFn("test");
      expect(result).toBe("test");
    });
  });
});

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
