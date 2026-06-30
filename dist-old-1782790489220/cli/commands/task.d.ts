/**
 * `foreman task` CLI commands — manage daemon-backed tasks in the Foreman task store.
 *
 * Sub-commands:
 *   foreman task create --title <text> [--description <text>] [--type <type>]
 *                        [--priority <level>]
 *   foreman task create --from-text "<description>" [--type <type>] [--priority <level>]
 *                        [--parent <id>] [--dry-run] [--no-llm] [--model <model>]
 *   foreman task list [--status <status>] [--all]
 *   foreman task show <id>
 *   foreman task update <id> [--title <text>] [--description <text>]
 *                           [--priority <level>] [--status <status>] [--force]
 *   foreman task approve <id>
 *   foreman task close <id>
 *   foreman task dep add <from-id> <to-id> [--type blocks|parent-child]
 *   foreman task dep list <id>
 *   foreman task dep remove <from-id> <to-id> [--type blocks|parent-child]
 *
 * @module src/cli/commands/task
 */
import { Command } from "commander";
interface ImportedBeadDependency {
    issue_id?: string;
    depends_on_id?: string;
    type?: string;
}
interface ImportedBeadRecord {
    id: string;
    title: string;
    description?: string | null;
    status?: string;
    priority?: number | string;
    issue_type?: string;
    type?: string;
    created_at?: string;
    updated_at?: string;
    closed_at?: string;
    dependencies?: ImportedBeadDependency[];
}
interface PreparedImportRecord {
    nativeId: string;
    bead: ImportedBeadRecord;
    type: string;
    priority: number;
    status: string;
    createdAt: string;
    updatedAt: string;
    approvedAt: string | null;
    closedAt: string | null;
}
export interface TaskImportResult {
    imported: number;
    duplicateSkips: number;
    unsupportedStatusSkips: number;
    jsonlPath: string;
    preview: PreparedImportRecord[];
}
export declare function performBeadsImport(projectPath: string, opts?: {
    dryRun?: boolean;
}): Promise<TaskImportResult>;
export declare const taskCommand: Command;
export {};
//# sourceMappingURL=task.d.ts.map