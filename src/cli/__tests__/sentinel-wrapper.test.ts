import { describe, expect, it } from "vitest";

import { createRegisteredSentinelStore } from "../commands/sentinel.js";

describe("createRegisteredSentinelStore", () => {
  it("creates an Elixir-backed sentinel store shim", async () => {
    const store = createRegisteredSentinelStore({ id: "proj-1", name: "proj", path: "/repo" });

    expect(store.isOpen()).toBe(true);
    await expect(store.getSentinelConfig("proj-1")).resolves.toBeNull();
    store.close();
  });
});
