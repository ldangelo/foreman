import { describe, expect, it } from "vitest";
import * as dispatcher from "../dispatcher.js";

describe("worker spawn module", () => {
  it("loads dispatcher worker-spawn production module", () => {
    expect(dispatcher).toBeDefined();
  });
});
