import { render as renderInk } from "ink";
import { createElement } from "react";
import type { InboxTaskSummary } from "../commands/inbox.js";
import type { SuperTuiDataAdapter } from "./data.js";
import { loadInitialSuperTuiSummaries } from "./data.js";
import type { SuperTuiView } from "./model.js";
import { SuperTuiApp } from "./App.js";
import type { RenderSuperTuiTaskDetail } from "./panes/DetailPane.js";

export interface RunSuperTuiOptions {
  adapter: SuperTuiDataAdapter;
  initialView?: SuperTuiView;
  initialTaskId?: string | null;
  initialRunId?: string | null;
  limit: number;
  eventsLimit: number;
  renderTaskDetail?: RenderSuperTuiTaskDetail;
  refreshIntervalMs?: number;
}

export async function runSuperTui(options: RunSuperTuiOptions): Promise<void> {
  const summaries: InboxTaskSummary[] = await loadInitialSuperTuiSummaries(options.adapter);
  const app = renderInk(createElement(SuperTuiApp, {
    summaries,
    projectLabel: options.adapter.projectLabel,
    limit: options.limit,
    eventsLimit: options.eventsLimit,
    initialView: options.initialView,
    initialTaskId: options.initialTaskId,
    initialRunId: options.initialRunId,
    renderTaskDetail: options.renderTaskDetail,
    loadSummaries: options.adapter.loadSummaries,
    refreshIntervalMs: options.refreshIntervalMs,
  }));
  await app.waitUntilExit();
}
