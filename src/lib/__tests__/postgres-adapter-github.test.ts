/**
 * Unit tests for PostgresAdapter GitHub repo CRUD (TRD-008).
 *
 * Tests: upsertGithubRepo, getGithubRepo, listGithubRepos, deleteGithubRepo.
 */

import { describe, it, expect } from "vitest";
import type {
  GithubRepoRow,
  GithubSyncEventRow,
} from "../../lib/db/postgres-adapter.js";

// ---------------------------------------------------------------------------
// Type shape validation (TRD-008)
// ---------------------------------------------------------------------------

describe("PostgresAdapter GitHub types", () => {
  it("GithubRepoRow type is exported and valid", () => {
    const row: GithubRepoRow = {
      id: "550e8400-e29b-41d4-a716-446655440000",
      project_id: "550e8400-e29b-41d4-a716-446655440001",
      owner: "myorg",
      repo: "myrepo",
      auth_type: "pat",
      auth_config: {},
      default_labels: ["bug", "foreman:dispatch"],
      auto_import: false,
      webhook_secret: null,
      webhook_enabled: false,
      sync_strategy: "github-wins",
      last_sync_at: null,
      created_at: "2026-01-01T00:00:00Z",
      updated_at: "2026-01-01T00:00:00Z",
    };
    expect(row.owner).toBe("myorg");
    expect(row.auth_type).toBe("pat");
    expect(row.sync_strategy).toBe("github-wins");
  });

  it("GithubSyncEventRow type is exported and valid", () => {
    const row: GithubSyncEventRow = {
      id: "550e8400-e29b-41d4-a716-446655440002",
      project_id: "550e8400-e29b-41d4-a716-446655440001",
      external_id: "github:myorg/myrepo#142",
      event_type: "issue_opened",
      direction: "from_github",
      github_payload: { number: 142, title: "Bug" },
      foreman_changes: null,
      conflict_detected: false,
      resolved_with: null,
      processed_at: "2026-01-01T00:00:00Z",
    };
    expect(row.external_id).toBe("github:myorg/myrepo#142");
    expect(row.event_type).toBe("issue_opened");
    expect(row.direction).toBe("from_github");
  });

  it("auth_config can hold app auth config", () => {
    const row: GithubRepoRow = {
      id: "550e8400-e29b-41d4-a716-446655440000",
      project_id: "550e8400-e29b-41d4-a716-446655440001",
      owner: "myorg",
      repo: "myrepo",
      auth_type: "app",
      auth_config: {
        app_id: 12345,
        installation_id: 67890,
      },
      default_labels: [],
      auto_import: true,
      webhook_secret: null,
      webhook_enabled: false,
      sync_strategy: "foreman-wins",
      last_sync_at: null,
      created_at: "2026-01-01T00:00:00Z",
      updated_at: "2026-01-01T00:00:00Z",
    };
    expect(row.auth_type).toBe("app");
    expect((row.auth_config as { app_id: number }).app_id).toBe(12345);
  });
});

// ---------------------------------------------------------------------------
// PostgresAdapter GitHub methods exist (API surface)
// ---------------------------------------------------------------------------

import { PostgresAdapter } from "../../lib/db/postgres-adapter.js";

describe("PostgresAdapter GitHub CRUD methods exist", () => {
  const adapter = new PostgresAdapter();

  it("upsertGithubRepo is a function", () => {
    expect(typeof adapter.upsertGithubRepo).toBe("function");
  });

  it("getGithubRepo is a function", () => {
    expect(typeof adapter.getGithubRepo).toBe("function");
  });

  it("listGithubRepos is a function", () => {
    expect(typeof adapter.listGithubRepos).toBe("function");
  });

  it("deleteGithubRepo is a function", () => {
    expect(typeof adapter.deleteGithubRepo).toBe("function");
  });

  it("recordGithubSyncEvent is a function", () => {
    expect(typeof adapter.recordGithubSyncEvent).toBe("function");
  });

  it("listGithubSyncEvents is a function", () => {
    expect(typeof adapter.listGithubSyncEvents).toBe("function");
  });
});
