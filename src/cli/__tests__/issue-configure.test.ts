import { describe, expect, it, vi } from "vitest";
import {
  buildGithubRepoConfigInput,
  mergeGithubRepoConfigInput,
  REQUIRED_FOREMAN_GITHUB_LABELS,
  ensureRequiredGithubLabels,
} from "../commands/issue.js";

describe("issue configure label setup", () => {
  it("defines the required Foreman GitHub labels", () => {
    expect(REQUIRED_FOREMAN_GITHUB_LABELS.map((label) => label.name)).toEqual([
      "foreman",
      "foreman:dispatch",
      "foreman:skip",
      "foreman:priority:0",
      "foreman:priority:1",
      "foreman:priority:2",
      "foreman:priority:3",
      "foreman:priority:4",
    ]);
  });

  it("passes the required label set to GhCli.ensureLabels", async () => {
    const ensureLabels = vi.fn().mockResolvedValue({
      created: ["foreman"],
      updated: [],
      unchanged: REQUIRED_FOREMAN_GITHUB_LABELS.slice(1).map((label) => label.name),
    });

    const result = await ensureRequiredGithubLabels({ ensureLabels }, "ldangelo", "foreman");

    expect(ensureLabels).toHaveBeenCalledWith(
      "ldangelo",
      "foreman",
      REQUIRED_FOREMAN_GITHUB_LABELS,
    );
    expect(result.created).toEqual(["foreman"]);
  });

  it("preserves existing auth and webhook config when updating repo settings", () => {
    const input = buildGithubRepoConfigInput(
      "proj-1",
      "ldangelo",
      "foreman",
      { disableAutoImport: true },
      {
        id: "repo-1",
        project_id: "proj-1",
        owner: "ldangelo",
        repo: "foreman",
        auth_type: "app",
        auth_config: { installationId: 123 },
        default_labels: ["github:docs"],
        auto_import: true,
        webhook_secret: "secret-123",
        webhook_enabled: true,
        sync_strategy: "manual",
        last_sync_at: "2026-04-29T00:00:00.000Z",
        created_at: "2026-04-29T00:00:00.000Z",
        updated_at: "2026-04-29T00:00:00.000Z",
      },
    );

    expect(input).toMatchObject({
      id: "repo-1",
      authType: "app",
      authConfig: { installationId: 123 },
      webhookSecret: "secret-123",
      webhookEnabled: true,
      autoImport: false,
      syncStrategy: "manual",
      defaultLabels: ["github:docs"],
      lastSyncAt: "2026-04-29T00:00:00.000Z",
    });
  });

  it("merges webhook-only updates without clobbering other repo config", () => {
    const input = mergeGithubRepoConfigInput(
      "proj-1",
      "ldangelo",
      "foreman",
      {
        id: "repo-1",
        project_id: "proj-1",
        owner: "ldangelo",
        repo: "foreman",
        auth_type: "app",
        auth_config: { installationId: 123 },
        default_labels: ["github:docs"],
        auto_import: true,
        webhook_secret: "old-secret",
        webhook_enabled: true,
        sync_strategy: "manual",
        last_sync_at: "2026-04-29T00:00:00.000Z",
        created_at: "2026-04-29T00:00:00.000Z",
        updated_at: "2026-04-29T00:00:00.000Z",
      },
      {
        webhookSecret: null,
        webhookEnabled: false,
      },
    );

    expect(input).toMatchObject({
      id: "repo-1",
      authType: "app",
      authConfig: { installationId: 123 },
      defaultLabels: ["github:docs"],
      autoImport: true,
      webhookSecret: null,
      webhookEnabled: false,
      syncStrategy: "manual",
      lastSyncAt: "2026-04-29T00:00:00.000Z",
    });
  });
});
