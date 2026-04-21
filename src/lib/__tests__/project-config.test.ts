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
  projectRoot: string,
  content: string,
  ext: "yaml" | "json" = "yaml",
): void {
  const dir = join(projectRoot, ".foreman");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, `config.${ext}`), content, "utf-8");
}

// ── loadProjectConfig ─────────────────────────────────────────────────────────

describe("loadProjectConfig", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkTmpDir();
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  // AC-T-025-3: Missing config → null (not an error)
  it("returns null when .foreman/config.yaml does not exist", () => {
    const result = loadProjectConfig(tmpDir);
    expect(result).toBeNull();
  });

  it("returns null when .foreman/ directory does not exist", () => {
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

  // JSON fallback
  it("falls back to .foreman/config.json when config.yaml is absent", () => {
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
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
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
