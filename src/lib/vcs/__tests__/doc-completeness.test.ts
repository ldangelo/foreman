/**
 * Documentation completeness test: All VcsBackend methods and config options are documented.
 *
 * Verifies that `docs/guides/vcs-backend-interface.md` contains documentation for every
 * method defined in `src/lib/vcs/interface.ts`, and that `docs/guides/vcs-configuration.md`
 * and `docs/workflow-yaml-reference.md` document all VCS configuration options.
 *
 * Covers: AC-T-035-1, AC-T-035-2
 *
 * --- AC-T-035-1: Interface Method Coverage ---
 * Every member of VcsBackend (property + methods) must appear as a documented subsection
 * in `docs/guides/vcs-backend-interface.md`. This test:
 *   1. Reads all method/property names from `src/lib/vcs/interface.ts`
 *   2. Checks that each name appears in the interface reference doc
 *   3. Verifies the doc has a heading-style entry (#### or ###) for each member
 *
 * --- AC-T-035-2: Configuration Option Coverage ---
 * Both workflow-level and project-level VCS config options must be documented:
 *   - Project-level options: vcs.backend, vcs.git.useTown, vcs.jujutsu.minVersion
 *   - Workflow-level: vcs.backend override documented in vcs-configuration.md and
 *     workflow-yaml-reference.md
 */

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, it, expect } from "vitest";
import { fileURLToPath } from "node:url";
import { dirname } from "node:path";

// ── Path helpers ───────────────────────────────────────────────────────────────

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

/** Resolve a path from project root (worktree root). */
function projectPath(...parts: string[]): string {
  // __dirname is src/lib/vcs/__tests__/
  return join(__dirname, "..", "..", "..", "..", ...parts);
}

// ── Expected interface members ─────────────────────────────────────────────────

/**
 * Canonical list of VcsBackend interface members (property + methods).
 * Derived directly from `src/lib/vcs/interface.ts`.
 *
 * Update this list whenever the interface changes (and update docs simultaneously).
 */
const VCSBACKEND_MEMBERS: string[] = [
  // Identity
  "name",
  // Repository Introspection
  "getRepoRoot",
  "getMainRepoRoot",
  "detectDefaultBranch",
  "getCurrentBranch",
  // Branch / Bookmark Operations
  "checkoutBranch",
  "branchExists",
  "branchExistsOnRemote",
  "deleteBranch",
  // Workspace / Worktree Operations
  "createWorkspace",
  "removeWorkspace",
  "listWorkspaces",
  // Staging and Commit Operations
  "stageAll",
  "commit",
  "push",
  "pull",
  // Rebase and Merge Operations
  "rebase",
  "abortRebase",
  "merge",
  // Diff, Status and Conflict Detection
  "getHeadId",
  "resolveRef",
  "fetch",
  "diff",
  "getChangedFiles",
  "getRefCommitTimestamp",
  "getModifiedFiles",
  "getConflictingFiles",
  "status",
  "cleanWorkingTree",
  // Finalize Support
  "getFinalizeCommands",
];

/**
 * Foreman-wide VCS configuration options that must be documented.
 * All options come from `~/.foreman/config.yaml`.
 */
const PROJECT_CONFIG_OPTIONS: Array<{ key: string; description: string }> = [
  { key: "vcs.backend", description: "Backend selector (git | jujutsu | auto)" },
  { key: "vcs.git.useTown", description: "Git-town integration toggle" },
  { key: "vcs.jujutsu.minVersion", description: "Minimum jj CLI version" },
];

/**
 * Workflow-level VCS configuration options that must be documented.
 * These options live in `~/.foreman/workflows/*.yaml`.
 */
const WORKFLOW_CONFIG_OPTIONS: Array<{ key: string; description: string }> = [
  { key: "vcs:", description: "Top-level workflow VCS block" },
  { key: "backend:", description: "Backend override for workflow" },
];

// ── Helpers ────────────────────────────────────────────────────────────────────

/** Read a file from the project root, returning its content as a string. */
function readDoc(relPath: string): string {
  return readFileSync(projectPath(relPath), "utf8");
}

/**
 * Returns true if the doc contains a heading-style anchor for the given member.
 * Accepts both:
 *   - #### `memberName(` — method with arguments
 *   - #### `memberName:` — property with type annotation
 *   - #### `memberName` — bare name heading
 *
 * This is lenient: it just needs the member name to appear after one or more `#`
 * characters followed by optional backtick, to confirm a dedicated section exists.
 */
function hasMemberHeading(doc: string, memberName: string): boolean {
  // Match: ### or #### `memberName` anywhere
  const headingPattern = new RegExp(
    `^#{2,6}\\s+\`?${escapeRegExp(memberName)}[\`:(\\s]`,
    "m",
  );
  return headingPattern.test(doc);
}

/** Escape special regex characters in a string. */
function escapeRegExp(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** Returns true if the doc contains the given string anywhere (case-sensitive). */
function docContains(doc: string, text: string): boolean {
  return doc.includes(text);
}

// ── Tests ──────────────────────────────────────────────────────────────────────

describe("AC-T-035: Documentation Completeness — VcsBackend", () => {
  /**
   * AC-T-035-1: All VcsBackend methods and the `name` property must have a
   * dedicated heading-level entry in `docs/guides/vcs-backend-interface.md`.
   *
   * For each expected member:
   *   - Checks that a `####` or `###` heading containing the member name exists
   *   - Reports ALL missing members in a single failure (not one failure per member)
   */
  describe("AC-T-035-1: Interface method coverage in vcs-backend-interface.md", () => {
    const interfaceDoc = readDoc("docs/guides/vcs-backend-interface.md");

    it("interface reference doc exists and is non-empty", () => {
      expect(interfaceDoc.length).toBeGreaterThan(0);
      expect(interfaceDoc).toContain("VcsBackend");
    });

    it("all VcsBackend members have a documented heading section", () => {
      const missing: string[] = [];

      for (const member of VCSBACKEND_MEMBERS) {
        if (!hasMemberHeading(interfaceDoc, member)) {
          missing.push(member);
        }
      }

      if (missing.length > 0) {
        const msg = [
          `${missing.length} VcsBackend member(s) lack a heading section in docs/guides/vcs-backend-interface.md:`,
          "",
          ...missing.map((m) => `  • ${m}`),
          "",
          "Each member must appear in a heading like:",
          "  #### `methodName(param: Type): Promise<ReturnType>`",
          "  #### `propertyName: Type`",
          "",
          "Add the missing sections to docs/guides/vcs-backend-interface.md.",
        ].join("\n");
        expect.fail(msg);
      }
    });

    it("documents the total expected number of interface members (30)", () => {
      // Sanity check: VCSBACKEND_MEMBERS list is up to date with interface.ts
      expect(VCSBACKEND_MEMBERS.length).toBe(30);
    });

    it("each member is referenced at least once in the doc body", () => {
      const notReferenced: string[] = [];

      for (const member of VCSBACKEND_MEMBERS) {
        if (!docContains(interfaceDoc, member)) {
          notReferenced.push(member);
        }
      }

      if (notReferenced.length > 0) {
        const msg = [
          `${notReferenced.length} VcsBackend member(s) are not mentioned anywhere in docs/guides/vcs-backend-interface.md:`,
          "",
          ...notReferenced.map((m) => `  • ${m}`),
          "",
          "All interface members must appear in the reference documentation.",
        ].join("\n");
        expect.fail(msg);
      }
    });

    it("documentation includes backend-comparison tables (Git vs Jujutsu)", () => {
      // Verify that cross-backend documentation exists (backend equivalents)
      expect(interfaceDoc).toContain("Git");
      expect(interfaceDoc).toContain("Jujutsu");
      expect(interfaceDoc).toContain("| Backend");
    });

    it("documentation includes a testing patterns section", () => {
      // AC-T-035-1 extension: doc must include mock/test usage patterns
      expect(interfaceDoc).toContain("mock");
    });
  });

  /**
   * AC-T-035-2: Both workflow-level and project-level VCS config options
   * must be documented in the appropriate guide files.
   */
  describe("AC-T-035-2: Configuration option coverage", () => {
    const configDoc = readDoc("docs/guides/vcs-configuration.md");
    const workflowDoc = readDoc("docs/workflow-yaml-reference.md");

    it("vcs-configuration.md exists and is non-empty", () => {
      expect(configDoc.length).toBeGreaterThan(0);
    });

    it("workflow-yaml-reference.md exists and is non-empty", () => {
      expect(workflowDoc.length).toBeGreaterThan(0);
    });

    describe("project-level config options", () => {
      it("all project-level config options are documented in vcs-configuration.md", () => {
        const missing: string[] = [];

        for (const option of PROJECT_CONFIG_OPTIONS) {
          if (!docContains(configDoc, option.key)) {
            missing.push(`${option.key} — ${option.description}`);
          }
        }

        if (missing.length > 0) {
          const msg = [
            `${missing.length} project-level config option(s) are missing from docs/guides/vcs-configuration.md:`,
            "",
            ...missing.map((m) => `  • ${m}`),
            "",
            "Add the missing options to the Project-Level Config section of the guide.",
          ].join("\n");
          expect.fail(msg);
        }
      });

      it("documents vcs.backend enum values (git, jujutsu, auto)", () => {
        expect(configDoc).toContain("git");
        expect(configDoc).toContain("jujutsu");
        expect(configDoc).toContain("auto");
      });

      it("documents configuration precedence (workflow > project > auto)", () => {
        expect(configDoc).toContain("Workflow YAML");
        expect(configDoc).toContain("~/.foreman/config.yaml");
        expect(configDoc).toContain("Auto-detection");
      });
    });

    describe("workflow-level config options", () => {
      it("workflow-level vcs.backend override is documented in vcs-configuration.md", () => {
        // The workflow-level config section must exist
        expect(configDoc).toContain("Workflow-Level Config");
        // And must document the backend override
        expect(configDoc).toContain("vcs:");
        expect(configDoc).toContain("backend:");
      });

      it("workflow-level vcs config is documented in workflow-yaml-reference.md", () => {
        for (const option of WORKFLOW_CONFIG_OPTIONS) {
          if (!docContains(workflowDoc, option.key)) {
            expect.fail(
              `workflow-yaml-reference.md is missing documentation for workflow config option: ${option.key} (${option.description})`,
            );
          }
        }
      });

      it("workflow-yaml-reference.md includes VCS configuration section", () => {
        // Must have a dedicated VCS section heading
        const hasVcsSection =
          workflowDoc.includes("## VCS") ||
          workflowDoc.includes("### VCS") ||
          workflowDoc.includes("VCS Configuration") ||
          workflowDoc.includes("vcs Configuration");
        expect(hasVcsSection).toBe(true);
      });
    });

    describe("cross-document linking", () => {
      it("vcs-configuration.md links to vcs-backend-interface.md", () => {
        expect(configDoc).toContain("vcs-backend-interface");
      });

      it("vcs-backend-interface.md links to vcs-configuration.md", () => {
        const interfaceDoc = readDoc("docs/guides/vcs-backend-interface.md");
        expect(interfaceDoc).toContain("vcs-configuration");
      });
    });
  });
});
