import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { createProjectMailClient, resolveProjectDatabaseUrl } from "../project-mail-client.js";

const { listRegisteredProjectsMock, initPoolMock, isPoolInitialisedMock } = vi.hoisted(() => ({
  listRegisteredProjectsMock: vi.fn(),
  initPoolMock: vi.fn(),
  isPoolInitialisedMock: vi.fn(),
}));

vi.mock("../../cli/commands/project-task-support.js", () => ({
  listRegisteredProjects: listRegisteredProjectsMock,
}));

vi.mock("../db/pool-manager.js", () => ({
  initPool: initPoolMock,
  isPoolInitialised: isPoolInitialisedMock,
}));

describe("project-mail-client", () => {
  const originalDatabaseUrl = process.env.DATABASE_URL;

  beforeEach(() => {
    delete process.env.DATABASE_URL;
    listRegisteredProjectsMock.mockReset();
    initPoolMock.mockReset();
    isPoolInitialisedMock.mockReset();
    isPoolInitialisedMock.mockReturnValue(false);
  });

  afterEach(() => {
    process.env.DATABASE_URL = originalDatabaseUrl;
  });

  it("reads DATABASE_URL from the project .env when ambient env is unset", () => {
    const projectPath = mkdtempSync(join(tmpdir(), "project-mail-client-dotenv-"));

    try {
      writeFileSync(projectPath + "/.env", 'DATABASE_URL="postgresql://user:pass@host/db"\n', "utf8");

      expect(resolveProjectDatabaseUrl(projectPath)).toBe("postgresql://user:pass@host/db");
    } finally {
      rmSync(projectPath, { recursive: true, force: true });
    }
  });

  it("prefers the project .env DATABASE_URL over ambient env when projectPath is known", () => {
    const projectPath = mkdtempSync(join(tmpdir(), "project-mail-client-prefer-dotenv-"));

    try {
      process.env.DATABASE_URL = "postgresql://ambient:ambient@host/ambient";
      writeFileSync(join(projectPath, ".env"), "DATABASE_URL=postgresql://repo:repo@host/repo\n", "utf8");

      expect(resolveProjectDatabaseUrl(projectPath)).toBe("postgresql://repo:repo@host/repo");
    } finally {
      rmSync(projectPath, { recursive: true, force: true });
    }
  });

  it("falls back to ambient DATABASE_URL when the project does not define one", () => {
    const projectPath = mkdtempSync(join(tmpdir(), "project-mail-client-fallback-ambient-"));

    try {
      process.env.DATABASE_URL = "postgresql://ambient:ambient@host/ambient";

      expect(resolveProjectDatabaseUrl(projectPath)).toBe("postgresql://ambient:ambient@host/ambient");
    } finally {
      rmSync(projectPath, { recursive: true, force: true });
    }
  });

  it("prefers PostgresMailClient when the project is registered and has a repo DATABASE_URL", async () => {
    const projectPath = mkdtempSync(join(tmpdir(), "project-mail-client-postgres-"));

    try {
      writeFileSync(join(projectPath, ".env"), "DATABASE_URL=postgresql://user:pass@host/db\n", "utf8");
      listRegisteredProjectsMock.mockResolvedValue([
        { id: "project-1", name: "test", path: projectPath },
      ]);

      const mailClient = await createProjectMailClient(projectPath);

      expect(mailClient.constructor.name).toBe("PostgresMailClient");
      expect(isPoolInitialisedMock).toHaveBeenCalledOnce();
      expect(initPoolMock).toHaveBeenCalledWith({ databaseUrl: "postgresql://user:pass@host/db" });
    } finally {
      rmSync(projectPath, { recursive: true, force: true });
    }
  });

  it("initializes Postgres with the project .env DATABASE_URL instead of ambient env", async () => {
    const projectPath = mkdtempSync(join(tmpdir(), "project-mail-client-init-prefer-dotenv-"));

    try {
      process.env.DATABASE_URL = "postgresql://ambient:ambient@host/ambient";
      writeFileSync(join(projectPath, ".env"), "DATABASE_URL=postgresql://repo:repo@host/repo\n", "utf8");
      listRegisteredProjectsMock.mockResolvedValue([
        { id: "project-1", name: "test", path: projectPath },
      ]);

      const mailClient = await createProjectMailClient(projectPath);

      expect(mailClient.constructor.name).toBe("PostgresMailClient");
      expect(initPoolMock).toHaveBeenCalledWith({ databaseUrl: "postgresql://repo:repo@host/repo" });
    } finally {
      rmSync(projectPath, { recursive: true, force: true });
    }
  });

  it("does not reinitialize the Postgres pool when it is already initialized", async () => {
    const projectPath = mkdtempSync(join(tmpdir(), "project-mail-client-existing-pool-"));

    try {
      writeFileSync(join(projectPath, ".env"), "DATABASE_URL=postgresql://user:pass@host/db\n", "utf8");
      listRegisteredProjectsMock.mockResolvedValue([
        { id: "project-1", name: "test", path: projectPath },
      ]);
      isPoolInitialisedMock.mockReturnValue(true);

      const mailClient = await createProjectMailClient(projectPath);

      expect(mailClient.constructor.name).toBe("PostgresMailClient");
      expect(initPoolMock).not.toHaveBeenCalled();
    } finally {
      rmSync(projectPath, { recursive: true, force: true });
    }
  });

  it("falls back to SqliteMailClient when the project is not registered", async () => {
    const projectPath = mkdtempSync(join(tmpdir(), "project-mail-client-sqlite-"));

    try {
      writeFileSync(join(projectPath, ".env"), "DATABASE_URL=postgresql://user:pass@host/db\n", "utf8");
      listRegisteredProjectsMock.mockResolvedValue([]);

      const mailClient = await createProjectMailClient(projectPath);

      expect(mailClient.constructor.name).toBe("SqliteMailClient");
      expect(initPoolMock).not.toHaveBeenCalled();
    } finally {
      rmSync(projectPath, { recursive: true, force: true });
    }
  });

  it("falls back to SqliteMailClient when no project DATABASE_URL is available", async () => {
    const projectPath = mkdtempSync(join(tmpdir(), "project-mail-client-no-db-"));

    try {
      listRegisteredProjectsMock.mockResolvedValue([
        { id: "project-1", name: "test", path: projectPath },
      ]);

      const mailClient = await createProjectMailClient(projectPath);

      expect(mailClient.constructor.name).toBe("SqliteMailClient");
      expect(initPoolMock).not.toHaveBeenCalled();
    } finally {
      rmSync(projectPath, { recursive: true, force: true });
    }
  });

  it("throws when Postgres initialization fails for a Postgres-eligible project", async () => {
    const projectPath = mkdtempSync(join(tmpdir(), "project-mail-client-init-fails-"));

    try {
      writeFileSync(join(projectPath, ".env"), "DATABASE_URL=postgresql://user:pass@host/db\n", "utf8");
      listRegisteredProjectsMock.mockResolvedValue([
        { id: "project-1", name: "test", path: projectPath },
      ]);
      initPoolMock.mockImplementation(() => {
        throw new Error("pool init failed");
      });

      await expect(createProjectMailClient(projectPath)).rejects.toThrow("pool init failed");
    } finally {
      rmSync(projectPath, { recursive: true, force: true });
    }
  });
});
