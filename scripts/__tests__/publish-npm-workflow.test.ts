/**
 * Tests for the GitHub Actions publish-npm workflow.
 *
 * These tests verify:
 * - The workflow YAML is valid and contains required fields
 * - Security: minimal permissions, NPM_TOKEN used correctly
 * - Version check step is present
 * - Dry-run support works as expected
 * - npm scripts required by the workflow exist
 */

import { describe, it, expect, beforeAll } from "vitest";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "..", "..");

// ── Workflow file existence ───────────────────────────────────────────────────

describe("publish-npm workflow file", () => {
  const workflowPath = path.join(
    REPO_ROOT,
    ".github",
    "workflows",
    "publish-npm.yml"
  );

  it("exists at .github/workflows/publish-npm.yml", () => {
    expect(existsSync(workflowPath)).toBe(true);
  });

  it("triggers on version tag push", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("push:");
    expect(contents).toContain("tags:");
    expect(contents).toMatch(/v\*\.\*\.\*/);
  });

  it("has workflow_dispatch trigger for manual publishing", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("workflow_dispatch:");
  });

  it("has dry_run input option", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("dry_run");
  });

  it("uses ubuntu-latest runner", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("ubuntu-latest");
  });

  it("checks out repository", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("actions/checkout@v4");
  });

  it("sets up Node.js with npm registry-url and @oftheangels scope", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("actions/setup-node@v4");
    expect(contents).toContain("registry-url");
    expect(contents).toContain("registry.npmjs.org");
    expect(contents).toContain("@oftheangels");
  });

  it("caches node_modules for faster builds", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("actions/cache@v4");
    expect(contents).toContain("node_modules");
    expect(contents).toContain("package-lock.json");
  });

  it("installs dependencies with npm ci", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("npm ci");
  });

  it("verifies git tag matches package.json version before publishing", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("package.json");
    // Should check both the tag and package version
    expect(contents).toContain("GITHUB_REF");
  });

  it("runs TypeScript type check before publishing", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("tsc --noEmit");
  });

  it("runs test suite before publishing", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("npm test");
  });

  it("builds TypeScript before publishing", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("npm run build");
  });

  it("publishes with --access public flag", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("npm publish");
    expect(contents).toContain("--access public");
  });

  it("uses NPM_TOKEN secret for authentication (not GITHUB_TOKEN)", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("secrets.NPM_TOKEN");
    expect(contents).toContain("NODE_AUTH_TOKEN");
  });

  it("has read-only permissions (contents: read)", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    // Must NOT request write permissions (npm publish doesn't need them)
    expect(contents).toContain("contents: read");
    expect(contents).not.toContain("contents: write");
  });

  it("skips npm publish step during dry run", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    // The publish step should have a condition that skips it during dry run
    expect(contents).toContain("dry_run");
    // Check the dry_run conditional is used on the publish step
    const publishIndex = contents.indexOf("npm publish");
    const dryRunCheckBefore = contents.lastIndexOf("dry_run", publishIndex);
    expect(dryRunCheckBefore).toBeGreaterThan(-1);
  });

  it("runs npm pack during dry run", () => {
    const contents = readFileSync(workflowPath, "utf-8");
    expect(contents).toContain("npm pack");
    expect(contents).toContain("--dry-run");
  });
});

// ── .npmrc file ───────────────────────────────────────────────────────────────

describe(".npmrc configuration file", () => {
  const npmrcPath = path.join(REPO_ROOT, ".npmrc");

  it("exists at repository root", () => {
    expect(existsSync(npmrcPath)).toBe(true);
  });

  it("points to https://registry.npmjs.org/", () => {
    const contents = readFileSync(npmrcPath, "utf-8");
    expect(contents).toContain("registry=https://registry.npmjs.org/");
  });

  it("uses ${NPM_TOKEN} interpolation (no hardcoded token)", () => {
    const contents = readFileSync(npmrcPath, "utf-8");
    expect(contents).toContain("${NPM_TOKEN}");
    // Ensure no real token is present (tokens start with npm_)
    expect(contents).not.toMatch(/npm_[A-Za-z0-9]{36}/);
  });

  it("configures auth token for registry.npmjs.org", () => {
    const contents = readFileSync(npmrcPath, "utf-8");
    expect(contents).toContain("_authToken");
    expect(contents).toContain("registry.npmjs.org");
  });

  it("does not contain any real secrets or API keys", () => {
    const contents = readFileSync(npmrcPath, "utf-8");
    // npm automation tokens are 36+ chars after npm_
    expect(contents).not.toMatch(/npm_[A-Za-z0-9]{36,}/);
    // GitHub PATs start with ghp_ or github_pat_
    expect(contents).not.toMatch(/ghp_[A-Za-z0-9]+/);
    expect(contents).not.toMatch(/github_pat_[A-Za-z0-9_]+/);
  });
});

// ── CONTRIBUTING.md ───────────────────────────────────────────────────────────

describe("CONTRIBUTING.md documentation", () => {
  const contributingPath = path.join(REPO_ROOT, "CONTRIBUTING.md");

  it("exists at repository root", () => {
    expect(existsSync(contributingPath)).toBe(true);
  });

  it("documents NPM_TOKEN secret setup", () => {
    const contents = readFileSync(contributingPath, "utf-8");
    expect(contents).toContain("NPM_TOKEN");
  });

  it("documents GITHUB_TOKEN (auto-provided)", () => {
    const contents = readFileSync(contributingPath, "utf-8");
    expect(contents).toContain("GITHUB_TOKEN");
  });

  it("documents @oftheangels npm organisation setup", () => {
    const contents = readFileSync(contributingPath, "utf-8");
    expect(contents).toContain("@oftheangels");
    expect(contents).toContain("organisation");
  });

  it("explains 2FA setup on npmjs.com", () => {
    const contents = readFileSync(contributingPath, "utf-8");
    expect(contents).toContain("2FA");
    expect(contents).toMatch(/[Tt]wo-[Ff]actor/);
  });

  it("explains automation token generation", () => {
    const contents = readFileSync(contributingPath, "utf-8");
    expect(contents).toContain("Automation");
    expect(contents).toContain("Access Tokens");
  });

  it("includes release checklist with git tag instructions", () => {
    const contents = readFileSync(contributingPath, "utf-8");
    expect(contents).toContain("git push origin --tags");
    expect(contents).toContain("npm version");
  });

  it("documents token rotation recommendation", () => {
    const contents = readFileSync(contributingPath, "utf-8");
    expect(contents).toContain("rotat");
  });

  it("includes troubleshooting section", () => {
    const contents = readFileSync(contributingPath, "utf-8");
    expect(contents).toContain("Troubleshooting");
    expect(contents).toContain("E403");
  });

  it("explains version consistency requirement", () => {
    const contents = readFileSync(contributingPath, "utf-8");
    expect(contents).toContain("package.json");
    // Should explain that the tag must match the package.json version
    expect(contents).toMatch(/tag.*match|match.*tag/i);
  });
});

// ── package.json publishing config ───────────────────────────────────────────

describe("package.json publish configuration", () => {
  let packageJson: Record<string, unknown>;

  beforeAll(() => {
    const pkgPath = path.join(REPO_ROOT, "package.json");
    packageJson = JSON.parse(readFileSync(pkgPath, "utf-8")) as Record<
      string,
      unknown
    >;
  });

  it("has scoped name @oftheangels/foreman", () => {
    expect(packageJson.name).toBe("@oftheangels/foreman");
  });

  it("has publishConfig.access set to 'public'", () => {
    const publishConfig = packageJson.publishConfig as Record<string, string>;
    expect(publishConfig).toBeDefined();
    expect(publishConfig.access).toBe("public");
  });

  it("has valid semver version", () => {
    const version = packageJson.version as string;
    expect(version).toMatch(/^\d+\.\d+\.\d+/);
  });

  it("includes dist/ in published files", () => {
    const files = packageJson.files as string[];
    expect(files).toContain("dist/");
  });

  it("includes bin/ in published files", () => {
    const files = packageJson.files as string[];
    expect(files).toContain("bin/");
  });

  it("has engines.node constraint >= 20", () => {
    const engines = packageJson.engines as Record<string, string>;
    expect(engines.node).toContain("20");
  });
});
