/**
 * ITaskClient — common interface for task-tracking back-ends.
 *
 * BeadsRustClient (br) implements this interface, allowing the Dispatcher
 * (and other orchestrator components) to be decoupled from a specific
 * task-tracker implementation.
 */

// ── Common Issue type ────────────────────────────────────────────────────

/**
 * Normalized representation of a task-tracker issue.
 *
 * Maps fields that exist on both Bead (sd) and BrIssue (br):
 *   Bead.id          ↔ BrIssue.id
 *   Bead.title       ↔ BrIssue.title
 *   Bead.type        ↔ BrIssue.type
 *   Bead.priority    ↔ BrIssue.priority  (string, e.g. "P0"–"P4" or "0"–"4")
 *   Bead.status      ↔ BrIssue.status
 *   Bead.assignee    ↔ BrIssue.assignee
 *   Bead.parent      ↔ BrIssue.parent
 *   Bead.created_at  ↔ BrIssue.created_at
 *   Bead.updated_at  ↔ BrIssue.updated_at
 */
export interface Issue {
  id: string;
  title: string;
  type: string;
  /** Priority string — "P0"–"P4" (sd) or "0"–"4" (br). Use normalizePriority() for comparisons. */
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
}

// ── Update options ───────────────────────────────────────────────────────

/**
 * Options accepted by ITaskClient.update().
 *
 * The union of update options supported by BeadsRustClient.
 * Individual implementations may ignore unsupported fields.
 */
export interface UpdateOptions {
  /** Atomically claim the issue (set to in_progress + assign to current user). */
  claim?: boolean;
  title?: string;
  status?: string;
  assignee?: string;
  description?: string;
  notes?: string;
  acceptance?: string;
  labels?: string[];
}

// ── ITaskClient interface ────────────────────────────────────────────────

/**
 * Common interface for the task-tracking back-end (br).
 *
 * Covers the methods used by Dispatcher. Implementations must map their
 * native issue types to the common Issue type.
 */
export interface ITaskClient {
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
   * BrIssueDetail or BeadDetail respectively, both of which include these fields.
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
   * Fetch comments for an issue as a formatted markdown string.
   * Returns null if there are no comments.
   * Optional — implementations that do not support comments may omit this method.
   */
  comments?(id: string): Promise<string | null>;
}
