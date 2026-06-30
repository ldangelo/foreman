/**
 * render.ts — Top-level render compositing for the unified watch display.
 *
 * Provides:
 * - renderWatch(): assembles the full display from WatchState
 * - renderWatchHeader(): header bar with project name, refresh, quit hint
 * - renderWatchFooter(): footer with last updated time
 */
import { type WatchState } from "./WatchState.js";
/**
 * Render the complete unified watch display.
 * Returns the full terminal-ready string.
 */
export declare function renderWatch(state: WatchState): string;
/**
 * Render the display header bar.
 */
export declare function renderWatchHeader(state: WatchState): string;
/**
 * Render the display footer.
 */
export declare function renderWatchFooter(state: WatchState): string;
/**
 * Render a temporary error toast (shown for 3 seconds after a failed action).
 */
export declare function renderErrorToast(message: string, width: number): string;
//# sourceMappingURL=render.d.ts.map