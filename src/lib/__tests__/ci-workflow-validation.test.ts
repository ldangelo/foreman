/**
 * CI Workflow Validation Tests
 *
 * Verifies that the GitHub Actions CI workflow (.github/workflows/ci.yml):
 *   1. Has valid YAML syntax (parseable)
 *   2. Contains the required structural elements (triggers, jobs, steps)
 *   3. Includes type checking via `tsc --noEmit`
 *   4. Includes test execution via `npm test`
 *   5. Confirms that tsc --noEmit fails on deliberate type errors
 *   6. Confirms that npm test fails on deliberate test failures
 *
 * These tests serve as a CI health-check that can run in CI itself,
 * providing fast feedback without needing a live GitHub Actions runner.
 */

import { describe, it, expect } from "vitest";
import { load as yamlLoad } from "js-yaml";
import { readFileSync, writeFileSync, mkdirSync, rmSync } from "node:fs";
import { resolve, join } from "node:path";
import { execFileSync, spawnSync } from "node:child_process";
import { tmpdir } from "node:os";

// ── Helpers ──────────────────────────────────────────────────────────────────

const ROOT = resolve(import.meta.dirname, "../../..");
const CI_WORKFLOW_PATH = resolve(ROOT, ".github/workflows/ci.yml");

/**
 * Parse and return the CI workflow as a typed structure.
 */
interface CiWorkflow {
  name: string;
  on: Record<string, unknown>;
  jobs: Record<
    string,
    {
      name?: string;
      "runs-on": string;
      strategy?: { matrix?: Record<string, unknown> };
      steps: Array<{ name?: string; uses?: string; run?: string; if?: string; with?: Record<string, unknown> }>;
    }
  >;
}

function loadCiWorkflow(): CiWorkflow {
  const raw = readFileSync(CI_WORKFLOW_PATH, "utf-8");
  return yamlLoad(raw) as CiWorkflow;
}

// ── YAML Syntax ───────────────────────────────────────────────────────────────

describe("CI Workflow: YAML syntax", () => {
  it("ci.yml parses as valid YAML without throwing", () => {
    expect(() => loadCiWorkflow()).not.toThrow();
  });

  it("ci.yml contains a non-empty workflow object", () => {
    const workflow = loadCiWorkflow();
    expect(workflow).toBeTruthy();
    expect(typeof workflow).toBe("object");
  });
});

// ── Workflow Metadata ─────────────────────────────────────────────────────────

describe("CI Workflow: metadata and triggers", () => {
  it("has a workflow name", () => {
    const workflow = loadCiWorkflow();
    expect(typeof workflow.name).toBe("string");
    expect(workflow.name.length).toBeGreaterThan(0);
  });

  it("triggers on pull_request events", () => {
    const workflow = loadCiWorkflow();
    expect(workflow.on).toHaveProperty("pull_request");
  });

  it("targets the main branch", () => {
    const workflow = loadCiWorkflow();
    const pr = workflow.on["pull_request"] as { branches?: string[] };
    expect(pr.branches).toContain("main");
  });

  it("targets the dev branch", () => {
    const workflow = loadCiWorkflow();
    const pr = workflow.on["pull_request"] as { branches?: string[] };
    expect(pr.branches).toContain("dev");
  });
});

// ── Jobs & Runner ─────────────────────────────────────────────────────────────

describe("CI Workflow: jobs and runner configuration", () => {
  it("defines at least one job", () => {
    const workflow = loadCiWorkflow();
    expect(Object.keys(workflow.jobs).length).toBeGreaterThan(0);
  });

  it("uses ubuntu-latest runner", () => {
    const workflow = loadCiWorkflow();
    const jobs = Object.values(workflow.jobs);
    const hasUbuntu = jobs.some((j) => j["runs-on"] === "ubuntu-latest");
    expect(hasUbuntu).toBe(true);
  });

  it("specifies Node.js version in strategy matrix", () => {
    const workflow = loadCiWorkflow();
    const jobs = Object.values(workflow.jobs);
    const hasMatrix = jobs.some(
      (j) =>
        j.strategy?.matrix?.["node-version"] !== undefined &&
        Array.isArray(j.strategy.matrix["node-version"]) &&
        (j.strategy.matrix["node-version"] as string[]).length > 0
    );
    expect(hasMatrix).toBe(true);
  });

  it("includes Node 20 in the matrix", () => {
    const workflow = loadCiWorkflow();
    const jobs = Object.values(workflow.jobs);
    const hasNode20 = jobs.some((j) => {
      const versions = j.strategy?.matrix?.["node-version"] as string[] | undefined;
      return versions?.includes("20") || versions?.includes("20.x");
    });
    expect(hasNode20).toBe(true);
  });
});

// ── Required Steps ────────────────────────────────────────────────────────────

describe("CI Workflow: required steps", () => {
  function getAllSteps() {
    const workflow = loadCiWorkflow();
    return Object.values(workflow.jobs).flatMap((j) => j.steps ?? []);
  }

  it("includes a checkout step (actions/checkout)", () => {
    const steps = getAllSteps();
    const hasCheckout = steps.some((s) => s.uses?.startsWith("actions/checkout"));
    expect(hasCheckout).toBe(true);
  });

  it("includes a Node.js setup step (actions/setup-node)", () => {
    const steps = getAllSteps();
    const hasSetupNode = steps.some((s) => s.uses?.startsWith("actions/setup-node"));
    expect(hasSetupNode).toBe(true);
  });

  it("includes a dependency installation step (npm ci)", () => {
    const steps = getAllSteps();
    const hasNpmCi = steps.some((s) => s.run?.includes("npm ci"));
    expect(hasNpmCi).toBe(true);
  });

  it("includes a TypeScript type check step (tsc --noEmit)", () => {
    const steps = getAllSteps();
    const hasTsc = steps.some((s) => s.run?.includes("tsc") && s.run?.includes("--noEmit"));
    expect(hasTsc).toBe(true);
  });

  it("includes a test execution step (npm test)", () => {
    const steps = getAllSteps();
    const hasNpmTest = steps.some((s) => s.run?.includes("npm test"));
    expect(hasNpmTest).toBe(true);
  });

  it("type check step comes before test execution step", () => {
    const steps = getAllSteps();
    const tscIdx = steps.findIndex((s) => s.run?.includes("tsc") && s.run?.includes("--noEmit"));
    const testIdx = steps.findIndex((s) => s.run?.includes("npm test"));
    expect(tscIdx).toBeGreaterThanOrEqual(0);
    expect(testIdx).toBeGreaterThanOrEqual(0);
    expect(tscIdx).toBeLessThan(testIdx);
  });
});

// ── Actions Versions ──────────────────────────────────────────────────────────

describe("CI Workflow: action versions are pinned", () => {
  function getAllSteps() {
    const workflow = loadCiWorkflow();
    return Object.values(workflow.jobs).flatMap((j) => j.steps ?? []);
  }

  it("all action references include a version tag (@v...)", () => {
    const steps = getAllSteps();
    const actionSteps = steps.filter((s) => s.uses !== undefined);
    // Every action should have a version tag (e.g. @v4, @v3, @sha)
    const unpinned = actionSteps.filter((s) => !s.uses?.match(/@/));
    expect(unpinned).toHaveLength(0);
  });
});

// ── Type Error Detection ──────────────────────────────────────────────────────

describe("CI Workflow behaviour: tsc --noEmit fails on type errors", () => {
  it("tsc --noEmit exits 0 on clean codebase", () => {
    const result = spawnSync("npx", ["tsc", "--noEmit"], {
      cwd: ROOT,
      encoding: "utf-8",
      timeout: 90_000,
    });
    expect(result.status).toBe(0);
  }, 90_000);

  it("tsc --noEmit exits non-zero when a type error is introduced", () => {
    // Write a temporary TypeScript file with a deliberate type error
    const tmpDir = join(tmpdir(), `foreman-ci-test-${Date.now()}`);
    mkdirSync(tmpDir, { recursive: true });

    // Create a minimal tsconfig pointing only at our bad file
    const tsconfigPath = join(tmpDir, "tsconfig.json");
    const badFilePath = join(tmpDir, "bad.ts");

    writeFileSync(
      tsconfigPath,
      JSON.stringify({
        compilerOptions: {
          strict: true,
          target: "ES2022",
          module: "ESNext",
          moduleResolution: "bundler",
          noEmit: true,
        },
        include: ["bad.ts"],
      })
    );

    // Deliberate type error: assign a number to a string variable
    writeFileSync(badFilePath, 'const x: string = 42;\nconsole.log(x);\n');

    // Use the project-local tsc binary (avoids npx not finding tsc in tmp dir)
    const tscBin = resolve(ROOT, "node_modules/.bin/tsc");

    try {
      const result = spawnSync(tscBin, ["--noEmit", "--project", tsconfigPath], {
        cwd: tmpDir,
        encoding: "utf-8",
        timeout: 30_000,
      });

      // tsc should exit with non-zero status on type errors
      expect(result.status).not.toBe(0);

      // stdout should mention the type error (tsc writes diagnostics to stdout)
      const output = (result.stdout ?? "") + (result.stderr ?? "");
      const hasTypeError =
        output.includes("error TS") ||
        output.includes("Type '42' is not assignable") ||
        output.includes("Type 'number' is not assignable");
      expect(hasTypeError).toBe(true);
    } finally {
      rmSync(tmpDir, { recursive: true, force: true });
    }
  }, 30_000);
});

// ── Test Failure Detection ────────────────────────────────────────────────────

describe("CI Workflow behaviour: npm test fails on failing tests", () => {
  it("vitest exits non-zero when a test fails", () => {
    // Write a temporary test file with a deliberate assertion failure
    const tmpDir = join(tmpdir(), `foreman-ci-testfail-${Date.now()}`);
    mkdirSync(tmpDir, { recursive: true });

    // Create a minimal package.json + vitest config so vitest can run standalone
    writeFileSync(
      join(tmpDir, "package.json"),
      JSON.stringify({
        name: "ci-failure-test",
        type: "module",
        private: true,
        dependencies: {
          vitest: "*",
        },
      })
    );

    const failingTestPath = join(tmpDir, "failing.test.js");
    writeFileSync(
      failingTestPath,
      `
import { describe, it, expect } from 'vitest';
describe('deliberate failure', () => {
  it('always fails', () => {
    expect(1).toBe(2); // intentional failure
  });
});
`
    );

    // Find vitest binary in the main project's node_modules
    const vitestBin = resolve(ROOT, "node_modules/.bin/vitest");

    const result = spawnSync(
      vitestBin,
      ["run", failingTestPath],
      {
        cwd: tmpDir,
        encoding: "utf-8",
        timeout: 30_000,
        env: {
          ...process.env,
          // Prevent vitest from trying to use the main project's config
          VITEST_CONFIG: "false",
        },
      }
    );

    // vitest should exit with non-zero status when tests fail
    expect(result.status).not.toBe(0);

    rmSync(tmpDir, { recursive: true, force: true });
  }, 30_000);
});

// ── act Integration (optional, skipped if act not installed) ──────────────────

describe("CI Workflow: act integration (requires act binary)", () => {
  it("act can list the CI workflow job without errors", () => {
    // Find act binary
    let actPath: string;
    try {
      actPath = execFileSync("which", ["act"], { encoding: "utf-8" }).trim();
    } catch {
      // act not installed — skip test gracefully
      console.log("  ℹ act binary not found — skipping act integration test");
      return;
    }

    if (!actPath) {
      console.log("  ℹ act binary not found — skipping act integration test");
      return;
    }

    // `act --list` parses the workflow and lists jobs without executing them
    const result = spawnSync(actPath, ["--list"], {
      cwd: ROOT,
      encoding: "utf-8",
      timeout: 15_000,
    });

    // act --list should succeed (exit 0) and mention our CI job
    expect(result.status).toBe(0);
    const output = result.stdout + result.stderr;
    // Should list a job from ci.yml
    expect(output).toMatch(/ci\.yml/);
  }, 15_000);
});
