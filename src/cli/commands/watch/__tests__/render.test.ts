import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const { mockRenderWatchLayout, mockRenderHelpOverlay } = vi.hoisted(() => ({
  mockRenderWatchLayout: vi.fn(),
  mockRenderHelpOverlay: vi.fn(),
}));

vi.mock("../WatchLayout.js", async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  renderWatchLayout: mockRenderWatchLayout,
}));

vi.mock("../WatchState.js", async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  renderHelpOverlay: mockRenderHelpOverlay,
}));

import { renderErrorToast, renderWatch, renderWatchFooter, renderWatchHeader } from "../render.js";
import type { WatchState } from "../WatchState.js";

function makeState(overrides: Partial<WatchState> = {}): WatchState {
  return {
    dashboard: null,
    agents: [],
    board: null,
    inbox: null,
    events: null,
    taskCounts: null,
    lastPollMs: 0,
    lastInboxPollMs: 0,
    inboxLastSeenId: null,
    eventsLastSeenId: null,
    focusedPanel: "agents",
    expandedAgentIndices: new Set(),
    selectedTaskIndex: -1,
    showHelp: false,
    errorMessage: null,
    agentsOffline: false,
    boardOffline: false,
    inboxOffline: false,
    eventsOffline: false,
    ...overrides,
  };
}

describe("watch render", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockRenderWatchLayout.mockReturnValue("LAYOUT");
    mockRenderHelpOverlay.mockReturnValue("HELP");
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("renders the normal watch layout when help is hidden", () => {
    const state = makeState({
      dashboard: { projects: [{ name: "proj" }] } as WatchState["dashboard"],
    });

    const rendered = renderWatch(state);

    expect(mockRenderWatchLayout).toHaveBeenCalledWith(state, 120);
    expect(rendered).toContain("FOREMAN WATCH");
    expect(rendered).toContain("LAYOUT");
  });

  it("renders the help overlay instead of the normal layout when help is shown", () => {
    const state = makeState({ showHelp: true });

    const rendered = renderWatch(state);

    expect(mockRenderWatchLayout).not.toHaveBeenCalled();
    expect(mockRenderHelpOverlay).toHaveBeenCalledWith(120);
    expect(rendered).toContain("HELP");
  });

  it("renders a fallback project name in the header", () => {
    const rendered = renderWatchHeader(makeState());
    expect(rendered).toContain("FOREMAN WATCH");
    expect(rendered).toContain("—");
  });

  it("renders the last updated time in the footer when available", () => {
    const rendered = renderWatchFooter(makeState({ lastPollMs: new Date("2026-01-01T12:34:56.000Z").getTime() }));
    expect(rendered).toContain("Last updated:");
    expect(rendered).toContain("Ctrl+C to quit");
  });

  it("renders a placeholder footer when no poll has happened yet", () => {
    const rendered = renderWatchFooter(makeState({ lastPollMs: 0 }));
    expect(rendered).toContain("Last updated: —");
  });

  it("renders an error toast box sized to the requested width", () => {
    const rendered = renderErrorToast("boom", 20);
    const lines = rendered.split("\n");

    expect(lines).toHaveLength(3);
    expect(lines[0]).toBe("┌────────────────┐");
    expect(lines[2]).toBe("└────────────────┘");
    expect(lines[1]).toContain("⚠ boom");
  });
});
