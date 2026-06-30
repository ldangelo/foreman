/**
 * WatchLayout — Responsive panel layout computation for the unified watch display.
 *
 * Layout modes:
 * - 3-panel side-by-side at 120+ columns
 * - 3-panel side-by-side at 90-119 columns (narrower panels)
 * - 3-panel stacked at 80-89 columns
 * - Warning at < 80 columns
 *
 * Panel widths are computed proportionally based on terminal width.
 * Each panel has a header line and a body.
 */
import { type PanelId, type WatchState } from "./WatchState.js";
export type LayoutMode = "wide" | "medium" | "narrow" | "too-narrow";
export declare function detectLayoutMode(width: number): LayoutMode;
export declare function getPanelWidths(mode: LayoutMode, totalWidth: number): Record<PanelId, number>;
export interface LayoutSection {
    panel: PanelId;
    lines: string[];
}
export declare function computeLayoutSections(state: WatchState, totalWidth: number): LayoutSection[];
/**
 * Render the full unified watch display as a string.
 */
export declare function renderWatchLayout(state: WatchState, totalWidth: number): string;
//# sourceMappingURL=WatchLayout.d.ts.map