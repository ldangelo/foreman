import type { AgentMailClient } from "./agent-mail-client.js";
import { NullAgentMailClient } from "./agent-mail-client.js";
import { foremanBackendMode } from "./backend-mode.js";
import { ElixirMailClient } from "./elixir-mail-client.js";

export async function createProjectMailClient(projectPath: string): Promise<AgentMailClient> {
  if (foremanBackendMode() === "elixir") {
    return new ElixirMailClient();
  }

  const mailClient = new NullAgentMailClient();
  await mailClient.ensureProject(projectPath);
  return mailClient;
}
