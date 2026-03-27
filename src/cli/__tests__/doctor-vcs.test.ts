/**
 * TRD-028 & TRD-028-TEST: Doctor jj validation tests.
 *
 * Verifies:
 * - checkJjBinary(): detects jj in PATH / handles missing jj
 * - checkJjColocatedRepo(): validates colocated jj+git structure
 * - checkJjVersion(): validates minimum jj version requirements
 * - Correct severity (pass/warn/fail/skip) for each scenario
 */

import { describe, it, expect, vi, afterEach, beforeEach } from "vitest";
import {
  mkdtempSync,
  rmSync,
  realpathSync,
  mkdirSync,
} from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

// ── Hoisted mock ──────────────────────────────────────────────────────────

const { mockExecFile } = vi.hoisted(() => ({
  mockExecFile: vi.fn(),
}));

vi.mock("node:child_process", () => ({
  execFile: mockExecFile,
}));

// ── Helpers ────────────────────────────────────────────────────────────────

const tempDirs: string[] = [];

function makeTempDir(): string {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-doctor-vcs-")));
  tempDirs.push(dir);
  return dir;
}

afterEach(() => {
  vi.clearAllMocks();
  for (const dir of tempDirs) {
    rmSync(dir, { recursive: true, force: true });
  }
  tempDirs.length = 0;
});

/**
 * Configure mockExecFile to dispatch by command name.
 *
 * Uses the pattern from beads-client.test.ts: callback is always the last arg.
 * The callback receives (err, {stdout, stderr}) as per Node.js execFile contract
 * used by util.promisify.
 */
function setupExecFileMock(
  handlers: Record<string, string | null>,
): void {
  mockExecFile.mockImplementation(
    (...args: unknown[]) => {
      const cmd = args[0] as string;
      const callback = args[args.length - 1] as Function;
      const response = handlers[cmd];
      if (response !== undefined && response !== null) {
        callback(null, { stdout: response, stderr: "" });
      } else {
        const err = Object.assign(new Error(`Command not found: ${cmd}`), {
          code: "ENOENT",
        });
        callback(err, { stdout: "", stderr: "" });
      }
    },
  );
}

/**
 * Simulate all commands failing (jj and git not in PATH).
 */
function allCommandsMissing(): void {
  setupExecFileMock({});
}

/**
 * Create a Doctor instance with a temp project path.
 */
async function makeDoctor(projectPath: string) {
  const { Doctor } = await import("../../orchestrator/doctor.js");
  const { ForemanStore } = await import("../../lib/store.js");
  const store = new ForemanStore(join(projectPath, "test.db"));
  const doctor = new Doctor(store, projectPath);
  return { doctor, store };
}

// ── checkJjBinary() ───────────────────────────────────────────────────────

describe("TRD-028: Doctor.checkJjBinary()", () => {
  it("returns pass when jj is found in PATH", async () => {
    const tmp = makeTempDir();
    const { doctor, store } = await makeDoctor(tmp);

    setupExecFileMock({ jj: "jj 0.18.0", git: "git version 2.39.0" });

    const result = await doctor.checkJjBinary("jujutsu");
    expect(result.status).toBe("pass");
    expect(result.message).toContain("jj found");
    expect(result.message).toContain("0.18.0");

    store.close();
  });

  it("returns fail when jj not found and backend=jujutsu", async () => {
    const tmp = makeTempDir();
    const { doctor, store } = await makeDoctor(tmp);

    allCommandsMissing();

    const result = await doctor.checkJjBinary("jujutsu");
    expect(result.status).toBe("fail");
    expect(result.message).toContain("jj not found");
    expect(result.details).toBeDefined();
    expect(result.details).toContain("brew install jj");

    store.close();
  });

  it("returns warn when jj not found and backend=auto", async () => {
    const tmp = makeTempDir();
    const { doctor, store } = await makeDoctor(tmp);

    allCommandsMissing();

    const result = await doctor.checkJjBinary("auto");
    expect(result.status).toBe("warn");
    expect(result.message).toContain("jj not found");
    expect(result.details).toContain("brew install jj");

    store.close();
  });

  it("returns skip when backend=git (jj not required)", async () => {
    const tmp = makeTempDir();
    const { doctor, store } = await makeDoctor(tmp);

    allCommandsMissing();

    const result = await doctor.checkJjBinary("git");
    expect(result.status).toBe("skip");
    expect(result.message).toContain("not required");

    store.close();
  });

  it("returns skip when vcsBackend is undefined (git-only project)", async () => {
    const tmp = makeTempDir();
    const { doctor, store } = await makeDoctor(tmp);

    allCommandsMissing();

    const result = await doctor.checkJjBinary(undefined);
    expect(result.status).toBe("skip");

    store.close();
  });

  it("details contain installation URL when jj is missing with jujutsu backend", async () => {
    const tmp = makeTempDir();
    const { doctor, store } = await makeDoctor(tmp);

    allCommandsMissing();

    const result = await doctor.checkJjBinary("jujutsu");
    expect(result.details).toContain("https://martinvonz.github.io/jj");

    store.close();
  });

  it("details contain installation URL when jj is missing with auto backend", async () => {
    const tmp = makeTempDir();
    const { doctor, store } = await makeDoctor(tmp);

    allCommandsMissing();

    const result = await doctor.checkJjBinary("auto");
    expect(result.details).toContain("https://martinvonz.github.io/jj");

    store.close();
  });
});

// ── checkJjColocatedRepo() ─────────────────────────────────────────────────

describe("TRD-028: Doctor.checkJjColocatedRepo()", () => {
  it("returns skip when .jj directory does not exist", async () => {
    const tmp = makeTempDir();
    const { doctor, store } = await makeDoctor(tmp);

    // No .jj dir — plain git project
    const result = await doctor.checkJjColocatedRepo();
    expect(result.status).toBe("skip");
    expect(result.message).toContain("Not a Jujutsu repository");

    store.close();
  });

  it("returns fail when .jj exists but .git is missing (bare jj repo)", async () => {
    const tmp = makeTempDir();
    mkdirSync(join(tmp, ".jj"), { recursive: true });
    // No .git directory

    const { doctor, store } = await makeDoctor(tmp);
    const result = await doctor.checkJjColocatedRepo();
    expect(result.status).toBe("fail");
    expect(result.message).toContain("Non-colocated");
    expect(result.details).toContain("jj git init --colocate");

    store.close();
  });

  it("returns warn when .jj and .git exist but .jj/repo/store/git is missing", async () => {
    const tmp = makeTempDir();
    mkdirSync(join(tmp, ".jj"), { recursive: true });
    mkdirSync(join(tmp, ".git"), { recursive: true });
    // .jj/repo/store/git NOT created

    const { doctor, store } = await makeDoctor(tmp);
    const result = await doctor.checkJjColocatedRepo();
    expect(result.status).toBe("warn");
    expect(result.message).toContain("may not be in colocated mode");

    store.close();
  });

  it("returns pass when full colocated structure exists", async () => {
    const tmp = makeTempDir();
    mkdirSync(join(tmp, ".jj", "repo", "store", "git"), { recursive: true });
    mkdirSync(join(tmp, ".git"), { recursive: true });

    const { doctor, store } = await makeDoctor(tmp);
    const result = await doctor.checkJjColocatedRepo();
    expect(result.status).toBe("pass");
    expect(result.message).toContain("Colocated");

    store.close();
  });
});

// ── checkJjVersion() ──────────────────────────────────────────────────────

describe("TRD-028: Doctor.checkJjVersion()", () => {
  it("returns skip when jj binary is not found", async () => {
    const tmp = makeTempDir();
    const { doctor, store } = await makeDoctor(tmp);

    allCommandsMissing();

    const result = await doctor.checkJjVersion("0.16.0");
    expect(result.status).toBe("skip");

    store.close();
  });

  it("returns pass when jj version meets minimum requirement", async () => {
    const tmp = makeTempDir();
    const { doctor, store } = await makeDoctor(tmp);

    setupExecFileMock({ jj: "jj 0.18.0" });

    const result = await doctor.checkJjVersion("0.16.0");
    expect(result.status).toBe("pass");
    expect(result.message).toContain("meets minimum");

    store.close();
  });

  it("returns fail when jj version is below minimum", async () => {
    const tmp = makeTempDir();
    const { doctor, store } = await makeDoctor(tmp);

    setupExecFileMock({ jj: "jj 0.14.0" });

    const result = await doctor.checkJjVersion("0.16.0");
    expect(result.status).toBe("fail");
    expect(result.message).toContain("below minimum");
    expect(result.details).toContain("Upgrade jj");

    store.close();
  });

  it("returns pass with no minimum when version is found", async () => {
    const tmp = makeTempDir();
    const { doctor, store } = await makeDoctor(tmp);

    setupExecFileMock({ jj: "jj 0.18.0" });

    const result = await doctor.checkJjVersion();
    expect(result.status).toBe("pass");
    expect(result.message).toContain("no minimum required");

    store.close();
  });

  it("returns pass for exact version match", async () => {
    const tmp = makeTempDir();
    const { doctor, store } = await makeDoctor(tmp);

    setupExecFileMock({ jj: "jj 0.16.0" });

    const result = await doctor.checkJjVersion("0.16.0");
    expect(result.status).toBe("pass");

    store.close();
  });

  it("returns warn when version format cannot be parsed", async () => {
    const tmp = makeTempDir();
    const { doctor, store } = await makeDoctor(tmp);

    setupExecFileMock({ jj: "jj dev-build-abc123" });

    const result = await doctor.checkJjVersion("0.16.0");
    expect(result.status).toBe("warn");
    expect(result.message).toContain("Could not parse");

    store.close();
  });
});

// ── Naming conventions ─────────────────────────────────────────────────────

describe("TRD-028: Doctor jj check naming conventions", () => {
  it("all jj check results have names containing 'jj'", async () => {
    const tmp = makeTempDir();
    const { doctor, store } = await makeDoctor(tmp);

    allCommandsMissing();

    const [binary, coloc, version] = await Promise.all([
      doctor.checkJjBinary("auto"),
      doctor.checkJjColocatedRepo(),
      doctor.checkJjVersion(),
    ]);

    expect(binary.name.toLowerCase()).toContain("jj");
    expect(coloc.name.toLowerCase()).toContain("jj");
    expect(version.name.toLowerCase()).toContain("jj");

    store.close();
  });
});
