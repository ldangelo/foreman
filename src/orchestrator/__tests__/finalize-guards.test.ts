import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, describe, expect, it } from "vitest";
import { extractExplorerScopedPaths, finalizeValidationCommands, findFinalizeScopeViolations, reportJustifiesOutOfScope } from "../finalize-guards.js";

describe("finalize guards", () => {
  const tmpDirs: string[] = [];

  afterEach(() => {
    for (const dir of tmpDirs.splice(0)) rmSync(dir, { recursive: true, force: true });
  });

  it("extracts Explorer Edit First paths", () => {
    const paths = extractExplorerScopedPaths(`## Developer Handoff\n\n### Edit First\n1. **src/cli/commands/task.ts** — update status badge\n2. \`src/cli/watch-ui.ts\` — update card color\n\n### Boundaries\n- Do not touch backend\n`);

    expect([...paths]).toEqual(["src/cli/commands/task.ts", "src/cli/watch-ui.ts"]);
  });

  it("flags files outside Explorer scope that lack a structured ## Scope Expansions entry", () => {
    // After removing the global keyword fallback, a file mentioned only in
    // ## Decisions & Trade-offs (or any other section) does NOT count as
    // justified. The developer contract is the ## Scope Expansions section;
    // only structured per-file entries there satisfy the guard.
    const worktreePath = join(tmpdir(), `foreman-finalize-guard-${process.pid}-${Date.now()}`);
    tmpDirs.push(worktreePath);
    const reportDir = ".foreman/reports/task-scope/run-scope";
    mkdirSync(join(worktreePath, reportDir), { recursive: true });
    writeFileSync(join(worktreePath, reportDir, "EXPLORER_REPORT.md"), `### Edit First\n- **src/cli/commands/task.ts**\n- **src/cli/watch-ui.ts**\n`, "utf8");
    writeFileSync(join(worktreePath, reportDir, "DEVELOPER_REPORT.md"), `## Decisions & Trade-offs\n- Changed src/generated/types.ts because the task command type requires the additional file.\n`, "utf8");

    const config = { worktreePath, reportDir };

    expect(findFinalizeScopeViolations(config, [
      "src/cli/commands/task.ts",
      "packages/foreman_server/lib/foreman_server/overwatch.ex",
      "src/generated/types.ts",
    ])).toEqual([
      "packages/foreman_server/lib/foreman_server/overwatch.ex",
      "src/generated/types.ts",
    ]);
  });

  it("accepts out-of-scope files listed under ## Scope Expansions with a substantive entry", () => {
    // The fix: a structured per-file entry under ## Scope Expansions with a
    // real justification now satisfies the guard. src/generated/types.ts moves
    // from Decisions & Trade-offs (where it was previously accepted via the
    // loose keyword fallback) to Scope Expansions, where it is now required.
    const worktreePath = join(tmpdir(), `foreman-finalize-guard-accept-${process.pid}-${Date.now()}`);
    tmpDirs.push(worktreePath);
    const reportDir = ".foreman/reports/task-scope/run-scope-accept";
    mkdirSync(join(worktreePath, reportDir), { recursive: true });
    writeFileSync(join(worktreePath, reportDir, "EXPLORER_REPORT.md"), `### Edit First\n- **src/cli/commands/task.ts**\n- **src/cli/watch-ui.ts**\n`, "utf8");
    writeFileSync(join(worktreePath, reportDir, "DEVELOPER_REPORT.md"), [
      "## Decisions & Trade-offs",
      "- Considered coupling to the existing types module.",
      "",
      "## Scope Expansions",
      "- `packages/foreman_server/lib/foreman_server/overwatch.ex` — prerequisite fix: the overwatch poll needed the heartbeat event surface this task introduces.",
      "- `src/generated/types.ts` — TypeScript types regenerate from the new schema; required to keep the build green.",
      "",
    ].join("\n"), "utf8");

    const config = { worktreePath, reportDir };

    expect(findFinalizeScopeViolations(config, [
      "src/cli/commands/task.ts",
      "packages/foreman_server/lib/foreman_server/overwatch.ex",
      "src/generated/types.ts",
    ])).toEqual([]);
  });

  it("rejects placeholder justifications (TODO, TBD, blank, dashes)", () => {
    // Real developer.md:116-119 requires a substantive justification. A bare
    // "TODO" or "-" or blank line must NOT satisfy the guard. The per-file
    // entry may exist, but its content must be a real sentence.
    const placeholders = ["TODO", "todo", "TBD", "tba", "n/a", "-", ".", ",", ";", " "];
    for (const placeholder of placeholders) {
      const report = [
        "## Scope Expansions",
        `- src/cli/commands/inbox.ts \u2014 ${placeholder}`,
      ].join("\n");
      expect(reportJustifiesOutOfScope(report, "src/cli/commands/inbox.ts")).toBe(false);
    }
  });

  it("rejects punctuation-only justifications of any length (CodeRabbit bypass regression)", () => {
    // Regression for CodeRabbit review on PR #387: the original
    // PLACEHOLDER_JUSTIFICATIONS regex used a single-character anchor and could
    // be bypassed by repeating punctuation to meet MIN_JUSTIFICATION_LENGTH
    // (e.g. "------------" or "............"). SYMBOL_ONLY_JUSTIFICATION now
    // rejects any string composed entirely of non-letter, non-digit characters
    // (Unicode-aware via \\p{L} / \\p{N}).
    const symbolOnly = [
      "------------",
      "............",
      "////////////",
      "************",
      ",,,,,,,,,",
      "____________",
      ":::::",
      ";;;;;",
      "((()))",
    ];
    for (const justification of symbolOnly) {
      const report = [
        "## Scope Expansions",
        `- src/cli/commands/inbox.ts — ${justification}`,
      ].join("\n");
      expect(reportJustifiesOutOfScope(report, "src/cli/commands/inbox.ts")).toBe(false);
    }
  });

  it("rejects justifications that begin with placeholder tokens followed by more text", () => {
    // Regression: a bare PLACEHOLDER_WORD match (e.g. "TODO" exactly) used to
    // reject the stub, but a justification like "TODO: justify later" or
    // "TBD - blocker" or "N/A because trivial" passes the exact-word check
    // because it contains letters and exceeds the minimum length. The
    // LEADING_PLACEHOLDER regex matches placeholder tokens at the start of
    // the justification, optionally followed by punctuation/whitespace and
    // any trailing text, so these stubs are rejected.
    const leadingPlaceholder = [
      "TODO: justify later",
      "TODO justify later",
      "TBD - blocker",
      "TBD — blocker",
      "N/A because trivial",
      "NA - will fix in follow-up",
      "PLACEHOLDER, see cr-developer",
      "PLACEHOLDER: revisit in follow-up",
      "NONE yet, will revisit",
    ];
    for (const justification of leadingPlaceholder) {
      const report = [
        "## Scope Expansions",
        `- src/cli/commands/inbox.ts — ${justification}`,
      ].join("\n");
      expect(reportJustifiesOutOfScope(report, "src/cli/commands/inbox.ts")).toBe(false);
    }
  });

  it("rejects justifications shorter than the minimum length", () => {
    // Anything shorter than ~12 characters is almost certainly a stub. Real
    // developer.md:116-119 justifications are sentence-length.
    const shortJustifications = ["fix", "TBD only", "needed"];
    for (const justification of shortJustifications) {
      const report = [
        "## Scope Expansions",
        `- src/cli/commands/inbox.ts \u2014 ${justification}`,
      ].join("\n");
      expect(reportJustifiesOutOfScope(report, "src/cli/commands/inbox.ts")).toBe(false);
    }
  });

  it("accepts colon-separated entries with backtick-wrapped paths", () => {
    // Some developer prompts render the separator as a colon rather than an
    // em-dash. The parser should accept either form.
    const report = [
      "## Scope Expansions",
      "- `packages/foreman_server/lib/foreman_server/overwatch.ex`: prerequisite fix for the heartbeat-manager coordination this task introduces.",
    ].join("\n");
    expect(reportJustifiesOutOfScope(report, "packages/foreman_server/lib/foreman_server/overwatch.ex")).toBe(true);
  });

  it("preserves paths with hyphens (heartbeat-manager.ts, finalize-guards.ts)", () => {
    // Regression: the path parser must not treat hyphens as separators.
    // Real flagged files in production runs include hyphens.
    const report = [
      "## Scope Expansions",
      "- `src/orchestrator/heartbeat-manager.ts` — hard-acceptance fix: the polling change required coordinating heartbeat emission intervals.",
      "- `src/orchestrator/finalize-guards.ts` — placeholder rejection hardening per the scope-guard failure RCA.",
    ].join("\n");
    expect(reportJustifiesOutOfScope(report, "src/orchestrator/heartbeat-manager.ts")).toBe(true);
    expect(reportJustifiesOutOfScope(report, "src/orchestrator/finalize-guards.ts")).toBe(true);
  });

  it("recognizes ## Scope Expansions section as explicit developer contract", () => {
    const report = [
      "# Developer Report",
      "",
      "## Files Changed",
      "- src/cli/commands/inbox.ts — added backlog-only task support",
      "",
      "## Scope Expansions",
      "- `src/cli/commands/inbox.ts` — CodeRabbit MAJOR remediation: `buildInboxTaskSummaries` dropped backlog-only tasks",
      "- `src/cli/__tests__/inbox-tui-contracts.test.ts` — regression tests for the inbox expansion",
      ""
    ].join("\n");

    expect(reportJustifiesOutOfScope(report, "src/cli/commands/inbox.ts")).toBe(true);
    expect(reportJustifiesOutOfScope(report, "src/cli/__tests__/inbox-tui-contracts.test.ts")).toBe(true);
    expect(reportJustifiesOutOfScope(report, "packages/foreman_server/lib/foreman_server/overwatch.ex")).toBe(false);
  });

  it("accepts Scope Expansions even when file appears under Edit First with line range", () => {
    // The explorer lists BoardPane.ts with line numbers, so BoardPane.ts is explicitly
    // in scope; the developer should be able to cite it in Scope Expansions for clarity
    // without finalize flagging it as just "redundant" justification.
    const report = [
      "## Scope Expansions",
      "- `src/cli/super-tui/panes/BoardPane.ts` — in Explorer scope (lines 17-37), listed for transparency"
    ].join("\n");

    expect(reportJustifiesOutOfScope(report, "src/cli/super-tui/panes/BoardPane.ts")).toBe(true);
  });

  it("selects domain validation for non-TypeScript changed files", () => {
    expect(finalizeValidationCommands([
      "packages/foreman_server/lib/foreman_server/overwatch.ex",
      "clients/cockpit/view.go",
      "src/defaults/prompts/default/developer.md",
    ])).toEqual([
      "cd packages/foreman_server && mix test",
      "cd clients/cockpit && go test ./...",
      "npx vitest run src/orchestrator/__tests__/workflow-loader.test.ts src/orchestrator/__tests__/workflow-remediation-routing.test.ts --reporter=dot",
    ]);
  });
});
