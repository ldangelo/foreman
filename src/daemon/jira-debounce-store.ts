/**
 * JiraDebounceStore — manages debounce state in PostgreSQL.
 * All debounce tracking uses the jira_issue_states table.
 * No JSON file is used — all state is persisted in the database.
 */

import { PoolManager } from "../lib/db/pool-manager.js";

export interface IssueState {
  issueKey: string;
  lastKnownStatus: string;
  lastTriggeredAt: Date | null;
}

export interface DebounceCheckResult {
  isDebounced: boolean;
  lastTriggeredAt: Date | null;
}

interface JiraIssueStateRow {
  issue_key: string;
  last_known_status: string | null;
  last_triggered_at: Date | null;
}

/**
 * Check if an issue is currently debounced.
 * Uses jira_issue_states.last_triggered_at to determine if within debounce window.
 */
export async function isDebounced(
  jiraProjectId: string,
  issueKey: string,
  debounceWindowSeconds: number,
): Promise<boolean> {
  if (debounceWindowSeconds === 0) {
    return false;
  }

  const db = PoolManager.getPool();
  const result = await db.query<{ is_debounced: boolean }>(
    `SELECT EXISTS (
      SELECT 1 FROM jira_issue_states
      WHERE jira_project_id = $1
        AND issue_key = $2
        AND last_triggered_at IS NOT NULL
        AND (NOW() - last_triggered_at) < ($3 || ' seconds')::INTERVAL
    ) AS is_debounced`,
    [jiraProjectId, issueKey, debounceWindowSeconds],
  );

  return result.rows[0]?.is_debounced ?? false;
}

/**
 * Get debounce status for an issue, including the last triggered timestamp.
 */
export async function getDebounceStatus(
  jiraProjectId: string,
  issueKey: string,
): Promise<DebounceCheckResult> {
  const db = PoolManager.getPool();
  const result = await db.query<JiraIssueStateRow>(
    `SELECT last_triggered_at FROM jira_issue_states
     WHERE jira_project_id = $1 AND issue_key = $2`,
    [jiraProjectId, issueKey],
  );

  return {
    isDebounced: result.rows[0]?.last_triggered_at != null,
    lastTriggeredAt: result.rows[0]?.last_triggered_at ?? null,
  };
}

/**
 * Set debounce: updates last_triggered_at in jira_issue_states.
 * If the issue doesn't have a row yet, creates one.
 */
export async function setDebounced(
  jiraProjectId: string,
  issueKey: string,
  status: string,
): Promise<void> {
  const db = PoolManager.getPool();
  await db.query(
    `INSERT INTO jira_issue_states (jira_project_id, issue_key, last_known_status, last_triggered_at, last_updated_at)
     VALUES ($1, $2, $3, NOW(), NOW())
     ON CONFLICT (jira_project_id, issue_key)
     DO UPDATE SET
       last_triggered_at = NOW(),
       last_known_status = EXCLUDED.last_known_status,
       last_updated_at = NOW()`,
    [jiraProjectId, issueKey, status],
  );
}

/**
 * Update last known status without triggering debounce.
 * Used when polling detects a status change but we're not triggering a workflow.
 */
export async function updateStatus(
  jiraProjectId: string,
  issueKey: string,
  status: string,
): Promise<void> {
  const db = PoolManager.getPool();
  await db.query(
    `INSERT INTO jira_issue_states (jira_project_id, issue_key, last_known_status, last_updated_at)
     VALUES ($1, $2, $3, NOW())
     ON CONFLICT (jira_project_id, issue_key)
     DO UPDATE SET
       last_known_status = EXCLUDED.last_known_status,
       last_updated_at = NOW()`,
    [jiraProjectId, issueKey, status],
  );
}

/**
 * Get the last known status for an issue.
 * Returns null if the issue hasn't been tracked yet.
 */
export async function getLastKnownStatus(
  jiraProjectId: string,
  issueKey: string,
): Promise<string | null> {
  const db = PoolManager.getPool();
  const result = await db.query<{ last_known_status: string | null }>(
    `SELECT last_known_status FROM jira_issue_states
     WHERE jira_project_id = $1 AND issue_key = $2`,
    [jiraProjectId, issueKey],
  );

  return result.rows[0]?.last_known_status ?? null;
}

/**
 * Check if transitioning to startStatus is a new transition.
 * Returns true if the issue was not previously in a startStatus.
 */
export async function isNewTransition(
  jiraProjectId: string,
  issueKey: string,
  startStatus: readonly string[],
): Promise<boolean> {
  const lastStatus = await getLastKnownStatus(jiraProjectId, issueKey);

  // If no prior status, it's a new issue — not a transition
  if (lastStatus === null) {
    return false;
  }

  // If previously in startStatus, this is not a new transition
  if (startStatus.includes(lastStatus)) {
    return false;
  }

  return true;
}

/**
 * Cleanup expired debounce entries.
 * Removes last_triggered_at for entries older than the debounce window.
 * Returns the count of cleaned entries.
 */
export async function cleanup(debounceWindowSeconds: number): Promise<number> {
  if (debounceWindowSeconds === 0) {
    return 0;
  }

  const db = PoolManager.getPool();
  const result = await db.query<{ id: number }>(
    `UPDATE jira_issue_states
     SET last_triggered_at = NULL
     WHERE last_triggered_at IS NOT NULL
       AND (NOW() - last_triggered_at) >= ($1 || ' seconds')::INTERVAL
     RETURNING id`,
    [debounceWindowSeconds],
  );

  return result.rowCount ?? 0;
}

/**
 * Get all issue states for a Jira project.
 * Useful for loading state at startup.
 */
export async function getIssueStates(
  jiraProjectId: string,
): Promise<IssueState[]> {
  const db = PoolManager.getPool();
  const result = await db.query<JiraIssueStateRow>(
    `SELECT issue_key, last_known_status, last_triggered_at
     FROM jira_issue_states
     WHERE jira_project_id = $1`,
    [jiraProjectId],
  );

  return result.rows.map((row) => ({
    issueKey: row.issue_key,
    lastKnownStatus: row.last_known_status ?? "",
    lastTriggeredAt: row.last_triggered_at ?? null,
  }));
}