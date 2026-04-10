import { describe, it, expect, vi, beforeEach } from "vitest";

const { MockForemanStore, mockRegistryList } = vi.hoisted(() => {
  const mockRegistryList = vi.fn().mockReturnValue([]);
  const MockForemanStore = {
    forProject: vi.fn(),
  };
  return { MockForemanStore, mockRegistryList };
});

vi.mock("../../lib/store.js", () => ({ ForemanStore: MockForemanStore }));
vi.mock("../../lib/project-registry.js", () => ({
  ProjectRegistry: vi.fn(function (this: { list: typeof mockRegistryList }) {
    this.list = mockRegistryList;
  }),
}));

import { inspectFleetHealth } from "../fleet-monitor.js";

describe("inspectFleetHealth", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("marks a project ready when latest validation passed", () => {
    mockRegistryList.mockReturnValue([
      { name: "alpha", path: "/tmp/alpha", addedAt: "2026-04-08T00:00:00Z" },
    ]);
    (MockForemanStore.forProject as ReturnType<typeof vi.fn>).mockReturnValue({
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getSentinelConfig: vi.fn().mockReturnValue({ branch: "main" }),
      getSentinelRuns: vi.fn().mockReturnValue([{ status: "passed", started_at: "2026-04-08T00:00:00Z" }]),
      getActiveRuns: vi.fn().mockReturnValue([]),
      close: vi.fn(),
    });

    const result = inspectFleetHealth();
    expect(result[0]?.validationReady).toBe(true);
    expect(result[0]?.healthSummary).toContain("last passed validation");
  });

  it("marks a project as attention-needed when validation is missing", () => {
    mockRegistryList.mockReturnValue([
      { name: "beta", path: "/tmp/beta", addedAt: "2026-04-08T00:00:00Z" },
    ]);
    (MockForemanStore.forProject as ReturnType<typeof vi.fn>).mockReturnValue({
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-2" }),
      getSentinelConfig: vi.fn().mockReturnValue(null),
      getSentinelRuns: vi.fn().mockReturnValue([]),
      getActiveRuns: vi.fn().mockReturnValue([]),
      close: vi.fn(),
    });

    const result = inspectFleetHealth();
    expect(result[0]?.validationReady).toBe(false);
    expect(result[0]?.healthSummary).toContain("No integration validation configured");
  });
});
