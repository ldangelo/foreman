import { describe, expect, it } from "vitest";
import { doctorCommand } from "../commands/doctor.js";

describe("doctor native mode", () => {
  it("loads doctor command for registered Postgres/native checks", () => {
    expect(doctorCommand.name()).toBe("doctor");
  });
});
