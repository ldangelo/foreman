import { describe, it, expect, vi, beforeEach } from "vitest";
import { promisify } from "node:util";

const { mockExecFile, mockExecFileSync } = vi.hoisted(() => {
  const mockExecFile = vi.fn();
  const mockExecFileSync = vi.fn();
  Object.assign(mockExecFile, {
    [Symbol.for("nodejs.util.promisify.custom")]: vi.fn(async (_cmd: string, args: string[]) => ({
      stdout: args[0] === "run" ? "0123456789abcdef\n" : "ok\n",
      stderr: "",
    })),
  });
  return { mockExecFile, mockExecFileSync };
});

vi.mock("node:child_process", () => ({
  execFile: mockExecFile,
  execFileSync: mockExecFileSync,
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
  mockExecFileSync.mockReset();
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

  it("passes mounts, ports, user, cleanup, and resource limits to docker run", async () => {
    const provider = new DockerSandboxProvider();
    await provider.createSandbox("/tmp/worktree", "ubuntu:22.04", {
      mounts: [{ source: "/cache", destination: "/cache", readOnly: true }],
      ports: [{ host: 8080, container: 80, protocol: "tcp" }],
      user: "1000:1000",
      cleanup: "keep",
      limits: { cpu: "1", memory: "512m", cpuset: "0", memorySwap: "1g", capabilities: ["SYS_PTRACE"] },
    });

    const args = promisifiedExecFileMock().mock.calls[0]?.[1] as string[];
    expect(args).toEqual(expect.arrayContaining([
      "--cpus", "1",
      "--memory", "512m",
      "--cpuset-cpus", "0",
      "--memory-swap", "1g",
      "--cap-add", "SYS_PTRACE",
      "-v", "/cache:/cache:ro",
      "-p", "8080:80/tcp",
      "--user", "1000:1000",
    ]));
    expect(args).not.toContain("--rm");
  });

  it("passes cwd, env, and timeout to docker exec", async () => {
    const provider = new DockerSandboxProvider();
    const result = await provider.runInSandbox("sandbox-1", ["npm", "test"], {
      cwd: "/workspace/app",
      env: { NODE_ENV: "test" },
      timeoutMs: 12_000,
    });

    const [, args, options] = promisifiedExecFileMock().mock.calls[0] as [string, string[], { timeout?: number }];
    expect(args).toEqual(expect.arrayContaining(["exec", "-w", "/workspace/app", "-e", "NODE_ENV=test", "sandbox-1", "npm", "test"]));
    expect(options.timeout).toBe(12_000);
    expect(result.stdout).toBe("ok");
  });

  it("removes docker sandbox on destroy", async () => {
    const provider = new DockerSandboxProvider();
    await provider.destroySandbox("sandbox-1");

    expect(promisifiedExecFileMock()).toHaveBeenCalledWith("docker", ["rm", "-f", "sandbox-1"], expect.any(Object));
  });

  it("reads docker sandbox info and lists sandboxes", async () => {
    promisifiedExecFileMock()
      .mockResolvedValueOnce({ stdout: "abc|running|2026-01-01|ubuntu:22.04", stderr: "" })
      .mockResolvedValueOnce({ stdout: "abc\ndef\n", stderr: "" });
    const provider = new DockerSandboxProvider();

    await expect(provider.getSandboxInfo("sandbox-1")).resolves.toEqual({ id: "abc", status: "running", created: "2026-01-01", image: "ubuntu:22.04" });
    await expect(provider.listSandboxes()).resolves.toEqual(["abc", "def"]);
  });

  it("propagates docker exec numeric exit codes", async () => {
    promisifiedExecFileMock().mockRejectedValueOnce({ code: 42, stdout: "", stderr: "failed" });
    const provider = new DockerSandboxProvider();

    const result = await provider.runInSandbox("sandbox-1", ["false"]);

    expect(result.exitCode).toBe(42);
    expect(result.stderr).toBe("failed");
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

  it("allows networking only when explicitly enabled", async () => {
    const provider = new PodmanSandboxProvider();
    await provider.createSandbox("/tmp/worktree", "ubuntu:22.04", { network: true });

    const args = promisifiedExecFileMock().mock.calls[0]?.[1] as string[];
    expect(args).not.toContain("--network");
    expect(args).not.toContain("none");
  });

  it("passes mounts, ports, user, cleanup, and resource limits to podman run", async () => {
    const provider = new PodmanSandboxProvider();
    await provider.createSandbox("/tmp/worktree", "ubuntu:22.04", {
      mounts: [{ source: "/cache", destination: "/cache", readOnly: true }],
      ports: [{ host: 8080, container: 80, protocol: "tcp" }],
      user: "1000:1000",
      cleanup: "keep",
      limits: { cpu: "1", memory: "512m", cpuset: "0", memorySwap: "1g", capabilities: ["SYS_PTRACE"] },
    });

    const args = promisifiedExecFileMock().mock.calls[0]?.[1] as string[];
    expect(args).toEqual(expect.arrayContaining([
      "--cpus", "1",
      "--memory", "512m",
      "--cpuset-cpus", "0",
      "--memory-swap", "1g",
      "--cap-add", "SYS_PTRACE",
      "-v", "/cache:/cache:ro",
      "-p", "8080:80/tcp",
      "--user", "1000:1000",
    ]));
    expect(args).not.toContain("--rm");
  });

  it("reports podman availability", async () => {
    const provider = new PodmanSandboxProvider();
    await expect(provider.isAvailable()).resolves.toBe(true);
    expect(promisifiedExecFileMock()).toHaveBeenCalledWith("podman", ["version"], expect.any(Object));
  });

  it("propagates podman exec numeric string exit codes", async () => {
    promisifiedExecFileMock().mockRejectedValueOnce({ code: "7", stdout: "", stderr: "failed" });
    const provider = new PodmanSandboxProvider();

    const result = await provider.runInSandbox("sandbox-1", ["false"]);

    expect(result.exitCode).toBe(7);
    expect(result.stderr).toBe("failed");
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

    it("detects provider availability", async () => {
      const result = await SandboxProviderFactory.detectAvailable();
      expect(result).toEqual({ docker: true, podman: true });
    });

    it("probes container CLIs with a timeout when backend is auto", () => {
      const prevDockerHost = process.env.DOCKER_HOST;
      process.env.DOCKER_HOST = "unix:///var/run/docker.sock";
      mockExecFileSync
        .mockImplementationOnce(() => { throw new Error("docker unavailable"); })
        .mockImplementationOnce(() => { throw new Error("docker unavailable"); })
        .mockImplementationOnce(() => "podman ok");

      try {
        const result = SandboxProviderFactory.resolveBackend({ backend: "auto" });

        expect(result).toBe("podman");
        expect(mockExecFileSync).toHaveBeenCalledWith("docker", ["version"], expect.objectContaining({ timeout: 2_000 }));
        expect(mockExecFileSync).toHaveBeenCalledWith("podman", ["version"], expect.objectContaining({ timeout: 2_000 }));
      } finally {
        if (prevDockerHost === undefined) delete process.env.DOCKER_HOST;
        else process.env.DOCKER_HOST = prevDockerHost;
      }
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