import { describe, expect, it } from "vitest";
import { ProjectNotFoundError } from "../project-registry.js";
import {
  LEGACY_PROJECT_PATH_WARNING,
  ProjectTargetingError,
  resolveProjectTarget,
} from "../project-targeting.js";

function createRegistry(entries: Record<string, string>) {
  return {
    resolve(nameOrPath: string): string {
      if (nameOrPath in entries) {
        return entries[nameOrPath]!;
      }
      throw new ProjectNotFoundError(nameOrPath);
    },
  };
}

describe("resolveProjectTarget", () => {
  it("returns cwd when no project targeting flags are supplied", () => {
    const result = resolveProjectTarget(
      {},
      {
        cwd: "/tmp/current-project",
        isAccessible: () => true,
      },
    );

    expect(result).toEqual({
      projectPath: "/tmp/current-project",
      source: "cwd",
    });
  });

  it("resolves registered project names through the registry", () => {
    const result = resolveProjectTarget(
      { project: "demo" },
      {
        registry: createRegistry({ demo: "/tmp/registered-project" }),
        isAccessible: () => true,
      },
    );

    expect(result).toEqual({
      projectPath: "/tmp/registered-project",
      source: "project-name",
    });
  });

  it("accepts explicit --project-path absolute paths", () => {
    const result = resolveProjectTarget(
      { projectPath: "/tmp/direct-project" },
      { isAccessible: () => true },
    );

    expect(result).toEqual({
      projectPath: "/tmp/direct-project",
      source: "project-path",
    });
  });

  it("warns but preserves compatibility for legacy absolute --project paths", () => {
    const result = resolveProjectTarget(
      { project: "/tmp/legacy-project" },
      { isAccessible: () => true },
    );

    expect(result).toEqual({
      projectPath: "/tmp/legacy-project",
      source: "legacy-project-path",
      warning: LEGACY_PROJECT_PATH_WARNING,
    });
  });

  it("rejects using --project and --project-path together", () => {
    expect(() => resolveProjectTarget(
      { project: "demo", projectPath: "/tmp/direct-project" },
      { isAccessible: () => true },
    )).toThrowError(
      new ProjectTargetingError(
        "project-and-project-path-conflict",
        "Specify either `--project <name>` or `--project-path <absolute-path>`, not both.",
      ),
    );
  });

  it("rejects relative --project-path values", () => {
    expect(() => resolveProjectTarget(
      { projectPath: "./relative-project" },
      { isAccessible: () => true },
    )).toThrowError(
      new ProjectTargetingError(
        "project-path-must-be-absolute",
        "`--project-path` must be an absolute path.",
      ),
    );
  });

  it("rejects unknown project names", () => {
    expect(() => resolveProjectTarget(
      { project: "missing-project" },
      {
        registry: createRegistry({}),
        isAccessible: () => true,
      },
    )).toThrowError(
      new ProjectTargetingError(
        "project-name-not-found",
        "Project 'missing-project' not found. Run 'foreman project list' to see registered projects.",
      ),
    );
  });

  it("rejects inaccessible explicit paths", () => {
    expect(() => resolveProjectTarget(
      { projectPath: "/tmp/missing-project" },
      { isAccessible: () => false },
    )).toThrowError(
      new ProjectTargetingError(
        "project-path-not-accessible",
        "Project path '/tmp/missing-project' does not exist or is not accessible.",
      ),
    );
  });

  it("rejects registered names that resolve to inaccessible paths", () => {
    expect(() => resolveProjectTarget(
      { project: "demo" },
      {
        registry: createRegistry({ demo: "/tmp/missing-registered-project" }),
        isAccessible: () => false,
      },
    )).toThrowError(
      new ProjectTargetingError(
        "project-path-not-accessible",
        "Registered project 'demo' points to '/tmp/missing-registered-project', but that path does not exist or is not accessible.",
      ),
    );
  });
});
