/**
 * Jira tRPC procedures — configure, test, and monitor Jira integrations.
 *
 * Procedures:
 * - jira.configure: Save Jira config for a project
 * - jira.getStatus: Get Jira monitor status
 * - jira.testConnection: Test Jira API connectivity
 * - jira.enableWebhook: Enable webhook for real-time triggers
 * - jira.disableWebhook: Disable webhook
 */

import { z } from "zod";
import type { Context } from "./router.js";

// Jira project row type (also exported from postgres-adapter)
export interface JiraProjectRow {
  id: string;
  project_id: string;
  api_url: string;
  email: string;
  poll_interval_seconds: number | null;
  webhook_enabled: boolean;
  last_poll_at: string | null;
}

// Jira procedure input/output types
export interface JiraConfigureInput {
  projectId?: string;
  apiUrl: string;
  email: string;
  apiTokenEnvVar: string;
  projects: Array<{
    key: string;
    startStatus: string[];
    endStatus?: string[];
    issueTypeWorkflowMap: Record<string, string>;
    debounceWindowSeconds?: number;
  }>;
  webhookEnabled?: boolean;
  webhookSecretEnvVar?: string;
  pollIntervalSeconds?: number;
}

export interface JiraStatusOutput {
  configured: boolean;
  projects: number;
  lastPoll?: string;
  webhookEnabled: boolean;
  // Observability metrics (TRD-028)
  monitoredIssues: number;
  triggeredToday: number;
  lastError?: string;
}

export interface JiraTestConnectionInput {
  apiUrl: string;
  email: string;
  apiTokenEnvVar: string;
}

export interface JiraTestConnectionOutput {
  connected: boolean;
  projects?: Array<{ key: string; name: string }>;
  error?: string;
}

export interface JiraEnableWebhookInput {
  projectId?: string;
  webhookSecret: string;
}

export interface JiraWebhookOutput {
  webhookUrl: string;
}

export interface JiraDisableWebhookInput {
  projectId?: string;
}