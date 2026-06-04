import { describe, expect, it } from "vitest";
import * as ops from "../task-backend-ops.js";

describe("task backend ops module", () => {
  it("loads production task backend helpers", () => {
    expect(ops).toBeDefined();
  });
});
