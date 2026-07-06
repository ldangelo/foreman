import { describe, expect, it } from "vitest";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";

const repoRoot = path.resolve(__dirname, "../../..");
const harnessPath = path.join(repoRoot, "docs/spikes/prototypes/trd-2026-014-prototypes.mjs");
const capturedResultsPath = path.join(repoRoot, "docs/spikes/prototypes/TRD-2026-014-prototype-results.json");

type PrototypeResult = {
  happy: {
    events: Array<{ type: string }>;
    rebuilt: { runStatus: string };
  };
  crash: {
    recoveryTimeline: string[];
    rebuilt: { runStatus: string };
  };
};

type SpikeResults = {
  status: string;
  lifecycle: string[];
  prototypes: Record<string, PrototypeResult>;
  decision: string;
};

describe("TRD-2026-014 architecture spike prototype harness", () => {
  it("executes the same lifecycle and recovery scenario for all compared runtimes", () => {
    const stdout = execFileSync(process.execPath, [harnessPath], {
      cwd: repoRoot,
      encoding: "utf8",
    });
    const generated = JSON.parse(stdout) as SpikeResults;
    const captured = JSON.parse(readFileSync(capturedResultsPath, "utf8")) as SpikeResults;

    expect(generated).toEqual(captured);
    expect(generated.status).toBe("pass");
    expect(generated.lifecycle).toEqual([
      "create_task",
      "approve_task",
      "dispatch_simulated_worker",
      "stream_status",
      "complete_run",
      "rebuild_read_model",
    ]);

    for (const runtime of ["elixir_otp", "wolverine_marten", "typescript_control"]) {
      const result = generated.prototypes[runtime];
      expect(result).toBeDefined();
      expect(result.happy.events.map((event) => event.type)).toEqual(
        expect.arrayContaining(["TaskCreated", "TaskApproved", "WorkerDispatched", "StatusStreamed", "RunCompleted"]),
      );
      expect(result.happy.rebuilt.runStatus).toBe("completed");
      expect(result.crash.rebuilt.runStatus).toBe("completed");
    }

    expect(generated.prototypes.elixir_otp.crash.recoveryTimeline.join(" ")).toMatch(
      /WorkerSupervisor.*RecoverySupervisor.*DynamicSupervisor/,
    );
    expect(generated.prototypes.wolverine_marten.crash.recoveryTimeline.join(" ")).toMatch(
      /durable message.*saga.*scheduled retry/i,
    );
    expect(generated.decision).toContain("Elixir/OTP remains selected");
  });
});
