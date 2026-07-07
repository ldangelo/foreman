import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";

function doc(path: string): string {
  return readFileSync(path, "utf8");
}

describe("TRD-2026-014 operator docs", () => {
  it("documents Elixir server, Node CLI, and Node/Pi worker responsibilities", () => {
    const docs = [
      doc("README.md"),
      doc("docs/user-guide.md"),
      doc("docs/cli-reference.md"),
      doc("docs/guides/elixir-backend-architecture.md"),
    ];

    for (const content of docs) {
      expect(content).toMatch(/Node CLI/i);
      expect(content).toMatch(/Elixir server|Elixir\/OTP server/i);
      expect(content).toMatch(/Node\/Pi worker|Node\/Pi workers/i);
    }
  });

  it("documents deprecated command replacements and warning surface", () => {
    const combined = [
      doc("docs/cli-reference.md"),
      doc("docs/guides/elixir-backend-architecture.md"),
      doc("docs/troubleshooting.md"),
    ].join("\n");

    expect(combined).toContain("foreman dashboard");
    expect(combined).toContain("foreman watch");
    expect(combined).toContain("foreman task");
    expect(combined).toContain("foreman task create --title");
    expect(combined).toContain("foreman purge-logs");
    expect(combined).toContain("foreman purge logs");
    expect(combined).toContain("--skip-explore");
    expect(combined).toContain("--workflow quick");
    expect(combined).toContain("Legacy TypeScript delegation was removed");
  });

  it("documents event, projection, and recovery troubleshooting concepts with examples", () => {
    const combined = [
      doc("docs/user-guide.md"),
      doc("docs/troubleshooting.md"),
      doc("docs/guides/elixir-backend-architecture.md"),
    ].join("\n");

    expect(combined).toContain("foreman server doctor");
    expect(combined).toMatch(/Events?.*durable|durable event/i);
    expect(combined).toMatch(/projection lag|Projections? are rebuildable/i);
    expect(combined).toContain("ExternalWorkerObserved");
    expect(combined).toContain("WorkerReattached");
    expect(combined).toContain("WorkerRestarted");
    expect(combined).toContain("NeedsOperator");
  });
});
