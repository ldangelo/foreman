/**
 * Tests for src/lib/project-config.ts
 *
 * Covers:
 *   AC-T-025-1: Load project VCS config from .foreman/config.yaml
 *   AC-T-025-2: Resolve VCS config (workflow > project > auto)
 *   AC-T-025-3: Handle missing config gracefully (return null)
 */
import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { mkdirSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  loadProjectConfig,
  resolveDefaultBranch,
  resolveVcsConfig,
  ProjectConfigError,
  type ProjectConfig,
} from "../project-config.js";

// ── Helpers ────────────────────────────────────────────────────────────────────

function mkTmpDir(): string {
  const dir = join(
    tmpdir(),
    `foreman-pc-test-${Date.now()}-${Math.random().toString(36).slice(2)}`,
  );
  mkdirSync(dir, { recursive: true });
  return dir;
}

function writeForemanConfig(
  foremanHome: string,
  content: string,
  ext: "yaml" | "json" = "yaml",
): void {
  mkdirSync(foremanHome, { recursive: true });
  writeFileSync(join(foremanHome, `config.${ext}`), content, "utf-8");
}

// ── loadProjectConfig ─────────────────────────────────────────────────────────

describe("loadProjectConfig", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkTmpDir();
    process.env["FOREMAN_HOME"] = tmpDir;
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
    delete process.env["FOREMAN_HOME"];
  });

  // AC-T-025-3: Missing config → null (not an error)
  it("returns null when ~/.foreman/config.yaml does not exist", () => {
    const result = loadProjectConfig(tmpDir);
    expect(result).toBeNull();
  });

  it("returns null when ~/.foreman/ directory does not exist", () => {
    const result = loadProjectConfig(tmpDir);
    expect(result).toBeNull();
  });

  // AC-T-025-1: Valid YAML configs
  it("loads vcs.backend='git' from config.yaml", () => {
    writeForemanConfig(tmpDir, "vcs:\n  backend: git");
    const cfg = loadProjectConfig(tmpDir);
    expect(cfg).not.toBeNull();
    expect(cfg!.vcs?.backend).toBe("git");
  });

  it("loads vcs.backend='jujutsu' from config.yaml", () => {
    writeForemanConfig(tmpDir, "vcs:\n  backend: jujutsu");
    const cfg = loadProjectConfig(tmpDir);
    expect(cfg!.vcs?.backend).toBe("jujutsu");
  });

  it("loads vcs.backend='auto' from config.yaml", () => {
    writeForemanConfig(tmpDir, "vcs:\n  backend: auto");
    const cfg = loadProjectConfig(tmpDir);
    expect(cfg!.vcs?.backend).toBe("auto");
  });

  it("loads vcs.git.useTown sub-option", () => {
    writeForemanConfig(
      tmpDir,
      "vcs:\n  backend: git\n  git:\n    useTown: false",
    );
    const cfg = loadProjectConfig(tmpDir);
    expect(cfg!.vcs?.git?.useTown).toBe(false);
  });

  it("loads vcs.jujutsu.minVersion sub-option", () => {
    writeForemanConfig(
      tmpDir,
      "vcs:\n  backend: jujutsu\n  jujutsu:\n    minVersion: '0.21.0'",
    );
    const cfg = loadProjectConfig(tmpDir);
    expect(cfg!.vcs?.jujutsu?.minVersion).toBe("0.21.0");
  });

  it("returns empty object when config.yaml has no 'vcs' key", () => {
    writeForemanConfig(tmpDir, "# empty config\n");
    const cfg = loadProjectConfig(tmpDir);
    // File exists but no vcs block → vcs is undefined
    expect(cfg).not.toBeNull();
    expect(cfg!.vcs).toBeUndefined();
  });

  it("treats vcs block without 'backend' key as backend: auto", () => {
    writeForemanConfig(tmpDir, "vcs:\n  git:\n    useTown: true");
    const cfg = loadProjectConfig(tmpDir);
    expect(cfg!.vcs?.backend).toBe("auto");
    expect(cfg!.vcs?.git?.useTown).toBe(true);
  });

  it("loads top-level defaultBranch from config.yaml", () => {
    writeForemanConfig(tmpDir, "defaultBranch: dev\nvcs:\n  backend: jujutsu");
    const cfg = loadProjectConfig(tmpDir);
    expect(cfg!.defaultBranch).toBe("dev");
  });

  it("loads positive concurrency limits", () => {
    writeForemanConfig(
      tmpDir,
      "concurrency:\n  global: 3\n  byState:\n    ready: 2\n    review: 1",
    );
    const cfg = loadProjectConfig(tmpDir);
    expect(cfg!.concurrency).toEqual({
      global: 3,
      byState: { ready: 2, review: 1 },
    });
  });

  it("requires non-empty GitHub API URL", () => {
    writeForemanConfig(
      tmpDir,
      "issueTracker:\n  backend: github\n  github:\n    apiUrl: ''\n    token: encrypted-token\n    repositories:\n      - owner: owner\n        repo: repo",
    );

    expect(() => loadProjectConfig(tmpDir)).toThrow(ProjectConfigError);
    expect(() => loadProjectConfig(tmpDir)).toThrow(/issueTracker\.github\.apiUrl/);
  });

  it("requires non-empty GitHub token", () => {
    writeForemanConfig(
      tmpDir,
      "issueTracker:\n  backend: github\n  github:\n    apiUrl: https://api.github.com\n    token: ''\n    repositories:\n      - owner: owner\n        repo: repo",
    );

    expect(() => loadProjectConfig(tmpDir)).toThrow(ProjectConfigError);
    expect(() => loadProjectConfig(tmpDir)).toThrow(/issueTracker\.github\.token/);
  });

  it("requires non-empty GitHub repository owner and repo", () => {
    writeForemanConfig(
      tmpDir,
      "issueTracker:\n  backend: github\n  github:\n    apiUrl: https://api.github.com\n    token: encrypted-token\n    repositories:\n      - owner: ''\n        repo: ''",
    );

    expect(() => loadProjectConfig(tmpDir)).toThrow(ProjectConfigError);
    expect(() => loadProjectConfig(tmpDir)).toThrow(/repositories\[0\]\.owner/);
  });

  // JSON fallback
  it("falls back to ~/.foreman/config.json when config.yaml is absent", () => {
    writeForemanConfig(
      tmpDir,
      JSON.stringify({ vcs: { backend: "git" } }),
      "json",
    );
    const cfg = loadProjectConfig(tmpDir);
    expect(cfg!.vcs?.backend).toBe("git");
  });

  it("prefers config.yaml over config.json when both exist", () => {
    writeForemanConfig(tmpDir, "vcs:\n  backend: jujutsu");
    writeForemanConfig(
      tmpDir,
      JSON.stringify({ vcs: { backend: "git" } }),
      "json",
    );
    const cfg = loadProjectConfig(tmpDir);
    // YAML takes priority
    expect(cfg!.vcs?.backend).toBe("jujutsu");
  });

  // Error cases
  it("throws ProjectConfigError for invalid backend value", () => {
    writeForemanConfig(tmpDir, "vcs:\n  backend: svn");
    expect(() => loadProjectConfig(tmpDir)).toThrow(ProjectConfigError);
    expect(() => loadProjectConfig(tmpDir)).toThrow(/vcs.backend must be/);
  });

  it("throws ProjectConfigError when top-level is not an object", () => {
    writeForemanConfig(tmpDir, "- item1\n- item2\n");
    expect(() => loadProjectConfig(tmpDir)).toThrow(ProjectConfigError);
    expect(() => loadProjectConfig(tmpDir)).toThrow(/must be a YAML\/JSON object/);
  });

  it("throws ProjectConfigError when vcs is not an object", () => {
    writeForemanConfig(tmpDir, "vcs: not-an-object");
    expect(() => loadProjectConfig(tmpDir)).toThrow(ProjectConfigError);
    expect(() => loadProjectConfig(tmpDir)).toThrow(/'vcs' must be an object/);
  });

  it("throws ProjectConfigError for invalid vcs.git.useTown type", () => {
    writeForemanConfig(
      tmpDir,
      "vcs:\n  backend: git\n  git:\n    useTown: 'yes'",
    );
    expect(() => loadProjectConfig(tmpDir)).toThrow(ProjectConfigError);
    expect(() => loadProjectConfig(tmpDir)).toThrow(/useTown.*boolean/);
  });

  it("throws ProjectConfigError for invalid defaultBranch type", () => {
    writeForemanConfig(tmpDir, "defaultBranch: 123");
    expect(() => loadProjectConfig(tmpDir)).toThrow(ProjectConfigError);
    expect(() => loadProjectConfig(tmpDir)).toThrow(/defaultBranch/);
  });

  it("throws ProjectConfigError for zero concurrency.global", () => {
    writeForemanConfig(tmpDir, "concurrency:\n  global: 0");
    expect(() => loadProjectConfig(tmpDir)).toThrow(ProjectConfigError);
    expect(() => loadProjectConfig(tmpDir)).toThrow(/concurrency\.global.*positive/);
  });

  it("throws ProjectConfigError for zero concurrency.byState limit", () => {
    writeForemanConfig(tmpDir, "concurrency:\n  byState:\n    review: 0");
    expect(() => loadProjectConfig(tmpDir)).toThrow(ProjectConfigError);
    expect(() => loadProjectConfig(tmpDir)).toThrow(/concurrency\.byState\.review.*positive/);
  });

  it("throws ProjectConfigError for malformed YAML", () => {
    writeForemanConfig(tmpDir, "vcs: {\n  broken yaml: [");
    expect(() => loadProjectConfig(tmpDir)).toThrow(ProjectConfigError);
    expect(() => loadProjectConfig(tmpDir)).toThrow(/failed to parse YAML/);
  });

  it("throws ProjectConfigError for malformed JSON", () => {
    writeForemanConfig(tmpDir, "{ bad json", "json");
    expect(() => loadProjectConfig(tmpDir)).toThrow(ProjectConfigError);
    expect(() => loadProjectConfig(tmpDir)).toThrow(/failed to parse JSON/);
  });

  // taskTypeWorkflowMap validation (foreman-676ac)
  it("loads valid taskTypeWorkflowMap from config.yaml", () => {
    writeForemanConfig(
      tmpDir,
      "taskTypeWorkflowMap:\n  bug: bug\n  task: task\n  default: default",
    );
    const cfg = loadProjectConfig(tmpDir);
    expect(cfg?.taskTypeWorkflowMap).toEqual({
      bug: "bug",
      task: "task",
      default: "default",
    });
  });

  it("loads taskTypeWorkflowMap entries that reference project workflows", () => {
    mkdirSync(join(tmpDir, ".foreman", "workflows"), { recursive: true });
    writeFileSync(join(tmpDir, ".foreman", "workflows", "project-custom.yaml"), "name: project-custom\nphases:\n  - name: finalize\n    builtin: true\n");
    writeForemanConfig(tmpDir, "taskTypeWorkflowMap:\n  custom: project-custom");
    const cfg = loadProjectConfig(tmpDir);
    expect(cfg?.taskTypeWorkflowMap).toEqual({ custom: "project-custom" });
  });

  it("loads taskTypeWorkflowMap with remapping (docs → task)", () => {
    writeForemanConfig(
      tmpDir,
      "taskTypeWorkflowMap:\n  docs: task\n  spike: feature",
    );
    const cfg = loadProjectConfig(tmpDir);
    expect(cfg?.taskTypeWorkflowMap).toEqual({
      docs: "task",
      spike: "feature",
    });
  });

  it("returns undefined taskTypeWorkflowMap when not configured", () => {
    writeForemanConfig(tmpDir, "vcs:\n  backend: git");
    const cfg = loadProjectConfig(tmpDir);
    expect(cfg?.taskTypeWorkflowMap).toBeUndefined();
  });

  it("throws ProjectConfigError when taskTypeWorkflowMap is not an object", () => {
    writeForemanConfig(tmpDir, "taskTypeWorkflowMap: 'not-an-object'");
    expect(() => loadProjectConfig(tmpDir)).toThrow(ProjectConfigError);
    expect(() => loadProjectConfig(tmpDir)).toThrow(/'taskTypeWorkflowMap' must be an object/);
  });

  it("throws ProjectConfigError when taskTypeWorkflowMap has non-string value", () => {
    writeForemanConfig(tmpDir, "taskTypeWorkflowMap:\n  bug: 123");
    expect(() => loadProjectConfig(tmpDir)).toThrow(ProjectConfigError);
    expect(() => loadProjectConfig(tmpDir)).toThrow(/'taskTypeWorkflowMap' entries must be string->string/);
  });

  it("throws ProjectConfigError when taskTypeWorkflowMap references an unknown workflow", () => {
    writeForemanConfig(tmpDir, "taskTypeWorkflowMap:\n  bug: no_such_workflow");
    expect(() => loadProjectConfig(tmpDir)).toThrow(ProjectConfigError);
    expect(() => loadProjectConfig(tmpDir)).toThrow(/no_such_workflow|unknown workflow/i);
  });
});

// ── resolveVcsConfig ──────────────────────────────────────────────────────────

describe("resolveVcsConfig", () => {
  // AC-T-025-2: Priority resolution

  it("returns auto when both inputs are undefined", () => {
    const result = resolveVcsConfig(undefined, undefined);
    expect(result.backend).toBe("auto");
  });

  it("returns auto when both inputs are absent", () => {
    const result = resolveVcsConfig();
    expect(result.backend).toBe("auto");
  });

  it("uses workflow backend when set (not auto)", () => {
    const workflowVcs: ProjectConfig["vcs"] = { backend: "jujutsu" };
    const result = resolveVcsConfig(workflowVcs, undefined);
    expect(result.backend).toBe("jujutsu");
  });

  it("uses project backend when workflow is absent", () => {
    const projectVcs: ProjectConfig["vcs"] = { backend: "git" };
    const result = resolveVcsConfig(undefined, projectVcs);
    expect(result.backend).toBe("git");
  });

  it("workflow takes priority over project config", () => {
    const workflowVcs: ProjectConfig["vcs"] = { backend: "git" };
    const projectVcs: ProjectConfig["vcs"] = { backend: "jujutsu" };
    const result = resolveVcsConfig(workflowVcs, projectVcs);
    expect(result.backend).toBe("git");
  });

  it("falls through to project config when workflow backend is 'auto'", () => {
    const workflowVcs: ProjectConfig["vcs"] = { backend: "auto" };
    const projectVcs: ProjectConfig["vcs"] = { backend: "jujutsu" };
    const result = resolveVcsConfig(workflowVcs, projectVcs);
    expect(result.backend).toBe("jujutsu");
  });

  it("returns auto when both workflow and project specify 'auto'", () => {
    const workflowVcs: ProjectConfig["vcs"] = { backend: "auto" };
    const projectVcs: ProjectConfig["vcs"] = { backend: "auto" };
    const result = resolveVcsConfig(workflowVcs, projectVcs);
    expect(result.backend).toBe("auto");
  });

  it("project config falls through to auto when project backend is 'auto'", () => {
    const projectVcs: ProjectConfig["vcs"] = { backend: "auto" };
    const result = resolveVcsConfig(undefined, projectVcs);
    expect(result.backend).toBe("auto");
  });

  // Sub-option merging
  it("merges git sub-options (workflow overrides project)", () => {
    const workflowVcs: ProjectConfig["vcs"] = {
      backend: "git",
      git: { useTown: false },
    };
    const projectVcs: ProjectConfig["vcs"] = {
      backend: "git",
      git: { useTown: true },
    };
    const result = resolveVcsConfig(workflowVcs, projectVcs);
    // workflow.git.useTown=false overrides project.git.useTown=true
    expect(result.git?.useTown).toBe(false);
  });

  it("inherits git sub-options from project when workflow has none", () => {
    const workflowVcs: ProjectConfig["vcs"] = { backend: "git" };
    const projectVcs: ProjectConfig["vcs"] = {
      backend: "git",
      git: { useTown: false },
    };
    const result = resolveVcsConfig(workflowVcs, projectVcs);
    expect(result.git?.useTown).toBe(false);
  });

  it("merges jujutsu sub-options (workflow overrides project)", () => {
    const workflowVcs: ProjectConfig["vcs"] = {
      backend: "jujutsu",
      jujutsu: { minVersion: "0.22.0" },
    };
    const projectVcs: ProjectConfig["vcs"] = {
      backend: "jujutsu",
      jujutsu: { minVersion: "0.20.0" },
    };
    const result = resolveVcsConfig(workflowVcs, projectVcs);
    expect(result.jujutsu?.minVersion).toBe("0.22.0");
  });

  it("omits git key when neither config has git options", () => {
    const workflowVcs: ProjectConfig["vcs"] = { backend: "git" };
    const result = resolveVcsConfig(workflowVcs, undefined);
    expect(result.git).toBeUndefined();
  });

  it("omits jujutsu key when neither config has jujutsu options", () => {
    const projectVcs: ProjectConfig["vcs"] = { backend: "jujutsu" };
    const result = resolveVcsConfig(undefined, projectVcs);
    expect(result.jujutsu).toBeUndefined();
  });
});

describe("resolveDefaultBranch", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkTmpDir();
    process.env["FOREMAN_HOME"] = tmpDir;
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
    delete process.env["FOREMAN_HOME"];
  });

  it("prefers configured defaultBranch over auto-detection", async () => {
    writeForemanConfig(tmpDir, "defaultBranch: dev");
    const detect = vi.fn().mockResolvedValue("main");
    await expect(resolveDefaultBranch(tmpDir, detect)).resolves.toBe("dev");
    expect(detect).not.toHaveBeenCalled();
  });

  it("falls back to VCS detection when defaultBranch is not configured", async () => {
    const detect = vi.fn().mockResolvedValue("main");
    await expect(resolveDefaultBranch(tmpDir, detect)).resolves.toBe("main");
    expect(detect).toHaveBeenCalledOnce();
  });
});

// ── loadProjectConfig — sandbox block ─────────────────────────────────────────

describe("loadProjectConfig — sandbox block", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkTmpDir();
    process.env["FOREMAN_HOME"] = tmpDir;
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
    delete process.env["FOREMAN_HOME"];
  });

  it("loads sandbox.backend='docker' from config.yaml", () => {
    writeForemanConfig(tmpDir, "sandbox:\n  backend: docker");
    const cfg = loadProjectConfig(tmpDir);
    expect(cfg).not.toBeNull();
    expect(cfg!.sandbox?.backend).toBe("docker");
  });

  it("loads sandbox.backend='podman' from config.yaml", () => {
    writeForemanConfig(tmpDir, "sandbox:\n  backend: podman");
    const cfg = loadProjectConfig(tmpDir);
    expect(cfg!.sandbox?.backend).toBe("podman");
  });

  it("loads sandbox.backend='auto' from config.yaml", () => {
    writeForemanConfig(tmpDir, "sandbox:\n  backend: auto");
    const cfg = loadProjectConfig(tmpDir);
    expect(cfg!.sandbox?.backend).toBe("auto");
  });

  it("loads sandbox.image from config.yaml", () => {
    writeForemanConfig(tmpDir, "sandbox:\n  image: ubuntu:22.04");
    const cfg = loadProjectConfig(tmpDir);
    expect(cfg!.sandbox?.image).toBe("ubuntu:22.04");
  });

  it("loads sandbox.limits from config.yaml", () => {
    writeForemanConfig(tmpDir, `sandbox:
  limits:
    cpu: "2"
    memory: "4g"
    cpuset: "0-1"
    memorySwap: "6g"`);
    const cfg = loadProjectConfig(tmpDir);
    expect(cfg!.sandbox?.limits).toEqual({
      cpu: "2",
      memory: "4g",
      cpuset: "0-1",
      memorySwap: "6g",
    });
  });

  it("loads sandbox.network from config.yaml", () => {
    writeForemanConfig(tmpDir, "sandbox:\n  network: true");
    const cfg = loadProjectConfig(tmpDir);
    expect(cfg!.sandbox?.network).toBe(true);
  });

  it("loads sandbox.cleanup from config.yaml", () => {
    writeForemanConfig(tmpDir, "sandbox:\n  cleanup: keep");
    const cfg = loadProjectConfig(tmpDir);
    expect(cfg!.sandbox?.cleanup).toBe("keep");
  });

  it("loads complete sandbox config from config.yaml", () => {
    writeForemanConfig(tmpDir, `sandbox:
  backend: docker
  image: ubuntu:22.04
  limits:
    cpu: "1"
    memory: "2g"
  network: false
  cleanup: remove`);
    const cfg = loadProjectConfig(tmpDir);
    expect(cfg!.sandbox).toEqual({
      backend: "docker",
      image: "ubuntu:22.04",
      limits: { cpu: "1", memory: "2g" },
      network: false,
      cleanup: "remove",
    });
  });

  it("throws when sandbox.backend is invalid", () => {
    writeForemanConfig(tmpDir, "sandbox:\n  backend: containerd");
    expect(() => loadProjectConfig(tmpDir)).toThrow(/'sandbox.backend' must be 'docker', 'podman', or 'auto'/);
  });

  it("throws when sandbox.image is empty", () => {
    writeForemanConfig(tmpDir, "sandbox:\n  image: ''");
    expect(() => loadProjectConfig(tmpDir)).toThrow(/'sandbox.image' must be a non-empty string/);
  });

  it("throws when sandbox.limits is not an object", () => {
    writeForemanConfig(tmpDir, "sandbox:\n  limits: 2g");
    expect(() => loadProjectConfig(tmpDir)).toThrow(/'sandbox.limits' must be an object/);
  });

  it("throws when sandbox.limits.cpu is empty", () => {
    writeForemanConfig(tmpDir, "sandbox:\n  limits:\n    cpu: ''");
    expect(() => loadProjectConfig(tmpDir)).toThrow(/'sandbox.limits.cpu' must be a non-empty string/);
  });

  it("throws when sandbox.cleanup is invalid", () => {
    writeForemanConfig(tmpDir, "sandbox:\n  cleanup: archive");
    expect(() => loadProjectConfig(tmpDir)).toThrow(/'sandbox.cleanup' must be 'remove' or 'keep'/);
  });

  it("loads sandbox from config.json", () => {
    const foremanHome = mkTmpDir();
    process.env["FOREMAN_HOME"] = foremanHome;
    writeFileSync(join(foremanHome, "config.json"), JSON.stringify({
      sandbox: { backend: "podman", image: "fedora:38" }
    }), "utf-8");
    const cfg = loadProjectConfig(foremanHome);
    expect(cfg!.sandbox?.backend).toBe("podman");
    expect(cfg!.sandbox?.image).toBe("fedora:38");
    rmSync(foremanHome, { recursive: true, force: true });
    delete process.env["FOREMAN_HOME"];
  });
});

// ── resolveSandboxConfig ──────────────────────────────────────────────────────

describe("resolveSandboxConfig", () => {
  // Import the function dynamically since it's not currently exported
  // This test validates the resolution logic works correctly
  it("returns undefined when neither workflow nor project has sandbox config", async () => {
    const { resolveSandboxConfig } = await import("../project-config.js");
    const result = resolveSandboxConfig(undefined, undefined);
    expect(result).toBeUndefined();
  });

  it("returns workflow sandbox when only workflow has config", async () => {
    const { resolveSandboxConfig } = await import("../project-config.js");
    const workflowSandbox = { backend: "docker" as const, image: "ubuntu:22.04" };
    const result = resolveSandboxConfig(workflowSandbox, undefined);
    expect(result?.backend).toBe("docker");
    expect(result?.image).toBe("ubuntu:22.04");
  });

  it("returns project sandbox when only project has config", async () => {
    const { resolveSandboxConfig } = await import("../project-config.js");
    const projectSandbox = { backend: "podman" as const, image: "fedora:38" };
    const result = resolveSandboxConfig(undefined, projectSandbox);
    expect(result?.backend).toBe("podman");
    expect(result?.image).toBe("fedora:38");
  });

  it("workflow config takes precedence over project config", async () => {
    const { resolveSandboxConfig } = await import("../project-config.js");
    const workflowSandbox = { backend: "docker" as const };
    const projectSandbox = { backend: "podman" as const, image: "fedora:38" };
    const result = resolveSandboxConfig(workflowSandbox, projectSandbox);
    expect(result?.backend).toBe("docker");
    expect(result?.image).toBe("fedora:38"); // from project
  });

  it("merges limits from workflow and project configs", async () => {
    const { resolveSandboxConfig } = await import("../project-config.js");
    const workflowSandbox = { limits: { cpu: "2" } };
    const projectSandbox = { limits: { memory: "4g" } };
    const result = resolveSandboxConfig(workflowSandbox, projectSandbox);
    expect(result?.limits).toEqual({ cpu: "2", memory: "4g" });
  });
});
