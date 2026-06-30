import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";

const root = process.cwd();
const threshold = 70;
const coverageDir = join(root, ".foreman", "coverage");
const nodeSummaryPath = join(coverageDir, "coverage-summary.json");
const transitionSummaryPath = join(coverageDir, "transition-scope-summary.json");

const nodeFrontendScope = [
  "src/cli/commands/board.ts",
  "src/cli/commands/cli-output.ts",
  "src/cli/commands/create-from-text.ts",
  "src/cli/commands/daemon.ts",
  "src/cli/commands/debug.ts",
  "src/cli/commands/import.ts",
  "src/cli/commands/inbox.ts",
  "src/cli/commands/local-store-adapter.ts",
  "src/cli/commands/logs.ts",
  "src/cli/commands/mcp.ts",
  "src/cli/commands/pr.ts",
  "src/cli/commands/project-context.ts",
  "src/cli/commands/project-task-support.ts",
  "src/cli/commands/recover.ts",
  "src/cli/commands/server.ts",
  "src/cli/commands/stop.ts",
  "src/cli/commands/task.ts",
  "src/cli/commands/watch/render.ts",
  "src/cli/commands/worktree.ts",
  "src/cli/legacy-coexistence.ts",
  "src/lib/backend-mode.ts",
  "src/lib/beads-rust.ts",
  "src/lib/elixir-server-client.ts",
  "src/lib/elixir-server-manager.ts",
  "src/lib/native-task-client.ts",
  "src/lib/pr-state.ts",
  "src/lib/priority.ts",
  "src/lib/project-mail-client.ts",
  "src/lib/project-targeting.ts",
  "src/lib/registered-project-checkout.ts",
  "src/lib/run-status.ts",
  "src/lib/setup.ts",
  "src/lib/task-client-factory.ts",
  "src/lib/workflow-loader.ts",
  "src/lib/workspace-paths.ts",
  "src/orchestrator/trd-parser.ts",
];

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? root,
    stdio: options.capture ? "pipe" : "inherit",
    encoding: "utf8",
    env: process.env,
  });
  if (!options.allowFailure && result.status !== 0) {
    process.exit(result.status ?? 1);
  }
  return result;
}

function pct(covered, total) {
  return total === 0 ? 100 : Number(((covered / total) * 100).toFixed(2));
}

function parseElixirCoverage(output) {
  const match = output.match(/^\s*([0-9]+(?:\.[0-9]+)?)%\s+\| Total\s*$/m);
  if (!match) {
    throw new Error("Could not parse Elixir coverage total from mix test --cover output");
  }
  return Number(match[1]);
}

function elixirModuleHtmlName(relativePath) {
  const withoutPrefix = relativePath.replace(/^lib\/foreman_server\/?/, "").replace(/\.ex$/, "");
  if (withoutPrefix === "") return "Elixir.ForemanServer.html";
  const moduleSuffix = withoutPrefix
    .split("/")
    .map((segment) => segment.split("_").map((part) => `${part.charAt(0).toUpperCase()}${part.slice(1)}`).join(""))
    .join(".");
  return `Elixir.ForemanServer.${moduleSuffix}.html`;
}

function parseCoverHtmlHits(html) {
  const hits = new Map();
  const rowPattern = /<tr(?: class="([^"]+)")?>\s*<td class="line" id="L(\d+)"[\s\S]*?<td class="hits">([^<]*)<\/td>/g;
  let match;
  while ((match = rowPattern.exec(html)) !== null) {
    const cssClass = match[1] ?? "";
    const hitText = match[3].trim();
    hits.set(Number(match[2]), cssClass.includes("hit") && hitText !== "" && hitText !== "0");
  }
  return hits;
}

function walkElixirFiles(dir) {
  return readdirSync(dir).flatMap((entry) => {
    const fullPath = join(dir, entry);
    const stat = statSync(fullPath);
    if (stat.isDirectory()) return walkElixirFiles(fullPath);
    return fullPath.endsWith(".ex") ? [fullPath] : [];
  });
}

function elixirBranchCoverage() {
  const serverRoot = join(root, "packages", "foreman_server");
  const libRoot = join(serverRoot, "lib");
  const coverRoot = join(serverRoot, "cover");
  const branchSitePattern = /\b(if|unless|case|cond|with)\b/;
  let total = 0;
  let covered = 0;
  const files = [];

  for (const absolutePath of walkElixirFiles(libRoot)) {
    const relativePath = absolutePath.slice(serverRoot.length + 1);
    const htmlPath = join(coverRoot, elixirModuleHtmlName(relativePath));
    if (!existsSync(htmlPath)) continue;
    const hits = parseCoverHtmlHits(readFileSync(htmlPath, "utf8"));
    const sourceLines = readFileSync(absolutePath, "utf8").split("\n");
    let fileTotal = 0;
    let fileCovered = 0;
    sourceLines.forEach((line, index) => {
      if (line.trim().startsWith("#") || !branchSitePattern.test(line)) return;
      fileTotal += 1;
      if (hits.get(index + 1)) fileCovered += 1;
    });
    if (fileTotal > 0) {
      total += fileTotal;
      covered += fileCovered;
      files.push({ path: relativePath, total: fileTotal, covered: fileCovered, pct: pct(fileCovered, fileTotal) });
    }
  }

  return { total, covered, pct: pct(covered, total), files: files.sort((a, b) => a.path.localeCompare(b.path)) };
}

run("npm", ["run", "test:coverage:ci"]);

const nodeSummary = JSON.parse(readFileSync(nodeSummaryPath, "utf8"));
const nodeTotals = {
  lines: { total: 0, covered: 0, pct: 0 },
  branches: { total: 0, covered: 0, pct: 0 },
};
const nodeFiles = [];
for (const [absolutePath, fileSummary] of Object.entries(nodeSummary)) {
  if (absolutePath === "total") continue;
  const relativePath = absolutePath.startsWith(`${root}/`) ? absolutePath.slice(root.length + 1) : absolutePath;
  if (!nodeFrontendScope.includes(relativePath)) continue;
  nodeFiles.push(relativePath);
  for (const key of ["lines", "branches"]) {
    nodeTotals[key].total += fileSummary[key].total;
    nodeTotals[key].covered += fileSummary[key].covered;
  }
}
for (const key of ["lines", "branches"]) {
  nodeTotals[key].pct = pct(nodeTotals[key].covered, nodeTotals[key].total);
}

const mixResult = run("mix", ["test", "--cover"], {
  cwd: join(root, "packages", "foreman_server"),
  capture: true,
  allowFailure: true,
});
process.stdout.write(mixResult.stdout ?? "");
process.stderr.write(mixResult.stderr ?? "");
if (mixResult.status !== 0 && !/Coverage test failed, threshold not met/.test(`${mixResult.stdout ?? ""}\n${mixResult.stderr ?? ""}`)) {
  process.exit(mixResult.status ?? 1);
}
const elixirLinePct = parseElixirCoverage(`${mixResult.stdout ?? ""}\n${mixResult.stderr ?? ""}`);
const elixirBranch = elixirBranchCoverage();

const summary = {
  threshold,
  generatedAt: new Date().toISOString(),
  nodeFrontendScope: {
    description: "Node frontend/operator CLI files and supporting frontend libraries that participate in default Elixir-backed operator workflows, legacy-gating, import/cutover, and task/run/event projections. Legacy Node backend-only daemon/orchestrator/store internals remain outside this transition coverage target.",
    files: nodeFiles.sort(),
    lines: nodeTotals.lines,
    branches: nodeTotals.branches,
  },
  elixirBackendScope: {
    description: "Elixir backend coverage from mix test --cover. Line coverage is Mix's reported total; branch coverage is a repo-local branch-site report over Elixir decision constructs (if/unless/case/cond/with) using the same cover HTML hit data.",
    lines: { pct: elixirLinePct },
    branches: elixirBranch,
  },
  pass: nodeTotals.lines.pct >= threshold && nodeTotals.branches.pct >= threshold && elixirLinePct >= threshold && elixirBranch.pct >= threshold,
};

mkdirSync(coverageDir, { recursive: true });
writeFileSync(transitionSummaryPath, `${JSON.stringify(summary, null, 2)}\n`);
console.log(`Transition coverage summary written to ${transitionSummaryPath}`);
console.log(`Node frontend scope: lines ${nodeTotals.lines.pct}%, branches ${nodeTotals.branches.pct}%`);
console.log(`Elixir backend scope: lines ${elixirLinePct}%, branches ${elixirBranch.pct}%`);

if (!summary.pass) {
  process.exit(1);
}
