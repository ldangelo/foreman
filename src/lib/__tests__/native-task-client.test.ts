import { describe, expect, it } from "vitest";
import { NativeTaskClient } from "../native-task-client.js";

describe("NativeTaskClient", () => {
  it("loads production client", () => {
    expect(NativeTaskClient).toBeDefined();
  });
});
