import { describe, expect, it } from "vitest";
import { doctorCommand } from "../commands/doctor.js";

describe("doctor command", () => {
  it("loads the production command", () => {
    expect(doctorCommand.name()).toBe("doctor");
    expect(doctorCommand.options.some((opt) => opt.long === "--fix")).toBe(true);
  });
});
