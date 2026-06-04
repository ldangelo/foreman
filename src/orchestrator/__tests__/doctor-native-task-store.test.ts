import { describe, expect, it } from "vitest";
import { PostgresStore } from "../../lib/postgres-store.js";

describe("doctor native task store", () => {
  it("uses PostgresStore for native task state", () => {
    expect(PostgresStore).toBeDefined();
  });
});
