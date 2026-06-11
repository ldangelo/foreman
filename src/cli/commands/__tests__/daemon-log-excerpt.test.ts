import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, describe, expect, it } from "vitest";

import { readDaemonLogExcerpt } from "../daemon.js";

describe("readDaemonLogExcerpt", () => {
  const tempDirs: string[] = [];

  afterEach(() => {
    for (const dir of tempDirs) rmSync(dir, { recursive: true, force: true });
    tempDirs.length = 0;
  });

  function tempFile(contents: string): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-daemon-log-"));
    tempDirs.push(dir);
    const path = join(dir, "daemon.err");
    writeFileSync(path, contents, "utf8");
    return path;
  }

  it("returns the last five daemon log lines", () => {
    const path = tempFile(["one", "two", "three", "four", "five", "six"].join("\n"));

    expect(readDaemonLogExcerpt(path)).toBe(["two", "three", "four", "five", "six"].join("\n"));
  });

  it("tails large daemon logs without reading the full file", () => {
    const largePrefix = "x".repeat(128 * 1024);
    const path = tempFile(`${largePrefix}\nlast-1\nlast-2\nlast-3\nlast-4\nlast-5\n`);

    expect(readDaemonLogExcerpt(path)).toBe(["last-1", "last-2", "last-3", "last-4", "last-5"].join("\n"));
  });
});
