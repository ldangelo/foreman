/**
 * JiraTriggerHandler — processes detected Jira status transitions and creates
 * Foreman tasks for workflow execution.
 *
 * This handler:
 * - Validates the transition (not debounced, not already triggered)
 * - Maps the Jira issue type to the appropriate Foreman workflow
 * - Creates a Foreman task with Jira metadata
 * - Dispatches the task for execution
 */

import type { PostgresAdapter } from "../lib/db/postgres-adapter.js";
import type { JiraProjectConfig } from "../lib/project-config.js";
import { getPool } from "../lib/db/pool-manager.js";
import type { JiraIssue } from "../daemon/jira-poller.js";
import { isDebounced, setDebounced } from "../daemon/jira-debounce-store.js";

// ── Context types ───────────────────────────────────────────────────────────────

/**
 * Context passed to the trigger handler when a transition is detected.
 */
export interface TriggerContext {
  issue: JiraIssue;
  projectConfig: JiraProjectConfig;
  jiraProjectId: string;
  source: "poll" | "webhook";
}

/**
 * Result of handling a trigger.
 */
export interface TriggerResult {
  /** Whether a workflow was triggered */
  triggered: boolean;
  /** Human-readable reason if no trigger occurred */
  reason?: string;
  /** Created task ID */
  taskId?: string;
  /** Workflow that was triggered */
  workflowName: string;
  /** External ID for the Jira issue */
  externalId: string;
}

// ── JiraTriggerHandler ─────────────────────────────────────────────────────────

export class JiraTriggerHandler {
  private readonly adapter: PostgresAdapter;
  private readonly jiraProjectId: string;
  private readonly defaultWorkflow: string;

  constructor(
    adapter: PostgresAdapter,
    jiraProjectId: string,
    defaultWorkflow = "default",
  ) {
    this.adapter = adapter;
    this.jiraProjectId = jiraProjectId;
    this.defaultWorkflow = defaultWorkflow;
  }

  /**
   * Process a detected Jira status transition.
   *
   * Steps:
   * 1. Generate external ID
   * 2. Check if already triggered (uniqueness)
   * 3. Check if debounced
   * 4. Map issue type to workflow
   * 5. Create task with Jira metadata
   */
  async handleTransition(context: TriggerContext): Promise<TriggerResult> {
    const { issue, projectConfig, jiraProjectId, source } = context;
    const externalId = `jira:${issue.key}`;
    const workflowName = this.mapWorkflow(issue, projectConfig);

    // Check uniqueness — skip if already triggered (REQ-012)
    if (await this.isAlreadyTriggered(externalId)) {
      return {
        triggered: false,
        reason: "already_triggered",
        workflowName,
        externalId,
      };
    }

    // Check debounce (REQ-006)
    const debounceSeconds = projectConfig.debounceWindowSeconds ?? 60;
    if (debounceSeconds > 0) {
      const db = getPool();
      const debounced = await isDebounced(db, jiraProjectId, issue.key, debounceSeconds);
      if (debounced) {
        return {
          triggered: false,
          reason: "debounced",
          workflowName,
          externalId,
        };
      }
    }

    // Create the task
    const taskId = await this.createTask(issue, projectConfig, externalId, workflowName);

    // Record trigger in debounce store
    if (debounceSeconds > 0) {
      const db = getPool();
      await setDebounced(db, jiraProjectId, issue.key, issue.fields.status.name);
    }

    console.log(
      `[JiraTriggerHandler] Triggered: ${issue.key} → ${workflowName} (task: ${taskId}, source: ${source})`,
    );

    return {
      triggered: true,
      taskId,
      workflowName,
      externalId,
    };
  }

  /**
   * Check if an external ID has already been triggered.
   *
   * Looks up existing tasks by external_id.
   */
  private async isAlreadyTriggered(externalId: string): Promise<boolean> {
    const projectId = this.resolveProjectId();
    const existing = await this.adapter.getTaskByExternalId(projectId, externalId);
    return existing !== null;
  }

  /**
   * Map a Jira issue to the appropriate Foreman workflow name.
   *
   * Uses the issueTypeWorkflowMap from the project config.
   * Falls back to the configured default or "default" workflow.
   */
  private mapWorkflow(issue: JiraIssue, projectConfig: JiraProjectConfig): string {
    const issueType = issue.fields.issuetype.name;
    const workflow = projectConfig.issueTypeWorkflowMap[issueType];

    if (workflow) {
      console.log(`[JiraTriggerHandler] Mapped ${issueType} → ${workflow}`);
      return workflow;
    }

    // Fall back to "default" mapping if configured
    const defaultWf = projectConfig.issueTypeWorkflowMap["default"];
    if (defaultWf) {
      return defaultWf;
    }

    return this.defaultWorkflow;
  }

  /**
   * Create a Foreman task for the Jira issue.
   *
   * The task title is the Jira issue summary.
   * The description includes Jira metadata and a link to the issue.
   * The external_id is set to "jira:<issueKey>" for uniqueness tracking.
   */
  private async createTask(
    issue: JiraIssue,
    projectConfig: JiraProjectConfig,
    externalId: string,
    workflowName: string,
  ): Promise<string> {
    const projectId = this.resolveProjectId();

    const jiraUrl = this.buildIssueUrl(issue);
    const title = issue.fields.summary;
    const description = [
      `# Jira Issue: ${issue.key}`,
      ``,
      `**Type:** ${issue.fields.issuetype.name}`,
      `**Status:** ${issue.fields.status.name}`,
      `**Project:** ${issue.fields.project.key}`,
      `**URL:** ${jiraUrl}`,
      ``,
      `## Summary`,
      ``,
      issue.fields.summary,
      ``,
      `*This task was automatically created from a Jira status transition to "${issue.fields.status.name}".*`,
    ].join("\n");

    const task = await this.adapter.createTask(projectId, {
      title,
      description,
      type: this.normalizeIssueType(issue.fields.issuetype.name),
      priority: 2,
      status: "ready",
      externalId,
      labels: [
        `jira-workflow:${workflowName}`,
        `jira-type:${issue.fields.issuetype.name.toLowerCase()}`,
      ],
    });

    return task.id;
  }

  /**
   * Build the Jira issue URL from the issue key.
   * Uses a convention-based URL since the project-level apiUrl isn't available here.
   */
  private buildIssueUrl(issue: JiraIssue): string {
    // Convention: Jira Cloud URLs follow /browse/<KEY> pattern
    // The actual base URL would come from JiraConfig, but we can't access it here
    // For now, use the standard Atlassian pattern with the issue key
    return `https://jira.atlassian.com/browse/${issue.key}`;
  }

  /**
   * Normalize Jira issue type to Foreman task type.
   */
  private normalizeIssueType(issueType: string): string {
    const mapping: Record<string, string> = {
      Epic: "epic",
      Story: "story",
      Task: "task",
      Bug: "bug",
      Subtask: "task",
      Improvement: "task",
    };
    return mapping[issueType] ?? "task";
  }

  /**
   * Resolve the current project ID from the environment.
   */
  private resolveProjectId(): string {
    const projectId = process.env.FOREMAN_PROJECT_ID;
    if (!projectId) {
      throw new Error("FOREMAN_PROJECT_ID environment variable is required for Jira trigger handling");
    }
    return projectId;
  }
}
