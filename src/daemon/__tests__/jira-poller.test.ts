/**
 * Integration tests for JiraIssuesPoller + JiraTriggerHandler.
 *
 * Tests:
 * - Poll project with no transitions → no triggers
 * - Poll project with new transition → triggers workflow
 * - Already-in-progress on first poll → no trigger (AC-003-4)
 * - Subsequent poll with same status → no trigger (AC-003-2)
 * - Status moves from non-start → start → triggers (AC-003-1)
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import type { PostgresAdapter } from "../../lib/db/postgres-adapter.js";
import type { JiraProjectConfig, JiraConfig } from "../../lib/project-config.js";
import { JiraIssuesPoller } from "../jira-poller.js";
import { JiraTriggerHandler } from "../../orchestrator/jira-trigger-handler.js";

// Mock pool manager to avoid real DB connections in trigger handler
vi.mock("../../lib/db/pool-manager.js", () => ({
  getPool: vi.fn().mockReturnValue({}),
}));

// Mock debounce store functions
vi.mock("../../daemon/jira-debounce-store.js", () => ({
  isDebounced: vi.fn().mockResolvedValue(false),
  setDebounced: vi.fn().mockResolvedValue(undefined),
}));

// ── Mock helpers ───────────────────────────────────────────────────────────────

function createMockAdapter(): PostgresAdapter {
  return {
    getJiraIssueStates: vi.fn().mockResolvedValue([]),
    upsertJiraIssueState: vi.fn().mockResolvedValue(undefined),
    createTask: vi.fn().mockResolvedValue({ id: "TASK-001" }),
    getTaskByExternalId: vi.fn().mockResolvedValue(null),
    listJiraProjects: vi.fn().mockResolvedValue([]),
  } as unknown as PostgresAdapter;
}

function createMockJiraClient() {
  return {
    authenticate: vi.fn().mockResolvedValue(undefined),
    search: vi.fn().mockResolvedValue({ issues: [], total: 0 }),
    listProjects: vi.fn().mockResolvedValue([
      { key: "PROJ", name: "Test Project" },
    ]),
    handleRateLimit: vi.fn().mockResolvedValue(undefined),
  };
}

function createJiraProjectConfig(overrides: Partial<JiraProjectConfig> = {}): JiraProjectConfig {
  return {
    key: "PROJ",
    startStatus: ["In Progress", "To Do"],
    endStatus: ["Done", "Closed"],
    issueTypeWorkflowMap: {
      Epic: "epic",
      Task: "default",
      default: "default",
    },
    debounceWindowSeconds: 60,
    ...overrides,
  };
}

// ── JiraIssuesPoller tests ─────────────────────────────────────────────────────

describe("JiraIssuesPoller", () => {
  let adapter: PostgresAdapter;
  let mockClient: ReturnType<typeof createMockJiraClient>;
  let jiraConfig: JiraConfig;
  let onTransition: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    vi.clearAllMocks();
    adapter = createMockAdapter();
    mockClient = createMockJiraClient();
    onTransition = vi.fn();
    jiraConfig = {
      apiUrl: "https://test.atlassian.net",
      email: "test@example.com",
      apiTokenEnvVar: "JIRA_API_TOKEN",
      pollIntervalSeconds: 60,
      webhookEnabled: false,
      projects: [createJiraProjectConfig()],
    };
  });

  describe("pollProject", () => {
    it("returns zero transitions when no issues found", async () => {
      const poller = new JiraIssuesPoller(adapter, mockClient, jiraConfig, onTransition);
      const result = await poller.pollProject(createJiraProjectConfig());

      expect(result.issues).toBe(0);
      expect(result.transitions).toBe(0);
      expect(mockClient.search).toHaveBeenCalled();
    });

    it("skips trigger for issue already in startStatus on first poll (AC-003-4)", async () => {
      mockClient.search.mockResolvedValue({
        issues: [
          {
            key: "PROJ-1",
            fields: {
              summary: "Test Issue",
              status: { name: "In Progress" },
              issuetype: { name: "Task" },
              project: { key: "PROJ" },
              updated: "2026-06-01T12:00:00Z",
            },
          },
        ],
        total: 1,
      });

      const poller = new JiraIssuesPoller(adapter, mockClient, jiraConfig, onTransition);
      const result = await poller.pollProject(createJiraProjectConfig());

      expect(result.transitions).toBe(0);
      expect(onTransition).not.toHaveBeenCalled();
    });

    it("triggers when status moves from non-start to start (AC-003-1)", async () => {
      const config = createJiraProjectConfig();

      // First poll: issue is in "To Do"
      mockClient.search.mockResolvedValueOnce({
        issues: [
          {
            key: "PROJ-1",
            fields: {
              summary: "Test Issue",
              status: { name: "To Do" },
              issuetype: { name: "Task" },
              project: { key: "PROJ" },
              updated: "2026-06-01T11:00:00Z",
            },
          },
        ],
        total: 1,
      });

      const poller = new JiraIssuesPoller(adapter, mockClient, jiraConfig, onTransition);
      await poller.pollProject(config);

      // Second poll: issue moved to "In Progress"
      mockClient.search.mockResolvedValueOnce({
        issues: [
          {
            key: "PROJ-1",
            fields: {
              summary: "Test Issue",
              status: { name: "In Progress" },
              issuetype: { name: "Task" },
              project: { key: "PROJ" },
              updated: "2026-06-01T12:00:00Z",
            },
          },
        ],
        total: 1,
      });

      const result = await poller.pollProject(config);

      expect(result.transitions).toBe(1);
      expect(onTransition).toHaveBeenCalledTimes(1);
      const [issue, cfg] = onTransition.mock.calls[0]!;
      expect(issue.key).toBe("PROJ-1");
      expect(cfg).toMatchObject({ key: "PROJ" });
    });

    it("does not re-trigger when status stays in startStatus (AC-003-2)", async () => {
      // Load state: issue already in startStatus
      adapter.getJiraIssueStates = vi.fn().mockResolvedValue([
        {
          project_key: "PROJ",
          issue_key: "PROJ-1",
          last_known_status: "In Progress",
          last_updated_at: "2026-06-01T11:00:00Z",
        },
      ]);

      const poller = new JiraIssuesPoller(adapter, mockClient, jiraConfig, onTransition);
      await poller.loadState();

      mockClient.search.mockResolvedValue({
        issues: [
          {
            key: "PROJ-1",
            fields: {
              summary: "Test Issue",
              status: { name: "In Progress" },
              issuetype: { name: "Task" },
              project: { key: "PROJ" },
              updated: "2026-06-01T12:00:00Z",
            },
          },
        ],
        total: 1,
      });

      const result = await poller.pollProject(createJiraProjectConfig());

      expect(result.transitions).toBe(0);
      expect(onTransition).not.toHaveBeenCalled();
    });

    it("does not trigger when status moves from startStatus to endStatus (AC-003-3)", async () => {
      // Load state: issue in startStatus
      adapter.getJiraIssueStates = vi.fn().mockResolvedValue([
        {
          project_key: "PROJ",
          issue_key: "PROJ-1",
          last_known_status: "In Progress",
          last_updated_at: "2026-06-01T11:00:00Z",
        },
      ]);

      const poller = new JiraIssuesPoller(adapter, mockClient, jiraConfig, onTransition);
      await poller.loadState();

      // Issue moved to Done
      mockClient.search.mockResolvedValue({
        issues: [
          {
            key: "PROJ-1",
            fields: {
              summary: "Test Issue",
              status: { name: "Done" },
              issuetype: { name: "Task" },
              project: { key: "PROJ" },
              updated: "2026-06-01T12:00:00Z",
            },
          },
        ],
        total: 1,
      });

      const result = await poller.pollProject(createJiraProjectConfig());

      expect(result.transitions).toBe(0);
      expect(onTransition).not.toHaveBeenCalled();
    });
  });

  describe("state persistence", () => {
    it("persists issue state to database after poll", async () => {
      mockClient.search.mockResolvedValue({
        issues: [
          {
            key: "PROJ-1",
            fields: {
              summary: "Test Issue",
              status: { name: "In Progress" },
              issuetype: { name: "Task" },
              project: { key: "PROJ" },
              updated: "2026-06-01T12:00:00Z",
            },
          },
        ],
        total: 1,
      });

      const poller = new JiraIssuesPoller(adapter, mockClient, jiraConfig, onTransition);
      await poller.pollProject(createJiraProjectConfig());

      expect(adapter.upsertJiraIssueState).toHaveBeenCalled();
      expect(adapter.upsertJiraIssueState).toHaveBeenCalledWith(
        expect.objectContaining({
          jiraProjectKey: "PROJ",
          issueKey: "PROJ-1",
          lastKnownStatus: "In Progress",
        }),
      );
    });

    it("loads persisted state on startup (TRD-008)", async () => {
      adapter.getJiraIssueStates = vi.fn().mockResolvedValue([
        {
          project_key: "PROJ",
          issue_key: "PROJ-1",
          last_known_status: "To Do",
          last_updated_at: "2026-06-01T11:00:00Z",
        },
      ]);

      const poller = new JiraIssuesPoller(adapter, mockClient, jiraConfig, onTransition);
      await poller.loadState();

      expect(adapter.getJiraIssueStates).toHaveBeenCalled();
    });
  });
});

// ── JiraTriggerHandler tests ───────────────────────────────────────────────────

describe("JiraTriggerHandler", () => {
  let adapter: PostgresAdapter;
  let handler: JiraTriggerHandler;

  beforeEach(() => {
    vi.clearAllMocks();
    process.env.FOREMAN_PROJECT_ID = "test-project-id";
    adapter = createMockAdapter();
    adapter.getTaskByExternalId = vi.fn().mockResolvedValue(null);
    handler = new JiraTriggerHandler(adapter, "test-jira-project-id");
  });

  afterEach(() => {
    delete process.env.FOREMAN_PROJECT_ID;
  });

  describe("handleTransition", () => {
    const baseIssue = {
      key: "PROJ-1",
      fields: {
        summary: "Test Issue",
        status: { name: "In Progress" },
        issuetype: { name: "Task" },
        project: { key: "PROJ" },
        updated: "2026-06-01T12:00:00Z",
      },
    };

    const baseContext = {
      issue: baseIssue,
      projectConfig: createJiraProjectConfig(),
      jiraProjectId: "test-jira-project-id",
      source: "poll" as const,
    };

    it("skips if already triggered (uniqueness check)", async () => {
      adapter.getTaskByExternalId = vi.fn().mockResolvedValue({ id: "EXISTING-TASK" });

      const result = await handler.handleTransition(baseContext);

      expect(result.triggered).toBe(false);
      expect(result.reason).toBe("already_triggered");
      expect(adapter.createTask).not.toHaveBeenCalled();
    });

    it("maps Epic issue type to epic workflow", async () => {
      const epicIssue = {
        ...baseIssue,
        fields: { ...baseIssue.fields, issuetype: { name: "Epic" } },
      };

      const result = await handler.handleTransition({
        ...baseContext,
        issue: epicIssue,
      });

      expect(result.triggered).toBe(true);
      expect(result.workflowName).toBe("epic");
    });

    it("maps unknown type to default workflow", async () => {
      const unknownIssue = {
        ...baseIssue,
        fields: { ...baseIssue.fields, issuetype: { name: "Unknown Type" } },
      };

      const result = await handler.handleTransition({
        ...baseContext,
        issue: unknownIssue,
      });

      expect(result.triggered).toBe(true);
      expect(result.workflowName).toBe("default");
    });

    it("creates task with Jira metadata", async () => {
      await handler.handleTransition(baseContext);

      expect(adapter.createTask).toHaveBeenCalledWith(
        "test-project-id",
        expect.objectContaining({
          title: "Test Issue",
          externalId: "jira:PROJ-1",
          status: "ready",
          labels: expect.arrayContaining([
            "jira-workflow:default",
            "jira-type:task",
          ]),
        }),
      );
    });

    it("returns taskId on successful trigger", async () => {
      const result = await handler.handleTransition(baseContext);

      expect(result.triggered).toBe(true);
      expect(result.taskId).toBe("TASK-001");
      expect(result.externalId).toBe("jira:PROJ-1");
    });
  });
});
