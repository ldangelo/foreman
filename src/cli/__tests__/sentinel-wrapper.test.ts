import { describe, expect, it } from "vitest";

import { createRegisteredSentinelStore } from "../commands/sentinel.js";

describe("createRegisteredSentinelStore", () => {
  it("fails explicitly until sentinel backend endpoints exist", async () => {
    const store = createRegisteredSentinelStore("proj-1");

    await expect(store.getSentinelConfig("proj-1")).rejects.toThrow(
      "Sentinel configuration and run history are not exposed by the Elixir backend yet.",
    );
  });
});
