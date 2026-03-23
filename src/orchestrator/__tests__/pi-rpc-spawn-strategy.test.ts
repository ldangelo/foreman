/**
 * Tests for isPiAvailable(), PI_PHASE_CONFIGS, and parsePiEvent().
 *
 * Strategy:
 * - Mock execFileSync to control Pi availability detection.
 * - Verify parsePiEvent handles well-formed and malformed input.
 */

import { describe, it, expect, vi, beforeEach } from "vitest";

// ── Mocks set up BEFORE importing the module under test ──────────────────

vi.mock("node:child_process", async (importOriginal) => {
  const original = await importOriginal<typeof import("node:child_process")>();
  return {
    ...original,
    execFileSync: vi.fn(),
  };
});

import { execFileSync } from "node:child_process";
import {
  isPiAvailable,
  parsePiEvent,
  PI_PHASE_CONFIGS,
} from "../pi-rpc-spawn-strategy.js";

// ── Tests ────────────────────────────────────────────────────────────────

describe("isPiAvailable()", () => {
  const execFileSyncMock = execFileSync as ReturnType<typeof vi.fn>;

  beforeEach(() => {
    execFileSyncMock.mockReset();
  });

  it("returns false when both `which pi` and the fallback path fail", () => {
    execFileSyncMock.mockImplementation(() => {
      throw new Error("not found");
    });
    expect(isPiAvailable()).toBe(false);
  });

  it("returns true when `which pi` succeeds", () => {
    execFileSyncMock.mockImplementationOnce(() => "/usr/local/bin/pi");
    expect(isPiAvailable()).toBe(true);
  });

  it("returns true when `which pi` fails but the fallback Homebrew path exists", () => {
    // First call (which pi) fails, second call (pi --version) succeeds
    execFileSyncMock
      .mockImplementationOnce(() => { throw new Error("not found"); })
      .mockImplementationOnce(() => "pi 0.60.0");
    expect(isPiAvailable()).toBe(true);
  });

  it("never throws — returns false on unexpected errors", () => {
    execFileSyncMock.mockImplementation(() => {
      throw new TypeError("unexpected");
    });
    expect(() => isPiAvailable()).not.toThrow();
    expect(isPiAvailable()).toBe(false);
  });
});

describe("PI_PHASE_CONFIGS", () => {
  it("defines configs for all four pipeline phases", () => {
    expect(PI_PHASE_CONFIGS).toHaveProperty("explorer");
    expect(PI_PHASE_CONFIGS).toHaveProperty("developer");
    expect(PI_PHASE_CONFIGS).toHaveProperty("qa");
    expect(PI_PHASE_CONFIGS).toHaveProperty("reviewer");
  });

  it("does not have hardcoded models — models come from workflow config", () => {
    expect(PI_PHASE_CONFIGS.explorer).not.toHaveProperty("model");
    expect(PI_PHASE_CONFIGS.developer).not.toHaveProperty("model");
    expect(PI_PHASE_CONFIGS.qa).not.toHaveProperty("model");
    expect(PI_PHASE_CONFIGS.reviewer).not.toHaveProperty("model");
  });

  it("has correct maxTurns for each phase", () => {
    expect(PI_PHASE_CONFIGS.explorer.maxTurns).toBe(30);
    expect(PI_PHASE_CONFIGS.developer.maxTurns).toBe(80);
    expect(PI_PHASE_CONFIGS.qa.maxTurns).toBe(30);
    expect(PI_PHASE_CONFIGS.reviewer.maxTurns).toBe(20);
  });

  it("has correct maxTokens for each phase", () => {
    expect(PI_PHASE_CONFIGS.explorer.maxTokens).toBe(100_000);
    expect(PI_PHASE_CONFIGS.developer.maxTokens).toBe(500_000);
    expect(PI_PHASE_CONFIGS.qa.maxTokens).toBe(200_000);
    expect(PI_PHASE_CONFIGS.reviewer.maxTokens).toBe(150_000);
  });

  it("includes only read-only tools for explorer", () => {
    const tools = PI_PHASE_CONFIGS.explorer.allowedTools;
    expect(tools).toContain("Read");
    expect(tools).toContain("Grep");
    expect(tools).not.toContain("Write");
    expect(tools).not.toContain("Edit");
    expect(tools).not.toContain("Bash");
  });

  it("includes write tools for developer", () => {
    const tools = PI_PHASE_CONFIGS.developer.allowedTools;
    expect(tools).toContain("Write");
    expect(tools).toContain("Edit");
    expect(tools).toContain("Bash");
  });
});


describe("parsePiEvent()", () => {
  it("parses agent_start event", () => {
    const event = parsePiEvent('{"type":"agent_start"}');
    expect(event).toEqual({ type: "agent_start" });
  });

  it("parses turn_end event with usage", () => {
    const line = '{"type":"turn_end","turn":3,"usage":{"input_tokens":100,"output_tokens":50}}';
    const event = parsePiEvent(line);
    expect(event).not.toBeNull();
    expect(event?.type).toBe("turn_end");
  });

  it("parses agent_end success event", () => {
    const event = parsePiEvent('{"type":"agent_end","success":true,"message":"Done"}');
    expect(event).not.toBeNull();
    expect(event?.type).toBe("agent_end");
  });

  it("parses error event", () => {
    const event = parsePiEvent('{"type":"error","message":"something went wrong"}');
    expect(event).not.toBeNull();
    expect(event?.type).toBe("error");
  });

  it("returns null for empty string", () => {
    expect(parsePiEvent("")).toBeNull();
  });

  it("returns null for whitespace-only string", () => {
    expect(parsePiEvent("   \n")).toBeNull();
  });

  it("returns null for invalid JSON", () => {
    expect(parsePiEvent("{not valid json")).toBeNull();
  });

  it("returns null when type field is missing", () => {
    expect(parsePiEvent('{"message":"no type here"}')).toBeNull();
  });

  it("returns null when type field is not a string", () => {
    expect(parsePiEvent('{"type":42}')).toBeNull();
  });

  it("handles extension_ui_request budget_exceeded event", () => {
    const line = '{"type":"extension_ui_request","subtype":"budget_exceeded","phase":"developer","limit":"500000"}';
    const event = parsePiEvent(line);
    expect(event).not.toBeNull();
    expect(event?.type).toBe("extension_ui_request");
  });
});
