import type { EpicTask } from "./pipeline-executor.js";

/**
 * Serialized worker launch configuration written by the dispatcher and read by
 * agent-worker. Keep this as the single source of truth for the wire format.
 */
export interface WorkerConfig {
  runId: string;
  projectId: string;
  seedId: string;
  seedTitle: string;
  seedDescription?: string;
  seedComments?: string;
  model: string;
  worktreePath: string;
  /** Project root directory (contains .beads/). Used as cwd for br commands. */
  projectPath?: string;
  prompt: string;
  env: Record<string, string>;
  resume?: string;
  pipeline?: boolean;
  skipExplore?: boolean;
  skipReview?: boolean;
  /** Absolute path to the SQLite DB file (e.g. .foreman/foreman.db). */
  dbPath?: string;
  /**
   * Resolved workflow type (e.g. "smoke", "feature", "bug").
   * Derived from label-based override or bead type field.
   * Used for prompt-loader workflow scoping and spawn strategy selection.
   */
  seedType?: string;
  /**
   * Labels from the bead. Forwarded to agent-worker so it can resolve
   * `workflow:<name>` label overrides.
   */
  seedLabels?: string[];
  /**
   * Bead priority string ("P0"–"P4", "0"–"4", or undefined).
   * Forwarded to the pipeline executor to resolve per-priority models from YAML.
   */
  seedPriority?: string;
  /**
   * Override target branch for auto-merge after finalize.
   * When set, the agent worker merges into this branch instead of
   * detectDefaultBranch().
   */
  targetBranch?: string;
  /**
   * Optional task ID from native task store (NativeTaskStore.claim()).
   * When present, pipeline will call taskStore.updatePhase(taskId, phaseName)
   * at each phase transition for phase-level visibility.
   */
  taskId?: string | null;
  /**
   * Ordered list of child tasks for epic execution mode.
   * When set, the worker runs the epic pipeline: taskPhases per child task,
   * then finalPhases once at the end.
   */
  epicTasks?: EpicTask[];
  /**
   * Parent epic bead ID.
   * When set, this run is an epic execution and the worker executes all
   * epicTasks within a single worktree.
   */
  epicId?: string;
}
