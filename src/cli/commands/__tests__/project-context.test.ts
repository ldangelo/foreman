import { beforeEach, describe, expect, it, vi } from "vitest";

const listRegisteredProjects = vi.fn();
const resolveRepoRootProjectPath = vi.fn();
const ensureCliPostgresPool = vi.fn();

vi.mock("../project-task-support.js", () => ({
  listRegisteredProjects: (...args: unknown[]) => listRegisteredProjects(...args),
  resolveRepoRootProjectPath: (...args: unknown[]) => resolveRepoRootProjectPath(...args),
  ensureCliPostgresPool: (...args: unknown[]) => ensureCliPostgresPool(...args),
}));

import {
  findRegisteredProjectByFlagOrCwd,
  findRegisteredProjectByPath,
  resolveProjectContext,
} from "../project-context.js";

const PROJECTS = [
  { id: "id-alpha", name: "alpha", path: "/projects/alpha" },
  { id: "id-beta", name: "beta", path: "/projects/beta/" },
];

beforeEach(() => {
  vi.clearAllMocks();
  listRegisteredProjects.mockResolvedValue(PROJECTS);
  resolveRepoRootProjectPath.mockResolvedValue("/projects/alpha");
});

describe("findRegisteredProjectByPath", () => {
  it("matches a registered project by exact path and initialises the pool", async () => {
    const registered = await findRegisteredProjectByPath("/projects/alpha");
    expect(registered).toEqual(PROJECTS[0]);
    expect(ensureCliPostgresPool).toHaveBeenCalledWith("/projects/alpha");
  });

  it("does not match trailing-slash variants without normalizePaths", async () => {
    const registered = await findRegisteredProjectByPath("/projects/beta");
    expect(registered).toBeUndefined();
    expect(ensureCliPostgresPool).not.toHaveBeenCalled();
  });

  it("matches normalized paths when normalizePaths is set (retry.ts behavior)", async () => {
    const registered = await findRegisteredProjectByPath("/projects/beta", {
      normalizePaths: true,
    });
    expect(registered).toEqual(PROJECTS[1]);
    expect(ensureCliPostgresPool).toHaveBeenCalledWith("/projects/beta");
  });

  it("skips pool initialisation when initPool is false", async () => {
    const registered = await findRegisteredProjectByPath("/projects/alpha", {
      initPool: false,
    });
    expect(registered).toEqual(PROJECTS[0]);
    expect(ensureCliPostgresPool).not.toHaveBeenCalled();
  });

  it("returns undefined when no project matches", async () => {
    const registered = await findRegisteredProjectByPath("/elsewhere");
    expect(registered).toBeUndefined();
    expect(ensureCliPostgresPool).not.toHaveBeenCalled();
  });
});

describe("resolveProjectContext", () => {
  it("resolves the repo-root path and matches the registered project by path", async () => {
    const context = await resolveProjectContext();
    expect(resolveRepoRootProjectPath).toHaveBeenCalledWith({});
    expect(context).toEqual({
      projectPath: "/projects/alpha",
      registered: PROJECTS[0],
    });
    expect(ensureCliPostgresPool).toHaveBeenCalledWith("/projects/alpha");
  });

  it("forwards project/projectPath options to the path resolver", async () => {
    const opts = { project: "alpha", projectPath: undefined };
    await resolveProjectContext(opts);
    expect(resolveRepoRootProjectPath).toHaveBeenCalledWith(opts);
  });

  it("returns registered undefined when the resolved path is unregistered", async () => {
    resolveRepoRootProjectPath.mockResolvedValue("/elsewhere");
    const context = await resolveProjectContext();
    expect(context).toEqual({ projectPath: "/elsewhere", registered: undefined });
    expect(ensureCliPostgresPool).not.toHaveBeenCalled();
  });

  it("matches by id when matchProjectFlagByIdOrName is set and --project is given (reset.ts behavior)", async () => {
    resolveRepoRootProjectPath.mockResolvedValue("/projects/beta/");
    const context = await resolveProjectContext(
      { project: "id-beta" },
      { matchProjectFlagByIdOrName: true },
    );
    expect(context.registered).toEqual(PROJECTS[1]);
    expect(ensureCliPostgresPool).toHaveBeenCalledWith("/projects/beta/");
  });

  it("matches by name when matchProjectFlagByIdOrName is set and --project is given", async () => {
    const context = await resolveProjectContext(
      { project: "beta" },
      { matchProjectFlagByIdOrName: true },
    );
    expect(context.registered).toEqual(PROJECTS[1]);
  });

  it("falls back to path matching when matchProjectFlagByIdOrName is set but --project is absent", async () => {
    const context = await resolveProjectContext({}, { matchProjectFlagByIdOrName: true });
    expect(context.registered).toEqual(PROJECTS[0]);
  });

  it("skips pool initialisation when initPool is false", async () => {
    await resolveProjectContext(
      { project: "alpha" },
      { matchProjectFlagByIdOrName: true, initPool: false },
    );
    expect(ensureCliPostgresPool).not.toHaveBeenCalled();
  });
});

describe("findRegisteredProjectByFlagOrCwd", () => {
  it("matches by id when a flag is given", async () => {
    const registered = await findRegisteredProjectByFlagOrCwd("id-alpha");
    expect(registered).toEqual(PROJECTS[0]);
    expect(resolveRepoRootProjectPath).not.toHaveBeenCalled();
  });

  it("matches by name when a flag is given", async () => {
    const registered = await findRegisteredProjectByFlagOrCwd("beta");
    expect(registered).toEqual(PROJECTS[1]);
  });

  it("returns null without resolving a path when the flag matches nothing (sentinel.ts behavior)", async () => {
    const registered = await findRegisteredProjectByFlagOrCwd("nope");
    expect(registered).toBeNull();
    expect(resolveRepoRootProjectPath).not.toHaveBeenCalled();
  });

  it("falls back to matching the repo-root path when no flag is given", async () => {
    const registered = await findRegisteredProjectByFlagOrCwd();
    expect(registered).toEqual(PROJECTS[0]);
    expect(resolveRepoRootProjectPath).toHaveBeenCalledWith({});
  });

  it("returns null when no flag is given and the path is unregistered", async () => {
    resolveRepoRootProjectPath.mockResolvedValue("/elsewhere");
    const registered = await findRegisteredProjectByFlagOrCwd();
    expect(registered).toBeNull();
  });

  it("never initialises the Postgres pool", async () => {
    await findRegisteredProjectByFlagOrCwd("alpha");
    await findRegisteredProjectByFlagOrCwd();
    expect(ensureCliPostgresPool).not.toHaveBeenCalled();
  });
});
