import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");

describe("pi-sdk-runner maxTurns guard", () => {
  it("exposes maxTurns and aborts the SDK session when the limit is reached", () => {
    const source = readFileSync(
      join(PROJECT_ROOT, "src", "orchestrator", "pi-sdk-runner.ts"),
      "utf-8",
    );

    expect(source).toContain("maxTurns?: number;");
    expect(source).toContain("Phase exceeded maxTurns");
    expect(source).toContain("void session.abort()");
    expect(source).toContain("requestMaxTurnAbort();");
  });
});
