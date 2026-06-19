import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import * as projectTaskSupport from "../commands/project-task-support.js";
import * as trpcClientModule from "../../lib/trpc-client.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";
import { debugCommand } from "../commands/debug.js";

describe("foreman debug", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-debug-test-"));
    mkdirSync(join(tmpDir, ".foreman"), { recursive: true });
    process.chdir(tmpDir);
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
    vi.restoreAllMocks();
  });

  it("uses daemon-backed runs and mail in raw mode", async () => {
    vi.spyOn(VcsBackendFactory, "create").mockResolvedValue({
      getRepoRoot: vi.fn().mockResolvedValue(tmpDir),
    } as unknown as Awaited<ReturnType<typeof VcsBackendFactory.create>>);

    vi.spyOn(projectTaskSupport, "listRegisteredProjects").mockResolvedValue([
      { id: "proj-1", name: "foreman", path: tmpDir },
    ]);

    vi.spyOn(trpcClientModule, "createTrpcClient").mockReturnValue({
      runs: {
        list: vi.fn().mockResolvedValue([
          {
            id: "run-12345678",
            project_id: "proj-1",
            bead_id: "foreman-a01cf",
            status: "running",
            branch: "foreman/foreman-a01cf",
            queued_at: "2026-04-25T00:00:00.000Z",
            started_at: "2026-04-25T00:01:00.000Z",
            finished_at: null,
            created_at: "2026-04-25T00:00:00.000Z",
          },
        ]),
      },
      mail: {
        list: vi.fn().mockResolvedValue([
          {
            id: "msg-1",
            run_id: "run-12345678",
            sender_agent_type: "foreman",
            recipient_agent_type: "developer",
            subject: "bead-claimed",
            body: '{"seedId":"foreman-a01cf"}',
            read: 0,
            created_at: "2026-04-25T00:02:00.000Z",
            deleted_at: null,
          },
        ]),
      },
    } as unknown as trpcClientModule.TrpcClient);

    const logs: string[] = [];
    const errors: string[] = [];
    vi.spyOn(console, "log").mockImplementation((value?: unknown) => {
      logs.push(String(value ?? ""));
    });
    vi.spyOn(console, "error").mockImplementation((value?: unknown) => {
      errors.push(String(value ?? ""));
    });

    await debugCommand.parseAsync(["foreman-a01cf", "--raw"], { from: "user" });

    const output = logs.join("\n");
    expect(errors.join("\n")).not.toContain("No runs found");
    expect(output).toContain("Analyzing foreman-a01cf");
    expect(output).toContain("run-12345");
    expect(output).toContain("bead-claimed");
  });
});
