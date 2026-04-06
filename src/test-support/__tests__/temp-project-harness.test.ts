import { existsSync } from "node:fs";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { createTempProjectHarness, type TempProjectHarness } from "../temp-project-harness.js";

let harness: TempProjectHarness | null = null;

afterEach(() => {
  harness?.cleanup();
  harness = null;
});

describe("createTempProjectHarness", () => {
  it("creates a registered git project with bundled smoke assets", () => {
    harness = createTempProjectHarness({
      projectName: "fixture-project",
      initialFiles: {
        "README.md": "# fixture\n",
        "src/index.ts": "export const value = 1;\n",
      },
    });

    expect(existsSync(join(harness.projectRoot, ".git"))).toBe(true);
    expect(existsSync(join(harness.projectRoot, ".foreman", "prompts", "smoke", "developer.md"))).toBe(true);
    expect(existsSync(join(harness.projectRoot, ".foreman", "workflows", "smoke.yaml"))).toBe(true);
    expect(harness.project.name).toBe("fixture-project");
    expect(harness.store.getProjectByPath(harness.projectRoot)?.id).toBe(harness.project.id);
    expect(harness.git(["rev-parse", "--abbrev-ref", "HEAD"])).toBe("main");
    expect(harness.git(["show", "HEAD:README.md"])).toContain("# fixture");
  });

  it("seeds native task fixtures with dependency edges and statuses", () => {
    harness = createTempProjectHarness();

    const seeded = harness.seedNativeTasks([
      { key: "create", title: "Create test.txt", status: "ready", priority: 1 },
      { key: "append", title: "Append test.txt", dependsOn: ["create"] },
    ]);

    expect(seeded.byKey.create.status).toBe("ready");
    expect(seeded.byKey.append.status).toBe("blocked");
    expect(harness.taskStore.getDependencies(seeded.byKey.append.id, "outgoing")).toEqual([
      expect.objectContaining({
        from_task_id: seeded.byKey.append.id,
        to_task_id: seeded.byKey.create.id,
        type: "blocks",
      }),
    ]);
  });

  it("can invoke the real CLI from the temp project root", async () => {
    harness = createTempProjectHarness();
    harness.seedNativeTasks([
      { title: "CLI-visible task", status: "ready" },
    ]);

    const result = await harness.runCli(["task", "list"]);

    expect(result.exitCode).toBe(0);
    expect(result.stdout).toContain("CLI-visible task");
    expect(result.stdout).toContain("ready");
  });
});
