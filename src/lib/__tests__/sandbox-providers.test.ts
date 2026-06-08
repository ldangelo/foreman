import { describe, it, expect, vi, beforeEach } from "vitest";
import { promisify } from "node:util";

const { mockExecFile } = vi.hoisted(() => {
  const mockExecFile = vi.fn();
  Object.assign(mockExecFile, {
    [Symbol.for("nodejs.util.promisify.custom")]: vi.fn(async (_cmd: string, args: string[]) => ({
      stdout: args[0] === "run" ? "0123456789abcdef\n" : "ok\n",
      stderr: "",
    })),
  });
  return { mockExecFile };
});

vi.mock("node:child_process", () => ({
  execFile: mockExecFile,
  execFileSync: vi.fn(),
}));

import {
  DockerSandboxProvider,
  PodmanSandboxProvider,
  SandboxProviderFactory,
} from "../sandbox-providers/index.js";
import type { SandboxProviderConfig } from "../sandbox-provider.js";

function promisifiedExecFileMock() {
  return vi.mocked(((mockExecFile as unknown) as Record<symbol, unknown>)[promisify.custom] as ReturnType<typeof vi.fn>);
}

beforeEach(() => {
  mockExecFile.mockReset();
  mockExecFile.mockImplementation((_cmd, args, _opts, cb) => {
    cb(null, args[0] === "run" ? "0123456789abcdef\n" : "ok\n", "");
  });
  promisifiedExecFileMock().mockClear();
});

describe("DockerSandboxProvider", () => {
  it("has name 'docker'", () => {
    const provider = new DockerSandboxProvider();
    expect(provider.name).toBe("docker");
  });

  it("can be instantiated without errors", () => {
    expect(() => new DockerSandboxProvider()).not.toThrow();
  });

  it("disables networking by default", async () => {
    const provider = new DockerSandboxProvider();
    await provider.createSandbox("/tmp/worktree", "ubuntu:22.04");

    const args = promisifiedExecFileMock().mock.calls[0]?.[1] as string[];
    expect(args).toContain("--network");
    expect(args).toContain("none");
  });

  it("allows networking only when explicitly enabled", async () => {
    const provider = new DockerSandboxProvider();
    await provider.createSandbox("/tmp/worktree", "ubuntu:22.04", { network: true });

    const args = promisifiedExecFileMock().mock.calls[0]?.[1] as string[];
    expect(args).not.toContain("--network");
  });
});

describe("PodmanSandboxProvider", () => {
  it("has name 'podman'", () => {
    const provider = new PodmanSandboxProvider();
    expect(provider.name).toBe("podman");
  });

  it("can be instantiated without errors", () => {
    expect(() => new PodmanSandboxProvider()).not.toThrow();
  });

  it("disables networking by default", async () => {
    const provider = new PodmanSandboxProvider();
    await provider.createSandbox("/tmp/worktree", "ubuntu:22.04");

    const args = promisifiedExecFileMock().mock.calls[0]?.[1] as string[];
    expect(args).toContain("--network");
    expect(args).toContain("none");
  });
});

describe("SandboxProviderFactory", () => {
  describe("create", () => {
    it("creates DockerSandboxProvider when backend is docker", async () => {
      const provider = await SandboxProviderFactory.create({ backend: "docker" });
      expect(provider.name).toBe("docker");
    });

    it("creates PodmanSandboxProvider when backend is podman", async () => {
      const provider = await SandboxProviderFactory.create({ backend: "podman" });
      expect(provider.name).toBe("podman");
    });
  });

  describe("resolveBackend", () => {
    it("returns docker when backend is explicitly docker", () => {
      const result = SandboxProviderFactory.resolveBackend({ backend: "docker" });
      expect(result).toBe("docker");
    });

    it("returns podman when backend is explicitly podman", () => {
      const result = SandboxProviderFactory.resolveBackend({ backend: "podman" });
      expect(result).toBe("podman");
    });
  });
});

describe("SandboxProviderConfig type", () => {
  it("accepts valid docker backend", () => {
    const config: SandboxProviderConfig = {
      backend: "docker",
      image: "ubuntu:22.04",
      network: false,
    };
    expect(config.backend).toBe("docker");
    expect(config.image).toBe("ubuntu:22.04");
    expect(config.network).toBe(false);
  });

  it("accepts valid podman backend", () => {
    const config: SandboxProviderConfig = {
      backend: "podman",
      image: "fedora:38",
    };
    expect(config.backend).toBe("podman");
  });

  it("accepts auto backend", () => {
    const config: SandboxProviderConfig = {
      backend: "auto",
    };
    expect(config.backend).toBe("auto");
  });

  it("accepts resource limits", () => {
    const config: SandboxProviderConfig = {
      backend: "docker",
      limits: {
        cpu: "2",
        memory: "4g",
        cpuset: "0-1",
        memorySwap: "6g",
      },
    };
    expect(config.limits).toEqual({
      cpu: "2",
      memory: "4g",
      cpuset: "0-1",
      memorySwap: "6g",
    });
  });

  it("accepts resource limits with capabilities", () => {
    const config: SandboxProviderConfig = {
      backend: "docker",
      limits: {
        cpu: "2",
        memory: "4g",
        capabilities: ["NET_ADMIN", "SYS_PTRACE"],
      },
    };
    expect(config.limits?.capabilities).toEqual(["NET_ADMIN", "SYS_PTRACE"]);
  });

  it("accepts empty capabilities array", () => {
    const config: SandboxProviderConfig = {
      backend: "podman",
      limits: {
        capabilities: [],
      },
    };
    expect(config.limits?.capabilities).toEqual([]);
  });

  it("accepts cleanup policy", () => {
    const config: SandboxProviderConfig = {
      backend: "docker",
      cleanup: "keep",
    };
    expect(config.cleanup).toBe("keep");
  });
});