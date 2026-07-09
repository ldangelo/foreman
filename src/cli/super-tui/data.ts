import type { InboxTaskSummary } from "../commands/inbox.js";
import type { SuperTuiScope } from "./model.js";

export type SuperTuiLoadSummaries = () => Promise<InboxTaskSummary[]>;

export interface SuperTuiDataAdapter {
  projectLabel: string;
  loadSummaries: SuperTuiLoadSummaries;
  initialSummaries?: InboxTaskSummary[];
  scope?: SuperTuiScope;
}

export function createStaticSuperTuiDataAdapter(projectLabel: string, summaries: InboxTaskSummary[]): SuperTuiDataAdapter {
  return {
    projectLabel,
    initialSummaries: summaries,
    loadSummaries: () => Promise.resolve(summaries),
  };
}

export async function loadInitialSuperTuiSummaries(adapter: SuperTuiDataAdapter): Promise<InboxTaskSummary[]> {
  if (adapter.initialSummaries) return adapter.initialSummaries;
  return adapter.loadSummaries();
}

export async function refreshSuperTuiSummaries(adapter: SuperTuiDataAdapter): Promise<InboxTaskSummary[]> {
  return adapter.loadSummaries();
}
