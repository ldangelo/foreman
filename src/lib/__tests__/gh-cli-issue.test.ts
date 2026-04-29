/**
 * Unit tests for GhCli Issue extension (TRD-002, TRD-003, TRD-004, TRD-005).
 *
 * Tests Issue CRUD methods, error types (GhRateLimitError, GhNotFoundError),
 * and helpers.
 *
 * These tests verify the public API surface and error class hierarchy.
 * Full integration tests require a real `gh` binary and network access.
 */

import { describe, it, expect } from "vitest";
import {
  GhCli,
  GhNotInstalledError,
  GhNotAuthenticatedError,
  GhApiError,
  GhRateLimitError,
  GhNotFoundError,
  GhError,
  type GitHubIssue,
  type GitHubLabel,
  type GitHubMilestone,
  type GitHubUser,
  type ListIssuesOptions,
  type CreateIssueOptions,
  type UpdateIssueOptions,
} from "../gh-cli.js";

// ---------------------------------------------------------------------------
// Error class hierarchy (TRD-004)
// ---------------------------------------------------------------------------

describe("GhCli error class hierarchy", () => {
  it("GhRateLimitError is GhApiError subclass", () => {
    const err = new GhRateLimitError("rate limit", 3600);
    expect(err).toBeInstanceOf(GhApiError);
    expect(err).toBeInstanceOf(Error);
  });

  it("GhRateLimitError stores retryAfter", () => {
    const err = new GhRateLimitError("rate limit", 7200);
    expect(err.retryAfter).toBe(7200);
    expect(err.status).toBe(403);
    expect(err.message).toContain("rate limit");
  });

  it("GhNotFoundError is GhApiError subclass", () => {
    const err = new GhNotFoundError("/repos/owner/repo/issues/999");
    expect(err).toBeInstanceOf(GhApiError);
    expect(err).toBeInstanceOf(Error);
  });

  it("GhNotFoundError stores resourcePath and has 404 status", () => {
    const err = new GhNotFoundError("/repos/owner/repo/issues/142");
    expect((err as unknown as { resourcePath: string }).resourcePath).toBe(
      "/repos/owner/repo/issues/142",
    );
    expect(err.status).toBe(404);
    expect(err.message).toContain("not found");
  });

  it("GhApiError stores exitCode, status, and stderr", () => {
    const err = new GhApiError("msg", "stderr text", 1, 500);
    expect(err.exitCode).toBe(1);
    expect(err.status).toBe(500);
    expect(err.stderr).toBe("stderr text");
  });

  it("GhNotInstalledError and GhNotAuthenticatedError are GhError subclasses", () => {
    const notInstalled = new GhNotInstalledError();
    const notAuth = new GhNotAuthenticatedError("err", 1);
    expect(notInstalled).toBeInstanceOf(GhError);
    expect(notAuth).toBeInstanceOf(GhError);
  });
});

// ---------------------------------------------------------------------------
// API surface — all Issue extension methods exist (TRD-002, TRD-003)
// ---------------------------------------------------------------------------

describe("GhCli Issue extension API surface", () => {
  const gh = new GhCli();

  it("getIssue is a function", () => {
    expect(typeof gh.getIssue).toBe("function");
  });

  it("listIssues is a function", () => {
    expect(typeof gh.listIssues).toBe("function");
  });

  it("createIssue is a function", () => {
    expect(typeof gh.createIssue).toBe("function");
  });

  it("updateIssue is a function", () => {
    expect(typeof gh.updateIssue).toBe("function");
  });

  it("listLabels is a function", () => {
    expect(typeof gh.listLabels).toBe("function");
  });

  it("listMilestones is a function", () => {
    expect(typeof gh.listMilestones).toBe("function");
  });

  it("getUser is a function", () => {
    expect(typeof gh.getUser).toBe("function");
  });
});

// ---------------------------------------------------------------------------
// Exported types compile correctly (TRD-002, TRD-003)
// ---------------------------------------------------------------------------

describe("GhCli exported types", () => {
  it("GitHubIssue type is valid", () => {
    const _issue: GitHubIssue = {
      id: 1,
      number: 1,
      title: "t",
      body: null,
      state: "open",
      user: { login: "u", id: 1 },
      labels: [],
      assignees: [],
      milestone: null,
      created_at: "",
      updated_at: "",
      closed_at: null,
      url: "",
      html_url: "",
    };
    expect(_issue.title).toBe("t");
  });

  it("GitHubLabel type is valid", () => {
    const _label: GitHubLabel = {
      id: 1,
      name: "bug",
      color: "ff0000",
      description: "Bug report",
    };
    expect(_label.name).toBe("bug");
  });

  it("GitHubMilestone type is valid", () => {
    const _ms: GitHubMilestone = {
      id: 1,
      number: 1,
      title: "v1.0",
      state: "open",
      description: null,
      open_issues: 5,
      closed_issues: 3,
    };
    expect(_ms.title).toBe("v1.0");
  });

  it("GitHubUser type is valid", () => {
    const _user: GitHubUser = {
      login: "alice",
      id: 100,
      avatar_url: "https://avatars.githubusercontent.com/u/100",
      html_url: "https://github.com/alice",
    };
    expect(_user.login).toBe("alice");
  });

  it("ListIssuesOptions type is valid", () => {
    const opts: ListIssuesOptions = {
      labels: "bug",
      milestone: "v1.0",
      assignee: "alice",
      state: "open",
      since: "2026-01-01T00:00:00Z",
    };
    expect(opts.labels).toBe("bug");
  });

  it("CreateIssueOptions type is valid", () => {
    const opts: CreateIssueOptions = {
      title: "New issue",
      body: "Description",
      labels: ["bug", "priority:p1"],
      milestone: "v1.0",
      assignee: ["alice", "bob"],
    };
    expect(opts.labels).toHaveLength(2);
  });

  it("UpdateIssueOptions type is valid", () => {
    const opts: UpdateIssueOptions = {
      title: "Updated title",
      body: "Updated body",
      state: "closed",
      labels: ["bug"],
      milestone: "v2.0",
      assignees: ["alice"],
    };
    expect(opts.state).toBe("closed");
  });
});

// ---------------------------------------------------------------------------
// Default GhCli constructor works
// ---------------------------------------------------------------------------

describe("GhCli constructor", () => {
  it("creates instance with default gh path", () => {
    const gh = new GhCli();
    expect(gh).toBeDefined();
  });

  it("creates instance with custom gh path", () => {
    const gh = new GhCli({ ghPath: "/usr/local/bin/gh" });
    expect(gh).toBeDefined();
  });
});
