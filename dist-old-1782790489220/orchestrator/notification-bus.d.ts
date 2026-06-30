/**
 * Notification Bus — event emitter for worker status/progress notifications.
 *
 * Workers POST JSON notifications to the NotificationServer, which forwards
 * them to this bus. Consumers (watch-ui, monitor) subscribe to receive
 * real-time updates instead of waiting for the next poll cycle.
 */
import { EventEmitter } from "node:events";
import type { WorkerNotification } from "./types.js";
export declare class NotificationBus extends EventEmitter {
    constructor();
    /**
     * Forward a notification received from a worker to all subscribers.
     * Emits on two channels:
     *   - "notification"          — all notifications
     *   - "notification:<runId>"  — per-run channel for targeted listeners
     */
    notify(notification: WorkerNotification): void;
    /** Subscribe to all notifications from all workers. */
    onNotification(handler: (n: WorkerNotification) => void): this;
    /** Subscribe to notifications for a specific run. */
    onRunNotification(runId: string, handler: (n: WorkerNotification) => void): this;
    /** Unsubscribe from notifications for a specific run. */
    offRunNotification(runId: string, handler: (n: WorkerNotification) => void): this;
}
/** Shared singleton notification bus instance. */
export declare const notificationBus: NotificationBus;
//# sourceMappingURL=notification-bus.d.ts.map