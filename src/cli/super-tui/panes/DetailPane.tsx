import { createElement, useEffect, useState, type ReactElement, useRef } from "react";
import type { InboxTaskSummary } from "../../commands/inbox.js";
import type { SuperTuiTab } from "../model.js";
import { TaskDetails, type TaskDetailsProps } from "../components/TaskDetails.js";

export type RenderSuperTuiTaskDetail = (summary: InboxTaskSummary, options: { messages: boolean; events: boolean; logs?: boolean; reports?: boolean; files?: boolean; limit: number; eventsLimit: number }) => string | Promise<string>;

interface DetailPaneProps {
  summary: InboxTaskSummary | undefined;
  tab: SuperTuiTab;
  limit: number;
  eventsLimit: number;
  renderTaskDetail?: RenderSuperTuiTaskDetail;
  compact: boolean;
}

interface RenderContext {
  runId: string;
  tab: SuperTuiTab;
  limit: number;
  eventsLimit: number;
}

/**
 * Detail pane for the super-tui cockpit. Thin wrapper that delegates field
 * rendering to the shared `TaskDetails` component. The wrapper only owns
 * the async artifact fetch (logs/reports/files) for the on-disk tabs.
 */
export function DetailPane({ summary, tab, limit, eventsLimit, renderTaskDetail, compact }: DetailPaneProps): ReactElement {
  const [renderedDetail, setRenderedDetail] = useState<string | undefined>(undefined);
  // Guard against stale async renders when the user switches tasks or tabs.
  const renderCtxRef = useRef<RenderContext | null>(null);

  useEffect(() => {
    if (!renderTaskDetail || !(tab === "logs" || tab === "reports" || tab === "files")) {
      setRenderedDetail(undefined);
      renderCtxRef.current = null;
      return;
    }
    if (!summary) return;
    const ctx: RenderContext = { runId: summary.runId, tab, limit, eventsLimit };
    renderCtxRef.current = ctx;
    try {
      const result = renderTaskDetail(summary, {
        messages: false,
        events: false,
        logs: tab === "logs",
        reports: tab === "reports",
        files: tab === "files",
        limit,
        eventsLimit,
      });
      if (result instanceof Promise) {
        result.then((output) => {
          if (renderCtxRef.current?.runId !== ctx.runId) return; // stale — user switched tasks
          setRenderedDetail(output);
        }).catch(() => {
          if (renderCtxRef.current?.runId !== ctx.runId) return;
          setRenderedDetail(undefined);
        });
      } else {
        if (renderCtxRef.current?.runId === ctx.runId) {
          setRenderedDetail(result);
        }
      }
    } catch {
      if (renderCtxRef.current?.runId === ctx.runId) {
        setRenderedDetail(undefined);
      }
    }
  }, [summary, tab, limit, eventsLimit, renderTaskDetail]);

  const detailProps: TaskDetailsProps = {
    summary,
    tab,
    compact,
    renderedDetail,
    limit,
    eventsLimit,
  };

  return createElement(TaskDetails, detailProps);
}
