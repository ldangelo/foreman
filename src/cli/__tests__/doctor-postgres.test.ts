import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

describe("doctor postgres connectivity", () => {
  beforeEach(() => {
    vi.resetModules();
    vi.clearAllMocks();
    vi.doUnmock("../../lib/db/pool-manager.js");
  });

  afterEach(() => {
    vi.resetModules();
    vi.clearAllMocks();
    vi.doUnmock("../../lib/db/pool-manager.js");
  });

  it("initializes and tears down a standalone pool when none exists", async () => {
    const healthCheck = vi.fn().mockResolvedValue(undefined);
    const initPool = vi.fn();
    const destroyPool = vi.fn().mockResolvedValue(undefined);
    const isPoolInitialised = vi
      .fn()
      .mockReturnValueOnce(false)
      .mockReturnValueOnce(true);

    vi.doMock("../../lib/db/pool-manager.js", async () => {
      const actual = await vi.importActual<typeof import("../../lib/db/pool-manager.js")>("../../lib/db/pool-manager.js");
      return {
        ...actual,
        healthCheck,
        initPool,
        destroyPool,
        isPoolInitialised,
        getPool: vi.fn(),
      };
    });

    const { Doctor } = await import("../../orchestrator/doctor.js");
    const doctor = new Doctor({} as never, "/tmp/project");

    const result = await doctor.checkPostgresConnectivity();

    expect(result).toEqual({
      name: "postgres connectivity",
      status: "pass",
      message: "Postgres connection is healthy",
    });
    expect(initPool).toHaveBeenCalledTimes(1);
    expect(healthCheck).toHaveBeenCalledTimes(1);
    expect(destroyPool).toHaveBeenCalledTimes(1);
  });

  it("reuses an existing pool without tearing it down", async () => {
    const healthCheck = vi.fn().mockResolvedValue(undefined);
    const initPool = vi.fn();
    const destroyPool = vi.fn().mockResolvedValue(undefined);
    const isPoolInitialised = vi.fn().mockReturnValue(true);

    vi.doMock("../../lib/db/pool-manager.js", async () => {
      const actual = await vi.importActual<typeof import("../../lib/db/pool-manager.js")>("../../lib/db/pool-manager.js");
      return {
        ...actual,
        healthCheck,
        initPool,
        destroyPool,
        isPoolInitialised,
        getPool: vi.fn(),
      };
    });

    const { Doctor } = await import("../../orchestrator/doctor.js");
    const doctor = new Doctor({} as never, "/tmp/project");

    const result = await doctor.checkPostgresConnectivity();

    expect(result.status).toBe("pass");
    expect(initPool).not.toHaveBeenCalled();
    expect(destroyPool).not.toHaveBeenCalled();
  });

  it("reports the actual connectivity error instead of pool initialization state", async () => {
    const healthCheck = vi.fn().mockRejectedValue(new Error("Health check failed: connect ECONNREFUSED 127.0.0.1:5432"));
    const initPool = vi.fn();
    const destroyPool = vi.fn().mockResolvedValue(undefined);
    const isPoolInitialised = vi
      .fn()
      .mockReturnValueOnce(false)
      .mockReturnValueOnce(true);

    vi.doMock("../../lib/db/pool-manager.js", async () => {
      const actual = await vi.importActual<typeof import("../../lib/db/pool-manager.js")>("../../lib/db/pool-manager.js");
      return {
        ...actual,
        healthCheck,
        initPool,
        destroyPool,
        isPoolInitialised,
        getPool: vi.fn(),
      };
    });

    const { Doctor } = await import("../../orchestrator/doctor.js");
    const doctor = new Doctor({} as never, "/tmp/project");

    const result = await doctor.checkPostgresConnectivity();

    expect(result.status).toBe("fail");
    expect(result.message).toContain("connect ECONNREFUSED 127.0.0.1:5432");
    expect(result.message).not.toContain("PoolManager not initialised");
    expect(initPool).toHaveBeenCalledTimes(1);
    expect(destroyPool).toHaveBeenCalledTimes(1);
  });
});
