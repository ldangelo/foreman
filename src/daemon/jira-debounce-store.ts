/**
 * JiraDebounceStore — manages debounce state in PostgreSQL.
 * All debounce tracking uses the jira_issue_states table.
 * No JSON file is used — all state is persisted in the database.
 */

import type { Database } from "postgres";

/**
 * Check if an issue is currently debounced.
 * Uses jira_issue_states.last_triggered_at to determine if within debounce window.
 */
export async function isDebounced(
  db: Database,
  jiraProjectId: string,
  issueKey: string,
  debounceWindowSeconds: number,
): Promise<boolean> {
  if (debounceWindowSeconds === 0) {
    return false;
  }

  const result = await db`
    SELECT EXISTS (
      SELECT 1 FROM jira_issue_states
      WHERE jira_project_id = ${jiraProjectId}
        AND issue_key = ${issueKey}
        AND last_triggered_at IS NOT NULL
        AND (NOW() - last_triggered_at) < (${debounceWindowSeconds} || ' seconds')::INTERVAL
    ) AS is_debounced
  `;

  return result[0]?.is_debounced ?? false;
}

/**
 * Set debounce: updates last_triggered_at in jira_issue_states.
 * If the issue doesn't have a row yet, creates one.
 */
export async function setDebounced(
  db: Database,
  jiraProjectId: string,
  issueKey: string,
  status: string,
): Promise<void> {
  await db`
    INSERT INTO jira_issue_states (jira_project_id, issue_key, last_known_status, last_triggered_at, last_updated_at)
    VALUES (${jiraProjectId}, ${issueKey}, ${status}, NOW(), NOW())
    ON CONFLICT (jira_project_id, issue_key)
    DO UPDATE SET
      last_triggered_at = NOW(),
      last_known_status = EXCLUDED.last_known_status,
      last_updated_at = NOW()
  `;
}

/**
 * Update last known status without triggering debounce.
 * Used when polling detects a status change but we're not triggering a workflow.
 */
export async function updateStatus(
  db: Database,
  jiraProjectId: string,
  issueKey: string,
  status: string,
): Promise<void> {
  await db`
    INSERT INTO jira_issue_states (jira_project_id, issue_key, last_known_status, last_updated_at)
    VALUES (${jiraProjectId}, ${issueKey}, ${status}, NOW())
    ON CONFLICT (jira_project_id, issue_key)
    DO UPDATE SET
      last_known_status = EXCLUDED.last_known_status,
      last_updated_at = NOW()
  `;
}

/**
 * Get the last known status for an issue.
 * Returns null if the issue hasn't been tracked yet.
 */
export async function getLastKnownStatus(
  db: Database,
  jiraProjectId: string,
  issueKey: string,
): Promise<string | null> {
  const result = await db`
    SELECT last_known_status FROM jira_issue_states
    WHERE jira_project_id = ${jiraProjectId}
      AND issue_key = ${issueKey}
  `;

  return result[0]?.last_known_status ?? null;
}

/**
 * Check if transitioning to startStatus is a new transition.
 * Returns true if the issue was not previously in a startStatus.
 */
export async function isNewTransition(
  db: Database,
  jiraProjectId: string,
  issueKey: string,
  startStatus: string[],
): Promise<boolean> {
  const lastStatus = await getLastKnownStatus(db, jiraProjectId, issueKey);

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
 */
export async function cleanup(
  db: Database,
  debounceWindowSeconds: number,
): Promise<number> {
  if (debounceWindowSeconds === 0) {
    return 0;
  }

  const result = await db`
    UPDATE jira_issue_states
    SET last_triggered_at = NULL
    WHERE last_triggered_at IS NOT NULL
      AND (NOW() - last_triggered_at) >= (${debounceWindowSeconds} || ' seconds')::INTERVAL
    RETURNING id
  `;

  return result.length;
}

/**
 * Get all issue states for a Jira project.
 * Useful for loading state at startup.
 */
export async function getIssueStates(
  db: Database,
  jiraProjectId: string,
): Promise<Array<{ issueKey: string; lastKnownStatus: string; lastTriggeredAt: Date | null }>> {
  const result = await db`
    SELECT issue_key, last_known_status, last_triggered_at
    FROM jira_issue_states
    WHERE jira_project_id = ${jiraProjectId}
  `;

  return result.map((row) => ({
    issueKey: row.issue_key,
    lastKnownStatus: row.last_known_status,
    lastTriggeredAt: row.last_triggered_at,
  }));
}