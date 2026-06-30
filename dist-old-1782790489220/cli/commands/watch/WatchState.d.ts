/**
 * WatchState — State machine for the unified watch poll + render cycle.
 *
 * Responsibilities:
 * - Poll cycle state: store, runs, messages, task counts
 * - Key handling state: focused panel, selected task
 * - Live inbox tracking: last seen message ID for new-message detection
 * - SIGWINCH handling: terminal resize signal
 */
import { ForemanStore } from "../../../lib/store.js";
import type { Run, RunProgress, Message, EventType } from "../../../lib/store.js";
import type { BoardTask } from "../board.js";
import { type DashboardState } from "../../dashboard-state.js";
import { type BoardStatus } from "../board.js";
export type PanelId = "agents" | "board" | "inbox" | "events";
export declare function nextPanel(current: PanelId): PanelId;
export interface WatchOptions {
    refreshMs: number;
    inboxLimit: number;
    inboxPollMs: number;
    eventsLimit: number;
    noWatch: boolean;
    noBoard: boolean;
    noInbox: boolean;
    noEvents: boolean;
    projectId?: string;
}
export interface AgentEntry {
    run: Run;
    progress: RunProgress | null;
}
export interface BoardSummary {
    counts: Record<BoardStatus, number>;
    total: number;
    ready: number;
    needsAttention: BoardTask[];
}
export interface InboxEntry {
    message: Message;
    isNew: boolean;
}
export interface InboxState {
    messages: InboxEntry[];
    totalCount: number;
    newestTimestamp: string | null;
    oldestTimestamp: string | null;
}
export interface PipelineEventEntry {
    id: string;
    eventType: EventType;
    runId: string | null;
    details: Record<string, unknown> | null;
    createdAt: string;
    isNew: boolean;
}
export interface EventsState {
    events: PipelineEventEntry[];
    totalCount: number;
    newestTimestamp: string | null;
    oldestTimestamp: string | null;
}
export interface WatchState {
    dashboard: DashboardState | null;
    agents: AgentEntry[];
    board: BoardSummary | null;
    inbox: InboxState | null;
    events: EventsState | null;
    taskCounts: {
        total: number;
        ready: number;
        inProgress: number;
        completed: number;
        blocked: number;
    } | null;
    lastPollMs: number;
    lastInboxPollMs: number;
    inboxLastSeenId: string | null;
    eventsLastSeenId: string | null;
    focusedPanel: PanelId;
    expandedAgentIndices: Set<number>;
    selectedTaskIndex: number;
    showHelp: boolean;
    errorMessage: string | null;
    agentsOffline: boolean;
    boardOffline: boolean;
    inboxOffline: boolean;
    eventsOffline: boolean;
}
export declare function initialWatchState(): WatchState;
export interface PollResult {
    dashboard: DashboardState;
    agents: AgentEntry[];
    board: BoardSummary;
    taskCounts: {
        total: number;
        ready: number;
        inProgress: number;
        completed: number;
        blocked: number;
    };
}
/**
 * Poll all data sources for the main display.
 * Returns null for unavailable sources (graceful degradation).
 */
export declare function pollWatchData(projectPath: string, projectId?: string): Promise<PollResult>;
/**
 * Poll inbox messages for the inbox panel.
 * Returns new messages since `lastSeenId` + total count.
 */
export declare function pollInboxData(store: ForemanStore, lastSeenId: string | null, inboxLimit: number, runIds: string[], projectPath?: string, projectId?: string): Promise<{
    messages: InboxEntry[];
    totalCount: number;
    newestId: string | null;
}>;
/**
 * Poll pipeline events for the events panel.
 * Returns events + total count for watched runIds.
 */
export declare function pollPipelineEvents(store: ForemanStore, lastSeenId: string | null, eventsLimit: number, runIds: string[], projectPath?: string, projectId?: string): Promise<{
    events: PipelineEventEntry[];
    totalCount: number;
    newestId: string | null;
}>;
export interface KeyAction {
    panel: PanelId | "global";
    key: string;
    description: string;
    handler: (state: WatchState) => KeyHandlerResult;
}
export interface KeyHandlerResult {
    /** Re-render the display */
    render: boolean;
    /** Interrupt the poll sleep to update immediately */
    wake: boolean;
    /** Quit the watch loop */
    quit: boolean;
    /** No key was matched */
    none: boolean;
}
/**
 * Handle a single keypress in the watch loop.
 * Returns whether to re-render, wake the poll sleep, or quit.
 */
export declare function handleWatchKey(state: WatchState, key: string): KeyHandlerResult;
export declare function renderHelpOverlay(width: number): string;
//# sourceMappingURL=WatchState.d.ts.map