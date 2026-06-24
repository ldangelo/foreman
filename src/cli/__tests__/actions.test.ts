import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { describe, expect, it } from "vitest";
import { listActions } from "../commands/actions.js";

describe("actions command helpers", () => {
  it("lists project overrides before bundled actions", () => {
    const project = mkdtempSync(join(tmpdir(), "foreman-actions-list-"));
    mkdirSync(join(project, ".foreman", "actions"), { recursive: true });
    writeFileSync(join(project, ".foreman", "actions", "create-pr.js"), "export default function run(ctx) { return ctx.internal.runBuiltin(); }\n");

    const rows = listActions(project);
    expect(rows.find((row) => row.action === "create-pr")).toMatchObject({ source: "project" });
    expect(rows.some((row) => row.action === "finalize")).toBe(true);
  });
});
