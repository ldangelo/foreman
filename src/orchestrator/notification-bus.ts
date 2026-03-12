/**
 * Notification Bus — event emitter for worker status/progress notifications.
 *
 * Workers POST JSON notifications to the NotificationServer, which forwards
 * them to this bus. Consumers (watch-ui, monitor) subscribe to receive
 * real-time updates instead of waiting for the next poll cycle.
 */

import { EventEmitter } from "node:events";
import type { WorkerNotification } from "./types.js";

export class NotificationBus extends EventEmitter {
  constructor() {
    super();
    // Each watched run subscribes on its own "notification:<runId>" channel
    // (max 1 listener per channel with current usage), so the default cap of 10
    // is never hit in practice. Raise the limit as a precaution against future
    // consumers that subscribe to the global "notification" channel from many
    // places simultaneously.
    this.setMaxListeners(0);
  }

  /**
   * Forward a notification received from a worker to all subscribers.
   * Emits on two channels:
   *   - "notification"          — all notifications
   *   - "notification:<runId>"  — per-run channel for targeted listeners
   */
  notify(notification: WorkerNotification): void {
    this.emit("notification", notification);
    this.emit(`notification:${notification.runId}`, notification);
  }

  /** Subscribe to all notifications from all workers. */
  onNotification(handler: (n: WorkerNotification) => void): this {
    return this.on("notification", handler);
  }

  /** Subscribe to notifications for a specific run. */
  onRunNotification(runId: string, handler: (n: WorkerNotification) => void): this {
    return this.on(`notification:${runId}`, handler);
  }

  /** Unsubscribe from notifications for a specific run. */
  offRunNotification(runId: string, handler: (n: WorkerNotification) => void): this {
    return this.off(`notification:${runId}`, handler);
  }
}

/** Shared singleton notification bus instance. */
export const notificationBus = new NotificationBus();
