/**
 * ITaskClient — common interface for task-tracking back-ends.
 *
 * TaskClient (native task store) implements this interface, allowing the Dispatcher
 * (and other orchestrator components) to be decoupled from a specific
 * task-tracker implementation.
 */

// ── Common Issue type ────────────────────────────────────────────────────

/**
 * Normalized representation of a task-tracker issue.
 *
 * Maps fields that exist on both Task (sd) and BrIssue (native task store):
 *   Task.id          ↔ BrIssue.id
 *   Task.title       ↔ BrIssue.title
 *   Task.type        ↔ BrIssue.type
 *   Task.priority    ↔ BrIssue.priority  (string, e.g. "P0"–"P4" or "0"–"4")
 *   Task.status      ↔ BrIssue.status
 *   Task.assignee    ↔ BrIssue.assignee
 *   Task.parent      ↔ BrIssue.parent
 *   Task.created_at  ↔ BrIssue.created_at
 *   Task.updated_at  ↔ BrIssue.updated_at
 */
export interface Issue {
  id: string;
  title: string;
  type: string;
  /** Priority string — "P0"–"P4" (sd) or "0"–"4" (native task store). Use normalizePriority() for comparisons. */
  priority: string;
  status: string;
  assignee: string | null;
  parent: string | null;
  created_at: string;
  updated_at: string;
  /** Full description text. Populated when fetched via show(); absent on list/ready() results. */
  description?: string | null;
  /** Labels attached to this issue (e.g. ["workflow:smoke"]). Populated by show(). */
  labels?: string[];
  /** GitHub issue number for this task (from github_issue_number field). */
  githubIssueNumber?: number;
}

// ── Update options ───────────────────────────────────────────────────────

/**
 * Options accepted by ITaskClient.update().
 *
 * The union of update options supported by TaskClient.
 * Individual implementations may ignore unsupported fields.
 */
export interface UpdateOptions {
  /** Atomically claim the issue (set to in_progress + assign to current user). */
  claim?: boolean;
  title?: string;
  status?: string;
  runId?: string | null;
  source?: string;
  assignee?: string;
  description?: string;
  notes?: string;
  acceptance?: string;
  labels?: string[];
}

export interface CreateOptions {
  type?: string;
  priority?: string;
  parent?: string;
  description?: string;
  labels?: string[];
}

// ── ITaskClient interface ────────────────────────────────────────────────

/**
 * Common interface for the task-tracking back-end (native task store).
 *
 * Covers the methods used by Dispatcher. Implementations must map their
 * native issue types to the common Issue type.
 */
export interface ITaskClient {
  /**
   * Create a new task when the active backend supports writes.
   */
  create?(title: string, opts?: CreateOptions): Promise<Issue>;

  /**
   * List issues with optional filters.
   */
  list(opts?: { status?: string; type?: string }): Promise<Issue[]>;

  /**
   * Return issues that are open and have no unresolved blockers
   * (i.e. are immediately actionable).
   */
  ready(): Promise<Issue[]>;

  /**
   * Show full detail for a single issue.
   *
   * Used by Monitor to detect completion (status === "closed" | "completed")
   * and by Dispatcher to fetch the description and notes for agent prompts.
   * The return type is intentionally loose — concrete implementations return
   * BrIssueDetail or TaskDetail respectively, both of which include these fields.
   */
  show(id: string): Promise<{ status: string; description?: string | null; notes?: string | null }>;

  /**
   * Update fields on an issue.
   */
  update(id: string, opts: UpdateOptions): Promise<void>;

  /**
   * Close an issue, optionally recording a reason.
   */
  close(id: string, reason?: string): Promise<void>;

  /**
   * Reset a native task back to the retryable ready state.
   *
   * Optional because tasks-style backends reset via `update(..., {status:"open"})`
   * instead of a dedicated method.
   */
  resetToReady?(id: string, reason?: string): Promise<void>;

  /**
   * Fetch comments for an issue as a formatted markdown string.
   * Returns null if there are no comments.
   * Optional — implementations that do not support comments may omit this method.
   */
  /**
   * Fetch comments for an issue as a formatted markdown string.
   * Returns null if there are no comments.
   * Optional — implementations that do not support comments may omit this method.
   */
  comments?(id: string): Promise<string | null>;
  /**
   * Claim an issue — transition it from a ready/start status to in-progress.
   * Used by Sentinel to take ownership of an issue before working on it.
   * 
   * Returns the updated issue with its new status.
   * Throws if the issue cannot be claimed (e.g., no valid transitions).
   */
  claim?(id: string): Promise<Issue>;
}