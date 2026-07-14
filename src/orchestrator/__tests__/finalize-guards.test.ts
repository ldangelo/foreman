import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, describe, expect, it } from "vitest";
import { extractExplorerScopedPaths, finalizeValidationCommands, findFinalizeScopeViolations } from "../finalize-guards.js";

describe("finalize guards", () => {
  const tmpDirs: string[] = [];

  afterEach(() => {
    for (const dir of tmpDirs.splice(0)) rmSync(dir, { recursive: true, force: true });
  });

  it("extracts Explorer Edit First paths", () => {
    const paths = extractExplorerScopedPaths(`## Developer Handoff\n\n### Edit First\n1. **src/cli/commands/task.ts** — update status badge\n2. \`src/cli/watch-ui.ts\` — update card color\n\n### Boundaries\n- Do not touch backend\n`);

    expect([...paths]).toEqual(["src/cli/commands/task.ts", "src/cli/watch-ui.ts"]);
  });

  it("flags files outside Explorer scope unless developer report justifies them", () => {
    const worktreePath = join(tmpdir(), `foreman-finalize-guard-${process.pid}-${Date.now()}`);
    tmpDirs.push(worktreePath);
    const reportDir = ".foreman/reports/task-scope/run-scope";
    mkdirSync(join(worktreePath, reportDir), { recursive: true });
    writeFileSync(join(worktreePath, reportDir, "EXPLORER_REPORT.md"), `### Edit First\n- **src/cli/commands/task.ts**\n- **src/cli/watch-ui.ts**\n`, "utf8");
    writeFileSync(join(worktreePath, reportDir, "DEVELOPER_REPORT.md"), `## Decisions & Trade-offs\n- Changed src/generated/types.ts because the task command type requires the additional file.\n`, "utf8");

    const config = { worktreePath, reportDir };

    expect(findFinalizeScopeViolations(config, [
      "src/cli/commands/task.ts",
      "packages/foreman_server/lib/foreman_server/overwatch.ex",
      "src/generated/types.ts",
    ])).toEqual(["packages/foreman_server/lib/foreman_server/overwatch.ex"]);
  });

  it("selects domain validation for non-TypeScript changed files", () => {
    expect(finalizeValidationCommands([
      "packages/foreman_server/lib/foreman_server/overwatch.ex",
      "clients/cockpit/view.go",
      "src/defaults/prompts/default/developer.md",
    ])).toEqual([
      "cd packages/foreman_server && mix test",
      "cd clients/cockpit && go test ./...",
      "npx vitest run src/orchestrator/__tests__/workflow-loader.test.ts src/orchestrator/__tests__/workflow-remediation-routing.test.ts --reporter=dot",
    ]);
  });
});
