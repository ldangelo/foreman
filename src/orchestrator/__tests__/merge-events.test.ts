import { describe, it, expect, beforeEach, afterEach } from "vitest";
import Database from "better-sqlite3";
import { ForemanStore } from "../../lib/store.js";
import type { EventType } from "../../lib/store.js";
import { MQ_ERRORS, type MQErrorCode, logMergeEvent } from "../merge-error-codes.js";

// ── MQ-T044: Merge queue event types ───────────────────────────────────

describe("Merge queue EventType entries", () => {
  let store: ForemanStore;

  beforeEach(() => {
    store = new ForemanStore(":memory:");
  });

  afterEach(() => {
    store.close();
  });

  const mergeQueueEventTypes: EventType[] = [
    "merge-queue-enqueue",
    "merge-queue-dequeue",
    "merge-queue-resolve",
    "merge-queue-fallback",
  ];

  it.each(mergeQueueEventTypes)(
    "accepts '%s' as a valid EventType",
    (eventType) => {
      // Type-level check: this assignment must compile
      const et: EventType = eventType;
      expect(et).toBe(eventType);
    }
  );

  it("can log merge-queue-enqueue events to the store", () => {
    const project = store.registerProject("test", "/tmp/test-mq-events");
    store.logEvent(project.id, "merge-queue-enqueue", { branch: "feat-1" });
    const events = store.getEvents(project.id);
    expect(events).toHaveLength(1);
    expect(events[0].event_type).toBe("merge-queue-enqueue");
  });

  it("can log merge-queue-dequeue events to the store", () => {
    const project = store.registerProject("test", "/tmp/test-mq-dequeue");
    store.logEvent(project.id, "merge-queue-dequeue", { branch: "feat-2" });
    const events = store.getEvents(project.id);
    expect(events).toHaveLength(1);
    expect(events[0].event_type).toBe("merge-queue-dequeue");
  });

  it("can log merge-queue-resolve events to the store", () => {
    const project = store.registerProject("test", "/tmp/test-mq-resolve");
    store.logEvent(project.id, "merge-queue-resolve", { tier: 1 });
    const events = store.getEvents(project.id);
    expect(events).toHaveLength(1);
    expect(events[0].event_type).toBe("merge-queue-resolve");
  });

  it("can log merge-queue-fallback events to the store", () => {
    const project = store.registerProject("test", "/tmp/test-mq-fallback");
    store.logEvent(project.id, "merge-queue-fallback", { reason: "tier exhausted" });
    const events = store.getEvents(project.id);
    expect(events).toHaveLength(1);
    expect(events[0].event_type).toBe("merge-queue-fallback");
  });
});

// ── MQ-T045: Error codes module ────────────────────────────────────────

describe("MQ error codes", () => {
  it("has all expected error codes", () => {
    const expectedCodes: MQErrorCode[] = [
      "MQ-001", "MQ-002", "MQ-003", "MQ-004", "MQ-005",
      "MQ-007", "MQ-008", "MQ-009", "MQ-010",
      "MQ-012", "MQ-013", "MQ-014", "MQ-015", "MQ-016",
      "MQ-018", "MQ-019", "MQ-020",
    ];

    for (const code of expectedCodes) {
      expect(MQ_ERRORS[code]).toBeDefined();
      expect(typeof MQ_ERRORS[code]).toBe("string");
      expect(MQ_ERRORS[code].length).toBeGreaterThan(0);
    }
  });

  it("has exactly 17 error codes", () => {
    expect(Object.keys(MQ_ERRORS)).toHaveLength(17);
  });

  it("all error codes have non-empty string descriptions", () => {
    for (const [code, description] of Object.entries(MQ_ERRORS)) {
      expect(code).toMatch(/^MQ-\d{3}$/);
      expect(typeof description).toBe("string");
      expect(description.length).toBeGreaterThan(0);
    }
  });
});

// ── MQ-T045 continued: logMergeEvent helper ────────────────────────────

describe("logMergeEvent helper", () => {
  let store: ForemanStore;
  let projectId: string;

  beforeEach(() => {
    store = new ForemanStore(":memory:");
    const project = store.registerProject("test", "/tmp/test-log-merge");
    projectId = project.id;
  });

  afterEach(() => {
    store.close();
  });

  it("logs an event with error code details", () => {
    logMergeEvent(store, projectId, "merge-queue-fallback", {
      errorCode: "MQ-018",
      branch: "feat-xyz",
    });

    const events = store.getEvents(projectId);
    expect(events).toHaveLength(1);
    expect(events[0].event_type).toBe("merge-queue-fallback");

    const details = JSON.parse(events[0].details!);
    expect(details.errorCode).toBe("MQ-018");
    expect(details.errorMessage).toBe("All tiers exhausted, merge aborted");
    expect(details.branch).toBe("feat-xyz");
    expect(details.timestamp).toBeDefined();
  });

  it("logs an event without error code", () => {
    logMergeEvent(store, projectId, "merge-queue-enqueue", {
      branch: "feat-abc",
      seedId: "seed-1",
    });

    const events = store.getEvents(projectId);
    expect(events).toHaveLength(1);
    const details = JSON.parse(events[0].details!);
    expect(details.branch).toBe("feat-abc");
    expect(details.seedId).toBe("seed-1");
    expect(details.errorCode).toBeUndefined();
    expect(details.errorMessage).toBeUndefined();
    expect(details.timestamp).toBeDefined();
  });

  it("attaches a runId when provided in details", () => {
    const run = store.createRun(projectId, "seed-1", "worker");
    logMergeEvent(store, projectId, "merge-queue-resolve", {
      tier: 2,
    }, run.id);

    const events = store.getEvents(projectId);
    expect(events).toHaveLength(1);
    expect(events[0].run_id).toBe(run.id);
  });
});
