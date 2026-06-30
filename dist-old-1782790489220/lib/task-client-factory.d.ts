import type { ITaskClient } from "./task-client.js";
export type TaskClientBackend = "native";
export interface TaskClientFactoryResult {
    backendType: TaskClientBackend;
    taskClient: ITaskClient;
}
export interface TaskClientFactoryOptions {
    registeredProjectId?: string;
}
export interface TaskCounts {
    total: number;
    ready: number;
    inProgress: number;
    completed: number;
    blocked: number;
}
export declare function createTaskClient(projectPath: string, opts?: TaskClientFactoryOptions): Promise<TaskClientFactoryResult>;
export declare function fetchTaskCounts(projectPath: string): Promise<TaskCounts>;
//# sourceMappingURL=task-client-factory.d.ts.map