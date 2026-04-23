import { describe, it, expect } from "vitest";
import {
  GhCli,
  GhNotInstalledError,
  GhNotAuthenticatedError,
  GhError,
} from "../gh-cli.js";

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

describe("GhCli error classes", () => {
  it("GhNotInstalledError has correct message", () => {
    const err = new GhNotInstalledError();
    expect(err.message).toContain("not installed");
    expect(err).toBeInstanceOf(GhError);
  });

  it("GhNotAuthenticatedError has exitCode property", () => {
    const err = new GhNotAuthenticatedError("Not authenticated", 4);
    expect(err.exitCode).toBe(4);
    expect(err).toBeInstanceOf(GhError);
  });

  it("GhError is the base class for all GhCli errors", () => {
    const notInstalled = new GhNotInstalledError();
    const notAuth = new GhNotAuthenticatedError("err", 1);
    expect(notInstalled).toBeInstanceOf(GhError);
    expect(notAuth).toBeInstanceOf(GhError);
  });
});

describe("GhCli methods exist", () => {
  const gh = new GhCli();

  it("has isInstalled method", () => {
    expect(typeof gh.isInstalled).toBe("function");
  });

  it("has checkAuth method", () => {
    expect(typeof gh.checkAuth).toBe("function");
  });

  it("has authStatus method", () => {
    expect(typeof gh.authStatus).toBe("function");
  });

  it("has repoClone method", () => {
    expect(typeof gh.repoClone).toBe("function");
  });

  it("has api method", () => {
    expect(typeof gh.api).toBe("function");
  });

  it("has getRepoMetadata method", () => {
    expect(typeof gh.getRepoMetadata).toBe("function");
  });
});

// NOTE: Full integration tests for GhCli require a working gh binary and are
// covered in E2E tests. Unit tests here verify the public API surface,
// constructor behavior, and error class hierarchy.
