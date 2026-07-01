import { describe, expect, it, vi, afterEach } from "vitest";

describe("foreman reset removed after Elixir cutover", () => {
  afterEach(() => vi.restoreAllMocks());

  it("fails with removal guidance instead of using local run-store reset", async () => {
    const exitSpy = vi.spyOn(process, "exit").mockImplementation(((code?: number) => {
      throw new Error(`process.exit(${code ?? ""})`);
    }) as never);
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const { resetCommand } = await import("../commands/reset.js");

    await expect(resetCommand.parseAsync(["--dry-run"], { from: "user" })).rejects.toThrow("process.exit(1)");

    expect(exitSpy).toHaveBeenCalledWith(1);
    const rendered = errSpy.mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("removed after the Elixir backend cutover");
    expect(rendered).not.toContain("FOREMAN_BACKEND=node");
  });
});
