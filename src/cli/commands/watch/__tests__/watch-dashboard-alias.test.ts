/**
 * `foreman dashboard` is retired as a standalone command; `foreman watch` is
 * the canonical live dashboard. The old spelling keeps working as an alias of
 * watch, printing a one-line deprecation notice.
 */
import { describe, it, expect, vi, afterEach } from "vitest";
import { watchCommand, maybePrintDashboardAliasNotice } from "../index.js";

describe("watch — dashboard alias", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("registers 'dashboard' as an alias of the watch command", () => {
    expect(watchCommand.aliases()).toContain("dashboard");
  });

  it("prints a one-line yellow deprecation notice when invoked via the dashboard alias", () => {
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);

    maybePrintDashboardAliasNotice(["node", "foreman", "dashboard", "--no-watch"]);

    expect(errSpy).toHaveBeenCalledTimes(1);
    const message = String(errSpy.mock.calls[0][0]);
    expect(message).toContain("deprecated");
    expect(message).toContain("foreman watch");
    // one-line notice
    expect(message).not.toContain("\n");
  });

  it("prints nothing when invoked as 'foreman watch'", () => {
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);

    maybePrintDashboardAliasNotice(["node", "foreman", "watch", "--no-watch"]);

    expect(errSpy).not.toHaveBeenCalled();
  });

  it("prints nothing when 'dashboard' appears only as an option value", () => {
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);

    maybePrintDashboardAliasNotice(["node", "foreman", "watch", "--project", "dashboard"]);

    expect(errSpy).not.toHaveBeenCalled();
  });

  it("still prints the notice when the dashboard alias is followed by options", () => {
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);

    maybePrintDashboardAliasNotice(["node", "foreman", "dashboard", "--project", "myproj"]);

    expect(errSpy).toHaveBeenCalledTimes(1);
  });
});
