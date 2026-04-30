/**
 * Unit tests for WatchState.ts
 */

import { describe, it, expect, beforeEach } from "vitest";
import {
  initialWatchState,
  nextPanel,
  handleWatchKey,
  type WatchState,
  type PanelId,
} from "../WatchState.js";

describe("WatchState", () => {
  describe("initialWatchState", () => {
    it("returns a valid initial state", () => {
      const state = initialWatchState();
      expect(state.dashboard).toBeNull();
      expect(state.agents).toEqual([]);
      expect(state.board).toBeNull();
      expect(state.inbox).toBeNull();
      expect(state.events).toBeNull();
      expect(state.focusedPanel).toBe("agents");
      expect(state.expandedAgentIndices.size).toBe(0);
      expect(state.selectedTaskIndex).toBe(-1);
      expect(state.showHelp).toBe(false);
      expect(state.errorMessage).toBeNull();
      expect(state.agentsOffline).toBe(false);
      expect(state.boardOffline).toBe(false);
      expect(state.inboxOffline).toBe(false);
      expect(state.eventsOffline).toBe(false);
    });
  });

  describe("nextPanel", () => {
    it("cycles agents → board → inbox → events → agents", () => {
      expect(nextPanel("agents")).toBe("board");
      expect(nextPanel("board")).toBe("inbox");
      expect(nextPanel("inbox")).toBe("events");
      expect(nextPanel("events")).toBe("agents");
    });
  });

  describe("handleWatchKey", () => {
    let state: WatchState;

    beforeEach(() => {
      state = initialWatchState();
      state.agents = [];
      state.board = null;
    });

    it("quits on q", () => {
      const result = handleWatchKey(state, "q");
      expect(result.quit).toBe(true);
      expect(result.none).toBe(false);
    });

    it("quits on Q", () => {
      const result = handleWatchKey(state, "Q");
      expect(result.quit).toBe(true);
    });

    it("quits on ESC", () => {
      const result = handleWatchKey(state, "\u001B");
      expect(result.quit).toBe(true);
    });

    it("toggles help on ?", () => {
      expect(state.showHelp).toBe(false);
      let result = handleWatchKey(state, "?");
      expect(result.render).toBe(true);
      expect(state.showHelp).toBe(true);
      result = handleWatchKey(state, "?");
      expect(result.render).toBe(true);
      expect(state.showHelp).toBe(false);
    });

    it("cycles focus on Tab", () => {
      expect(state.focusedPanel).toBe("agents");
      let result = handleWatchKey(state, "\t");
      expect(result.render).toBe(true);
      expect(state.focusedPanel).toBe("board");

      result = handleWatchKey(state, "\t");
      expect(result.render).toBe(true);
      expect(state.focusedPanel).toBe("inbox");

      result = handleWatchKey(state, "\t");
      expect(result.render).toBe(true);
      expect(state.focusedPanel).toBe("events");

      result = handleWatchKey(state, "\t");
      expect(result.render).toBe(true);
      expect(state.focusedPanel).toBe("agents");
    });

    it("returns none for unrecognized keys", () => {
      const result = handleWatchKey(state, "z");
      expect(result.none).toBe(true);
      expect(result.quit).toBe(false);
      expect(result.render).toBe(false);
    });

    it("sets board focus on Tab in agents panel", () => {
      state.focusedPanel = "agents";
      const result = handleWatchKey(state, "\t");
      expect(result.render).toBe(true);
      expect(state.focusedPanel).toBe("board");
    });
  });
});
