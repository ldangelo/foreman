import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

import { listRegisteredProjects } from "../cli/commands/project-task-support.js";
import { initPool, isPoolInitialised } from "./db/pool-manager.js";
import type { AgentMailClient } from "./sqlite-mail-client.js";
import { PostgresMailClient } from "./postgres-mail-client.js";
import { SqliteMailClient } from "./sqlite-mail-client.js";

export function resolveProjectDatabaseUrl(projectPath?: string): string | undefined {
  if (!projectPath) {
    return process.env.DATABASE_URL;
  }

  const dotEnvPath = join(projectPath, ".env");
  if (existsSync(dotEnvPath)) {
    const databaseUrl = readFileSync(dotEnvPath, "utf8")
      .match(/^\s*DATABASE_URL=(.+)\s*$/m)?.[1]
      ?.trim()
      .replace(/^['"]|['"]$/g, "");

    if (databaseUrl) {
      return databaseUrl;
    }
  }

  return process.env.DATABASE_URL;
}

export async function createProjectMailClient(projectPath: string): Promise<AgentMailClient> {
  const databaseUrl = resolveProjectDatabaseUrl(projectPath);

  if (databaseUrl) {
    const projects = await listRegisteredProjects();
    const project = projects.find((record) => record.path === projectPath);
    if (project) {
      if (!isPoolInitialised()) {
        initPool({ databaseUrl });
      }

      const mailClient = new PostgresMailClient();
      await mailClient.ensureProject(projectPath);
      return mailClient;
    }
  }

  const mailClient = new SqliteMailClient();
  await mailClient.ensureProject(projectPath);
  return mailClient;
}
