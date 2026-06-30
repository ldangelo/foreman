import { Command } from "commander";
import type { ITaskClient, Issue } from "../../lib/task-client.js";
interface PlanCreateOptions {
    type?: string;
    priority?: string;
    parent?: string;
    description?: string;
}
export interface PlanTaskClient extends ITaskClient {
    create(title: string, opts?: PlanCreateOptions): Promise<Issue>;
    addDependency(fromId: string, toId: string): Promise<void>;
}
export declare function createPlanClient(projectPath: string): PlanTaskClient;
export declare const planCommand: Command;
export declare function readPlanningInput(description: string, projectPath: string): string;
export declare function inferPrdHintPath(outputDir: string, fromPrd?: string): string;
export {};
//# sourceMappingURL=plan.d.ts.map