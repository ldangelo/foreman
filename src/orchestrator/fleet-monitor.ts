import { ProjectRegistry, type ProjectEntry } from "../lib/project-registry.js";
import { ForemanStore, type SentinelConfigRow, type SentinelRunRow } from "../lib/store.js";

export interface FleetProjectHealth {
  project: ProjectEntry;
  validationConfig: SentinelConfigRow | null;
  latestValidation: SentinelRunRow | null;
  activeAgents: number;
  validationReady: boolean;
  healthSummary: string;
}

function summarizeHealth(
  config: SentinelConfigRow | null,
  latestValidation: SentinelRunRow | null,
  activeAgents: number,
): { validationReady: boolean; healthSummary: string } {
  if (!config) {
    return {
      validationReady: false,
      healthSummary: "No integration validation configured.",
    };
  }
  if (!latestValidation) {
    return {
      validationReady: false,
      healthSummary: `Validation configured for ${config.branch} but no runs recorded yet.`,
    };
  }
  if (latestValidation.status === "passed") {
    return {
      validationReady: true,
      healthSummary: `Integration branch ${config.branch} last passed validation${activeAgents > 0 ? ` with ${activeAgents} active agent(s)` : ""}.`,
    };
  }
  return {
    validationReady: false,
    healthSummary: `Integration branch ${config.branch} is not ready: latest validation ${latestValidation.status}.`,
  };
}

export function inspectProjectFleetHealth(project: ProjectEntry): FleetProjectHealth {
  const store = ForemanStore.forProject(project.path);
  try {
    const projectRow = store.getProjectByPath(project.path);
    const validationConfig = projectRow ? store.getSentinelConfig(projectRow.id) : null;
    const latestValidation = projectRow ? (store.getSentinelRuns(projectRow.id, 1)[0] ?? null) : null;
    const activeAgents = projectRow ? store.getActiveRuns(projectRow.id).length : 0;
    const derived = summarizeHealth(validationConfig, latestValidation, activeAgents);
    return {
      project,
      validationConfig,
      latestValidation,
      activeAgents,
      ...derived,
    };
  } finally {
    store.close();
  }
}

export function inspectFleetHealth(
  registry: Pick<ProjectRegistry, "list"> = new ProjectRegistry(),
): FleetProjectHealth[] {
  return registry.list().map((project) => inspectProjectFleetHealth(project));
}
