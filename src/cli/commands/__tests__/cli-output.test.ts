import { afterEach, describe, expect, it, vi } from "vitest";
import chalk from "chalk";
import { InvalidArgumentError } from "commander";
import {
  parseNonNegativeIntOption,
  printDeprecationNotice,
  printDryRunNotice,
  printPurgeSummary,
} from "../cli-output.js";

describe("parseNonNegativeIntOption", () => {
  const parse = parseNonNegativeIntOption("--days");

  it("parses valid non-negative integers", () => {
    expect(parse("0")).toBe(0);
    expect(parse("7")).toBe(7);
    expect(parse(" 42 ")).toBe(42);
  });

  it.each(["1.5", "7abc", "-1", "abc", "", "0x10", "1e3"])(
    "rejects %j with a clear error",
    (value) => {
      expect(() => parse(value)).toThrow("--days must be a non-negative integer");
    },
  );

  it("throws commander's InvalidArgumentError so the CLI prints a friendly message", () => {
    expect(() => parse("1.5")).toThrow(InvalidArgumentError);
  });

  it("includes the flag name it was built with in the error message", () => {
    expect(() => parseNonNegativeIntOption("--log-days")("7abc")).toThrow(
      "--log-days must be a non-negative integer",
    );
  });
});

describe("printDeprecationNotice", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("prints a single yellow one-line notice to stderr", () => {
    const err = vi.spyOn(console, "error").mockImplementation(() => {});
    printDeprecationNotice("foreman purge-logs", "foreman purge logs");
    expect(err).toHaveBeenCalledTimes(1);
    expect(err).toHaveBeenCalledWith(
      chalk.yellow("'foreman purge-logs' is deprecated — use 'foreman purge logs' instead."),
    );
  });
});

describe("printDryRunNotice", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("prints the standard notice when dryRun is true", () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    printDryRunNotice(true);
    expect(log).toHaveBeenCalledTimes(1);
    expect(log).toHaveBeenCalledWith(
      chalk.yellow("(dry run — no changes will be made)\n"),
    );
  });

  it("prints nothing when dryRun is false", () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    printDryRunNotice(false);
    expect(log).not.toHaveBeenCalled();
  });

  it("prints nothing when dryRun is undefined", () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    printDryRunNotice(undefined);
    expect(log).not.toHaveBeenCalled();
  });
});

describe("printPurgeSummary", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("prints the purge-logs style dry-run summary with detail and hint", () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    printPurgeSummary({
      dryRun: true,
      subject: "log group(s)",
      verb: "deleted",
      count: 3,
      skipped: 1,
      errors: 0,
      detail: "2.0 MB",
      dryRunHint: "Run without --dry-run to apply changes.",
      warnOnErrors: true,
    });

    expect(log).toHaveBeenNthCalledWith(1);
    expect(log).toHaveBeenNthCalledWith(
      2,
      chalk.yellow(
        "Dry run complete — 3 log group(s) would be deleted (2.0 MB), 1 skipped, 0 error(s).",
      ),
    );
    expect(log).toHaveBeenNthCalledWith(
      3,
      chalk.dim("Run without --dry-run to apply changes."),
    );
  });

  it("prints the purge-logs style done summary in yellow when errors occurred", () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    printPurgeSummary({
      dryRun: false,
      subject: "log group(s)",
      verb: "deleted",
      count: 2,
      skipped: 0,
      errors: 1,
      detail: "512 B",
      warnOnErrors: true,
    });

    expect(log).toHaveBeenNthCalledWith(1);
    expect(log).toHaveBeenNthCalledWith(
      2,
      chalk.yellow("Done — 2 log group(s) deleted (512 B), 0 skipped, 1 error(s)."),
    );
    expect(log).toHaveBeenCalledTimes(2);
  });

  it("prints the done summary in green when no errors occurred", () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    printPurgeSummary({
      dryRun: false,
      subject: "log group(s)",
      verb: "deleted",
      count: 2,
      skipped: 0,
      errors: 0,
      detail: "512 B",
      warnOnErrors: true,
    });

    expect(log).toHaveBeenNthCalledWith(
      2,
      chalk.green("Done — 2 log group(s) deleted (512 B), 0 skipped, 0 error(s)."),
    );
  });

  it("prints the purge-zombie-runs style dry-run summary (no detail, no hint)", () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    printPurgeSummary({
      dryRun: true,
      subject: "zombie run(s)",
      verb: "purged",
      count: 4,
      skipped: 2,
      errors: 1,
    });

    expect(log).toHaveBeenNthCalledWith(1);
    expect(log).toHaveBeenNthCalledWith(
      2,
      chalk.yellow(
        "Dry run complete — 4 zombie run(s) would be purged, 2 skipped, 1 error(s).",
      ),
    );
    expect(log).toHaveBeenCalledTimes(2);
  });

  it("prints the purge-zombie-runs style done summary in green even with errors", () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    printPurgeSummary({
      dryRun: false,
      subject: "zombie run(s)",
      verb: "purged",
      count: 4,
      skipped: 2,
      errors: 1,
    });

    expect(log).toHaveBeenNthCalledWith(
      2,
      chalk.green("Done — 4 zombie run(s) purged, 2 skipped, 1 error(s)."),
    );
  });
});
