import { describe, it, expect, vi, beforeEach } from "vitest";
import { initProjectStore } from "../commands/init.js";

function makeStore(overrides: Record<string, unknown> = {}) {
  return {
    getProjectByPath: vi.fn().mockReturnValue(null),
    registerProject: vi.fn().mockReturnValue({ id: "proj-new" }),
    getSentinelConfig: vi.fn().mockReturnValue(null),
    upsertSentinelConfig: vi.fn().mockReturnValue({}),
    ...overrides,
  } as unknown as import("../../lib/store.js").ForemanStore;
}

describe("initProjectStore — sentinel seeding", () => {
  beforeEach(() => {
    vi.spyOn(console, "log").mockImplementation(() => {});
  });

  it("seeds default sentinel config on fresh project", async () => {
    const store = makeStore();

    await initProjectStore("/my/project", "my-project", store);

    expect(store.getSentinelConfig).toHaveBeenCalledWith("proj-new");
    expect(store.upsertSentinelConfig).toHaveBeenCalledWith("proj-new", {
      branch: "main",
      test_command: "npm test",
      interval_minutes: 30,
      failure_threshold: 2,
      enabled: 1,
    });
  });

  it("skips sentinel seeding when config already exists", async () => {
    const store = makeStore({
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-existing" }),
      getSentinelConfig: vi.fn().mockReturnValue({ enabled: 1 }),
    });

    await initProjectStore("/my/project", "my-project", store);

    expect(store.upsertSentinelConfig).not.toHaveBeenCalled();
  });

  it("uses existing project id when project is already registered", async () => {
    const store = makeStore({
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-existing" }),
      getSentinelConfig: vi.fn().mockReturnValue(null),
    });

    await initProjectStore("/my/project", "my-project", store);

    expect(store.getSentinelConfig).toHaveBeenCalledWith("proj-existing");
    expect(store.upsertSentinelConfig).toHaveBeenCalledWith("proj-existing", expect.any(Object));
  });
});
