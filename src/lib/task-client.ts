/**
 * ITaskClient — common interface for task-tracking back-ends.
 *
 * Both SeedsClient (sd) and BeadsRustClient (br) implement this interface,
 * allowing the Dispatcher (and other orchestrator components) to be
 * decoupled from a specific task-tracker implementation.
 */

// ── Common Issue type ────────────────────────────────────────────────────

/**
 * Normalized representation of a task-tracker issue.
 *
 * Maps fields that exist on both Seed (sd) and BrIssue (br):
 *   Seed.id          ↔ BrIssue.id
 *   Seed.title       ↔ BrIssue.title
 *   Seed.type        ↔ BrIssue.type
 *   Seed.priority    ↔ BrIssue.priority  (string, e.g. "P0"–"P4" or "0"–"4")
 *   Seed.status      ↔ BrIssue.status
 *   Seed.assignee    ↔ BrIssue.assignee
 *   Seed.parent      ↔ BrIssue.parent
 *   Seed.created_at  ↔ BrIssue.created_at
 *   Seed.updated_at  ↔ BrIssue.updated_at
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
}

// ── Update options ───────────────────────────────────────────────────────

/**
 * Options accepted by ITaskClient.update().
 *
 * The union of update options supported by SeedsClient and BeadsRustClient.
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
}

// ── ITaskClient interface ────────────────────────────────────────────────

/**
 * Common interface for task-tracking back-ends (sd / br).
 *
 * Covers the methods used by Dispatcher. Implementations must map their
 * native issue types to the common Issue type.
 */
export interface ITaskClient {
  /**
   * Return issues that are open and have no unresolved blockers
   * (i.e. are immediately actionable).
   */
  ready(): Promise<Issue[]>;

  /**
   * Update fields on an issue.
   */
  update(id: string, opts: UpdateOptions): Promise<void>;

  /**
   * Close an issue, optionally recording a reason.
   */
  close(id: string, reason?: string): Promise<void>;
}
