import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// We mock child_process at the module level
vi.mock("node:child_process", () => {
  const mockExecFile = vi.fn();
  return {
    execFile: mockExecFile,
  };
});

vi.mock("node:util", () => ({
  promisify: vi.fn((fn: unknown) => fn),
}));

// Import after mocking
const { execFile: mockExecFile } = await import("node:child_process");
const typedMock = mockExecFile as unknown as ReturnType<typeof vi.fn>;

// We need to dynamically import the module under test after mocks are set up
// Use resetModules to clear cached availability between tests
let TmuxClient: typeof import("../tmux.js").TmuxClient;
let tmuxSessionName: typeof import("../tmux.js").tmuxSessionName;

describe("tmuxSessionName", () => {
  beforeEach(async () => {
    vi.resetModules();
    // Re-apply mocks after resetModules
    vi.doMock("node:child_process", () => ({
      execFile: typedMock,
    }));
    vi.doMock("node:util", () => ({
      promisify: vi.fn((fn: unknown) => fn),
    }));
    const mod = await import("../tmux.js");
    tmuxSessionName = mod.tmuxSessionName;
    TmuxClient = mod.TmuxClient;
    typedMock.mockReset();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("formats seed ID with foreman- prefix", () => {
    expect(tmuxSessionName("abc123")).toBe("foreman-abc123");
  });

  it("replaces colons with hyphens", () => {
    expect(tmuxSessionName("seed:001")).toBe("foreman-seed-001");
  });

  it("replaces periods with hyphens", () => {
    expect(tmuxSessionName("seed.001")).toBe("foreman-seed-001");
  });

  it("replaces spaces with hyphens", () => {
    expect(tmuxSessionName("seed 001")).toBe("foreman-seed-001");
  });

  it("replaces multiple invalid characters", () => {
    expect(tmuxSessionName("seed:001.v2 beta")).toBe("foreman-seed-001-v2-beta");
  });

  it("returns foreman-unknown for empty string", () => {
    expect(tmuxSessionName("")).toBe("foreman-unknown");
  });

  it("returns foreman-unknown for whitespace-only string", () => {
    expect(tmuxSessionName("   ")).toBe("foreman-unknown");
  });
});

describe("TmuxClient", () => {
  let client: InstanceType<typeof TmuxClient>;
  const originalEnv = process.env;

  beforeEach(async () => {
    vi.resetModules();
    vi.doMock("node:child_process", () => ({
      execFile: typedMock,
    }));
    vi.doMock("node:util", () => ({
      promisify: vi.fn((fn: unknown) => fn),
    }));
    const mod = await import("../tmux.js");
    TmuxClient = mod.TmuxClient;
    tmuxSessionName = mod.tmuxSessionName;
    client = new TmuxClient();
    typedMock.mockReset();
    process.env = { ...originalEnv };
    delete process.env.FOREMAN_TMUX_DISABLED;
  });

  afterEach(() => {
    process.env = originalEnv;
    vi.restoreAllMocks();
  });

  describe("isAvailable", () => {
    it("returns true when tmux binary is found", async () => {
      typedMock.mockResolvedValueOnce({ stdout: "/usr/local/bin/tmux\n", stderr: "" });
      const result = await client.isAvailable();
      expect(result).toBe(true);
    });

    it("returns false when tmux binary is not found", async () => {
      typedMock.mockRejectedValueOnce(new Error("not found"));
      const result = await client.isAvailable();
      expect(result).toBe(false);
    });

    it("returns false when FOREMAN_TMUX_DISABLED=true", async () => {
      process.env.FOREMAN_TMUX_DISABLED = "true";
      // Need a fresh client to pick up env var
      vi.resetModules();
      vi.doMock("node:child_process", () => ({
        execFile: typedMock,
      }));
      vi.doMock("node:util", () => ({
        promisify: vi.fn((fn: unknown) => fn),
      }));
      const mod = await import("../tmux.js");
      const freshClient = new mod.TmuxClient();
      const result = await freshClient.isAvailable();
      expect(result).toBe(false);
      // Should not have called execFile at all
      expect(typedMock).not.toHaveBeenCalled();
    });

    it("caches the result after first call", async () => {
      typedMock.mockResolvedValueOnce({ stdout: "/usr/local/bin/tmux\n", stderr: "" });
      await client.isAvailable();
      await client.isAvailable();
      await client.isAvailable();
      // execFile should only be called once due to caching
      expect(typedMock).toHaveBeenCalledTimes(1);
    });

    it("does not throw on non-zero exit codes", async () => {
      const err = new Error("exit code 1") as Error & { code: number };
      err.code = 1;
      typedMock.mockRejectedValueOnce(err);
      const result = await client.isAvailable();
      expect(result).toBe(false);
    });
  });

  describe("createSession", () => {
    it("creates a tmux session and returns success", async () => {
      typedMock.mockResolvedValueOnce({ stdout: "", stderr: "" });

      const result = await client.createSession({
        sessionName: "foreman-abc1",
        command: "tsx agent-worker.ts config.json > out.log 2> err.log",
        cwd: "/tmp/worktree",
      });

      expect(result).toEqual({ sessionName: "foreman-abc1", created: true });
      // Verify the tmux command was called correctly
      const createCall = typedMock.mock.calls[0];
      expect(createCall[0]).toBe("tmux");
      expect(createCall[1]).toContain("new-session");
      expect(createCall[1]).toContain("-d");
      expect(createCall[1]).toContain("-s");
      expect(createCall[1]).toContain("foreman-abc1");
    });

    it("returns created: false on failure", async () => {
      typedMock.mockRejectedValueOnce(new Error("tmux failed"));

      const stderrSpy = vi.spyOn(process.stderr, "write").mockImplementation(() => true);

      const result = await client.createSession({
        sessionName: "foreman-abc1",
        command: "tsx agent-worker.ts",
        cwd: "/tmp",
      });

      expect(result).toEqual({ sessionName: "foreman-abc1", created: false });
      expect(stderrSpy).toHaveBeenCalled();
      stderrSpy.mockRestore();
    });

    it("includes cwd in the tmux command", async () => {
      typedMock.mockResolvedValueOnce({ stdout: "", stderr: "" });

      await client.createSession({
        sessionName: "foreman-test",
        command: "echo hello",
        cwd: "/home/user/project",
      });

      const createCall = typedMock.mock.calls[0];
      expect(createCall[1]).toContain("-c");
      expect(createCall[1]).toContain("/home/user/project");
    });

    it("passes environment variables when provided", async () => {
      typedMock.mockResolvedValueOnce({ stdout: "", stderr: "" });

      await client.createSession({
        sessionName: "foreman-env",
        command: "echo hello",
        cwd: "/tmp",
        env: { NODE_ENV: "test", FOO: "bar" },
      });

      const createCall = typedMock.mock.calls[0];
      const opts = createCall[2];
      expect(opts.env).toBeDefined();
      expect(opts.env.NODE_ENV).toBe("test");
      expect(opts.env.FOO).toBe("bar");
    });
  });

  describe("killSession", () => {
    it("returns true when session is killed", async () => {
      typedMock.mockResolvedValueOnce({ stdout: "", stderr: "" });
      const result = await client.killSession("foreman-abc1");
      expect(result).toBe(true);
      expect(typedMock).toHaveBeenCalledWith(
        "tmux",
        ["kill-session", "-t", "foreman-abc1"],
        expect.objectContaining({ timeout: 5000 }),
      );
    });

    it("returns false when session does not exist", async () => {
      typedMock.mockRejectedValueOnce(new Error("session not found"));
      const result = await client.killSession("foreman-nonexistent");
      expect(result).toBe(false);
    });

    it("does not throw on failure", async () => {
      typedMock.mockRejectedValueOnce(new Error("tmux error"));
      await expect(client.killSession("foreman-test")).resolves.toBe(false);
    });
  });

  describe("hasSession", () => {
    it("returns true when session exists", async () => {
      typedMock.mockResolvedValueOnce({ stdout: "", stderr: "" });
      const result = await client.hasSession("foreman-abc1");
      expect(result).toBe(true);
      expect(typedMock).toHaveBeenCalledWith(
        "tmux",
        ["has-session", "-t", "foreman-abc1"],
        expect.objectContaining({ timeout: 5000 }),
      );
    });

    it("returns false when session does not exist", async () => {
      typedMock.mockRejectedValueOnce(new Error("session not found"));
      const result = await client.hasSession("foreman-nonexistent");
      expect(result).toBe(false);
    });
  });

  describe("capturePaneOutput", () => {
    it("returns stdout split into lines", async () => {
      typedMock.mockResolvedValueOnce({
        stdout: "line 1\nline 2\nline 3\n",
        stderr: "",
      });
      const result = await client.capturePaneOutput("foreman-abc1");
      expect(result).toEqual(["line 1", "line 2", "line 3"]);
      expect(typedMock).toHaveBeenCalledWith(
        "tmux",
        ["capture-pane", "-t", "foreman-abc1", "-p"],
        expect.objectContaining({ timeout: 5000 }),
      );
    });

    it("returns empty array when session does not exist", async () => {
      typedMock.mockRejectedValueOnce(new Error("session not found"));
      const result = await client.capturePaneOutput("foreman-nonexistent");
      expect(result).toEqual([]);
    });

    it("handles empty output", async () => {
      typedMock.mockResolvedValueOnce({ stdout: "", stderr: "" });
      const result = await client.capturePaneOutput("foreman-empty");
      expect(result).toEqual([]);
    });
  });

  describe("listForemanSessions", () => {
    it("returns parsed and filtered session info", async () => {
      const output = [
        "foreman-abc1 1710000000 0 1",
        "foreman-def2 1710000100 1 3",
        "other-session 1710000200 0 1",
      ].join("\n");

      typedMock.mockResolvedValueOnce({ stdout: output, stderr: "" });

      const result = await client.listForemanSessions();
      expect(result).toHaveLength(2);
      expect(result[0]).toEqual({
        sessionName: "foreman-abc1",
        created: "1710000000",
        attached: false,
        windowCount: 1,
      });
      expect(result[1]).toEqual({
        sessionName: "foreman-def2",
        created: "1710000100",
        attached: true,
        windowCount: 3,
      });
    });

    it("returns empty array when tmux is unavailable", async () => {
      typedMock.mockRejectedValueOnce(new Error("tmux not found"));
      const result = await client.listForemanSessions();
      expect(result).toEqual([]);
    });

    it("returns empty array when no sessions exist", async () => {
      typedMock.mockResolvedValueOnce({ stdout: "", stderr: "" });
      const result = await client.listForemanSessions();
      expect(result).toEqual([]);
    });

    it("returns empty array when no foreman sessions exist", async () => {
      typedMock.mockResolvedValueOnce({
        stdout: "other-session 1710000000 0 1\n",
        stderr: "",
      });
      const result = await client.listForemanSessions();
      expect(result).toEqual([]);
    });
  });

  describe("getTmuxVersion", () => {
    it("parses version from tmux -V output", async () => {
      typedMock.mockResolvedValueOnce({ stdout: "tmux 3.4\n", stderr: "" });
      const result = await client.getTmuxVersion();
      expect(result).toBe("3.4");
    });

    it("parses version with letter suffix", async () => {
      typedMock.mockResolvedValueOnce({ stdout: "tmux 3.3a\n", stderr: "" });
      const result = await client.getTmuxVersion();
      expect(result).toBe("3.3a");
    });

    it("returns null when tmux is unavailable", async () => {
      typedMock.mockRejectedValueOnce(new Error("tmux not found"));
      const result = await client.getTmuxVersion();
      expect(result).toBeNull();
    });

    it("returns null when output format is unexpected", async () => {
      typedMock.mockResolvedValueOnce({ stdout: "unexpected output\n", stderr: "" });
      const result = await client.getTmuxVersion();
      expect(result).toBeNull();
    });
  });
});
