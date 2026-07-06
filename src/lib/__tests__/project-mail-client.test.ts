import { describe, expect, it, vi } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { createProjectMailClient } from "../project-mail-client.js";

const { mockForemanBackendMode } = vi.hoisted(() => ({
  mockForemanBackendMode: vi.fn(() => "elixir"),
}));

vi.mock("../backend-mode.js", () => ({
  foremanBackendMode: mockForemanBackendMode,
}));

describe("project-mail-client", () => {
  it("uses ElixirMailClient in the Elixir backend without requiring DATABASE_URL or registry lookup", async () => {
    const projectPath = mkdtempSync(join(tmpdir(), "project-mail-client-elixir-"));

    try {
      mockForemanBackendMode.mockReturnValue("elixir");

      const mailClient = await createProjectMailClient(projectPath);

      expect(mailClient.constructor.name).toBe("ElixirMailClient");
    } finally {
      rmSync(projectPath, { recursive: true, force: true });
    }
  });

  it("falls back to NullAgentMailClient only outside Elixir mode", async () => {
    const projectPath = mkdtempSync(join(tmpdir(), "project-mail-client-node-"));

    try {
      mockForemanBackendMode.mockReturnValue("node");

      const mailClient = await createProjectMailClient(projectPath);

      expect(mailClient.constructor.name).toBe("NullAgentMailClient");
    } finally {
      rmSync(projectPath, { recursive: true, force: true });
    }
  });
});
