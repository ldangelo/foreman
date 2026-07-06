/**
 * In-memory Jira debounce store.
 *
 * Legacy Postgres debounce persistence was removed with the CLI PG purge. This
 * preserves process-local behavior until Elixir exposes Jira state APIs.
 */

export interface IssueState {
  issue_key: string;
  last_known_status: string | null;
  last_triggered_at: string | null;
}

export interface DebounceCheckResult {
  isDebounced: boolean;
  lastTriggeredAt: Date | null;
}

export interface JiraIssueStateRow {
  id?: number;
  jira_project_id: string;
  issue_key: string;
  last_known_status: string | null;
  last_triggered_at: Date | string | null;
  last_updated_at?: Date | string | null;
}

const states = new Map<string, JiraIssueStateRow>();

function key(jiraProjectId: string, issueKey: string): string {
  return `${jiraProjectId}:${issueKey}`;
}

export async function isDebounced(jiraProjectId: string, issueKey: string, debounceWindowSeconds: number): Promise<boolean> {
  const state = states.get(key(jiraProjectId, issueKey));
  if (!state?.last_triggered_at) return false;
  const last = new Date(state.last_triggered_at).getTime();
  return Date.now() - last < debounceWindowSeconds * 1000;
}

export async function getDebounceStatus(jiraProjectId: string, issueKey: string): Promise<DebounceCheckResult> {
  const state = states.get(key(jiraProjectId, issueKey));
  const last = state?.last_triggered_at ? new Date(state.last_triggered_at) : null;
  return { isDebounced: Boolean(last), lastTriggeredAt: last };
}

export async function setDebounced(jiraProjectId: string, issueKey: string, status: string): Promise<void> {
  states.set(key(jiraProjectId, issueKey), {
    jira_project_id: jiraProjectId,
    issue_key: issueKey,
    last_known_status: status,
    last_triggered_at: new Date(),
    last_updated_at: new Date(),
  });
}

export async function updateStatus(jiraProjectId: string, issueKey: string, status: string): Promise<void> {
  const existing = states.get(key(jiraProjectId, issueKey));
  states.set(key(jiraProjectId, issueKey), {
    jira_project_id: jiraProjectId,
    issue_key: issueKey,
    last_known_status: status,
    last_triggered_at: existing?.last_triggered_at ?? null,
    last_updated_at: new Date(),
  });
}

export async function getLastKnownStatus(jiraProjectId: string, issueKey: string): Promise<string | null> {
  return states.get(key(jiraProjectId, issueKey))?.last_known_status ?? null;
}

export async function clearDebounce(jiraProjectId: string, issueKey?: string): Promise<number> {
  let count = 0;
  for (const stateKey of [...states.keys()]) {
    if (stateKey.startsWith(`${jiraProjectId}:`) && (!issueKey || stateKey === key(jiraProjectId, issueKey))) {
      states.delete(stateKey);
      count += 1;
    }
  }
  return count;
}

export async function getIssueStates(jiraProjectId: string): Promise<IssueState[]> {
  return [...states.values()]
    .filter((row) => row.jira_project_id === jiraProjectId)
    .map((row) => ({
      issue_key: row.issue_key,
      last_known_status: row.last_known_status,
      last_triggered_at: row.last_triggered_at ? new Date(row.last_triggered_at).toISOString() : null,
    }));
}
