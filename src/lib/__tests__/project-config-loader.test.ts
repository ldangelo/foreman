/**
 * Tests for src/lib/project-config-loader.ts
 */
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdirSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  loadProjectConfig,
  validateProjectConfig,
  mergeVcsConfig,
  ProjectConfigError,
  type ProjectConfig,
} from "../project-config-loader.js";

// ── Helpers ──────────────────────────────────────────────────────────────────

function mkTmpDir(): string {
  const dir = join(
    tmpdir(),
    `foreman-pcc-test-${Date.now()}-${Math.random().toString(36).slice(2)}`,
  );
  mkdirSync(dir, { recursive: true });
  return dir;
}

function writeProjectConfig(projectRoot: string, content: string): void {
  const dir = join(projectRoot, ".foreman");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "config.yaml"), content, "utf-8");
}

// ── validateProjectConfig ────────────────────────────────────────────────────

describe("validateProjectConfig", () => {
  const projectPath = "/tmp/test-project";

  it("accepts an empty object (no vcs key)", () => {
    const config = validateProjectConfig({}, projectPath);
    expect(config.vcs).toBeUndefined();
  });

  it("parses vcs.backend = 'git'", () => {
    const config = validateProjectConfig({ vcs: { backend: "git" } }, projectPath);
    expect(config.vcs!.backend).toBe("git");
  });

  it("parses vcs.backend = 'jujutsu'", () => {
    const config = validateProjectConfig({ vcs: { backend: "jujutsu" } }, projectPath);
    expect(config.vcs!.backend).toBe("jujutsu");
  });

  it("parses vcs.backend = 'auto'", () => {
    const config = validateProjectConfig({ vcs: { backend: "auto" } }, projectPath);
    expect(config.vcs!.backend).toBe("auto");
  });

  it("parses vcs.git.useTown = true", () => {
    const config = validateProjectConfig(
      { vcs: { backend: "git", git: { useTown: true } } },
      projectPath,
    );
    expect(config.vcs!.git!.useTown).toBe(true);
  });

  it("parses vcs.git.useTown = false", () => {
    const config = validateProjectConfig(
      { vcs: { backend: "git", git: { useTown: false } } },
      projectPath,
    );
    expect(config.vcs!.git!.useTown).toBe(false);
  });

  it("parses vcs.jujutsu.minVersion", () => {
    const config = validateProjectConfig(
      { vcs: { backend: "jujutsu", jujutsu: { minVersion: "0.21.0" } } },
      projectPath,
    );
    expect(config.vcs!.jujutsu!.minVersion).toBe("0.21.0");
  });

  it("throws ProjectConfigError on non-object input", () => {
    expect(() => validateProjectConfig("string", projectPath)).toThrow(ProjectConfigError);
    expect(() => validateProjectConfig(null, projectPath)).toThrow(ProjectConfigError);
    expect(() => validateProjectConfig(42, projectPath)).toThrow(ProjectConfigError);
  });

  it("throws ProjectConfigError when vcs is not an object", () => {
    expect(() =>
      validateProjectConfig({ vcs: "git" }, projectPath),
    ).toThrow(ProjectConfigError);
  });

  it("throws ProjectConfigError when vcs.backend is invalid", () => {
    expect(() =>
      validateProjectConfig({ vcs: { backend: "svn" } }, projectPath),
    ).toThrow(ProjectConfigError);
    expect(() =>
      validateProjectConfig({ vcs: { backend: "svn" } }, projectPath),
    ).toThrow(/vcs.backend must be/);
  });

  it("throws ProjectConfigError when vcs.backend is missing", () => {
    expect(() =>
      validateProjectConfig({ vcs: {} }, projectPath),
    ).toThrow(ProjectConfigError);
  });

  it("throws ProjectConfigError when vcs.git is not an object", () => {
    expect(() =>
      validateProjectConfig({ vcs: { backend: "git", git: "yes" } }, projectPath),
    ).toThrow(ProjectConfigError);
  });

  it("throws ProjectConfigError when vcs.git.useTown is not a boolean", () => {
    expect(() =>
      validateProjectConfig(
        { vcs: { backend: "git", git: { useTown: "yes" } } },
        projectPath,
      ),
    ).toThrow(ProjectConfigError);
  });

  it("throws ProjectConfigError when vcs.jujutsu is not an object", () => {
    expect(() =>
      validateProjectConfig({ vcs: { backend: "jujutsu", jujutsu: "v0.21" } }, projectPath),
    ).toThrow(ProjectConfigError);
  });

  it("throws ProjectConfigError when vcs.jujutsu.minVersion is not a string", () => {
    expect(() =>
      validateProjectConfig(
        { vcs: { backend: "jujutsu", jujutsu: { minVersion: 21 } } },
        projectPath,
      ),
    ).toThrow(ProjectConfigError);
  });

  it("throws ProjectConfigError when vcs.jujutsu.minVersion is empty string", () => {
    expect(() =>
      validateProjectConfig(
        { vcs: { backend: "jujutsu", jujutsu: { minVersion: "" } } },
        projectPath,
      ),
    ).toThrow(ProjectConfigError);
  });
});

// ── loadProjectConfig ────────────────────────────────────────────────────────

describe("loadProjectConfig", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkTmpDir();
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("returns empty object when .foreman/config.yaml does not exist", () => {
    const config = loadProjectConfig(tmpDir);
    expect(config).toEqual({});
    expect(config.vcs).toBeUndefined();
  });

  it("returns empty object when config.yaml is empty", () => {
    writeProjectConfig(tmpDir, "");
    const config = loadProjectConfig(tmpDir);
    expect(config).toEqual({});
  });

  it("returns empty object when config.yaml is null YAML", () => {
    writeProjectConfig(tmpDir, "~");
    const config = loadProjectConfig(tmpDir);
    expect(config).toEqual({});
  });

  it("loads vcs.backend = 'git' from config.yaml", () => {
    writeProjectConfig(tmpDir, "vcs:\n  backend: git\n");
    const config = loadProjectConfig(tmpDir);
    expect(config.vcs!.backend).toBe("git");
  });

  it("loads vcs.backend = 'jujutsu' from config.yaml", () => {
    writeProjectConfig(tmpDir, "vcs:\n  backend: jujutsu\n");
    const config = loadProjectConfig(tmpDir);
    expect(config.vcs!.backend).toBe("jujutsu");
  });

  it("loads vcs.backend = 'auto' from config.yaml", () => {
    writeProjectConfig(tmpDir, "vcs:\n  backend: auto\n");
    const config = loadProjectConfig(tmpDir);
    expect(config.vcs!.backend).toBe("auto");
  });

  it("loads full vcs config with nested options", () => {
    writeProjectConfig(
      tmpDir,
      `vcs:
  backend: git
  git:
    useTown: true
`,
    );
    const config = loadProjectConfig(tmpDir);
    expect(config.vcs!.backend).toBe("git");
    expect(config.vcs!.git!.useTown).toBe(true);
  });

  it("loads jujutsu minVersion from config.yaml", () => {
    writeProjectConfig(
      tmpDir,
      `vcs:
  backend: jujutsu
  jujutsu:
    minVersion: "0.21.0"
`,
    );
    const config = loadProjectConfig(tmpDir);
    expect(config.vcs!.backend).toBe("jujutsu");
    expect(config.vcs!.jujutsu!.minVersion).toBe("0.21.0");
  });

  it("throws ProjectConfigError when config.yaml has invalid YAML", () => {
    writeProjectConfig(tmpDir, "vcs: {\n invalid yaml here\n");
    expect(() => loadProjectConfig(tmpDir)).toThrow(ProjectConfigError);
    expect(() => loadProjectConfig(tmpDir)).toThrow(/failed to parse YAML/);
  });

  it("throws ProjectConfigError when vcs.backend is invalid", () => {
    writeProjectConfig(tmpDir, "vcs:\n  backend: svn\n");
    expect(() => loadProjectConfig(tmpDir)).toThrow(ProjectConfigError);
  });

  it("throws ProjectConfigError when config.yaml is a non-object YAML value", () => {
    writeProjectConfig(tmpDir, "42");
    expect(() => loadProjectConfig(tmpDir)).toThrow(ProjectConfigError);
  });
});

// ── mergeVcsConfig ────────────────────────────────────────────────────────────

describe("mergeVcsConfig", () => {
  it("returns workflowVcs when both are defined (workflow wins)", () => {
    const workflowVcs = { backend: "git" as const };
    const projectVcs = { backend: "jujutsu" as const };
    const merged = mergeVcsConfig(workflowVcs, projectVcs);
    expect(merged.backend).toBe("git");
  });

  it("returns projectVcs when workflowVcs is undefined", () => {
    const projectVcs = { backend: "jujutsu" as const };
    const merged = mergeVcsConfig(undefined, projectVcs);
    expect(merged.backend).toBe("jujutsu");
  });

  it("returns auto default when both are undefined", () => {
    const merged = mergeVcsConfig(undefined, undefined);
    expect(merged.backend).toBe("auto");
  });

  it("returns workflowVcs when projectVcs is undefined", () => {
    const workflowVcs = { backend: "git" as const };
    const merged = mergeVcsConfig(workflowVcs, undefined);
    expect(merged.backend).toBe("git");
  });

  it("preserves nested git config from workflowVcs", () => {
    const workflowVcs = { backend: "git" as const, git: { useTown: true } };
    const projectVcs = { backend: "git" as const, git: { useTown: false } };
    const merged = mergeVcsConfig(workflowVcs, projectVcs);
    expect(merged.git!.useTown).toBe(true);  // workflow wins
  });

  it("preserves jujutsu.minVersion from projectVcs when workflow has no vcs", () => {
    const projectVcs = { backend: "jujutsu" as const, jujutsu: { minVersion: "0.21.0" } };
    const merged = mergeVcsConfig(undefined, projectVcs);
    expect(merged.jujutsu!.minVersion).toBe("0.21.0");
  });
});
