import { describe, expect, it } from "vitest";

describe("orchestrator doctor module", () => {
  it("loads without requiring local sqlite state", async () => {
    const mod = await import("../doctor.js");
    expect(mod).toBeDefined();
  });
});
