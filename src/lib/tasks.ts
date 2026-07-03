/**
 * Legacy task-client compatibility exports.
 *
 * File-backed task backends were removed after the Elixir cutover. Runtime code
 * should use the Elixir task APIs and the shared ITaskClient/Issue types.
 */
export type { Issue as Task, Issue as TaskDetail, ITaskClient } from "./task-client.js";

export class TasksClient {
  constructor(_projectPath?: string) {
    throw new Error("TasksClient was removed after the Elixir backend cutover. Use Elixir task APIs instead.");
  }
}

export async function execSd(): Promise<never> {
  throw new Error("execSd was removed after the Elixir backend cutover. Use Elixir task APIs instead.");
}

export function unwrapSdResponse<T>(value: T): T {
  return value;
}
