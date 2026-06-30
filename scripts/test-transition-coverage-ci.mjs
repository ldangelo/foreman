import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";

const root = process.cwd();
const threshold = 70;
const coverageDir = join(root, ".foreman", "coverage");
const nodeSummaryPath = join(coverageDir, "coverage-summary.json");
const transitionSummaryPath = join(coverageDir, "transition-scope-summary.json");

const nodeFrontendScope = [
  "src/cli/commands/project-task-support.ts",
  "src/lib/backend-mode.ts",
  "src/lib/elixir-server-client.ts",
  "src/lib/native-task-client.ts",
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

const summary = {
  threshold,
  generatedAt: new Date().toISOString(),
  nodeFrontendScope: {
    description: "Node frontend files that enforce backend mode, resolve Elixir-backed project/task context, and call Elixir-backed task/event APIs for default operator workflows. Legacy Node backend-only daemon/orchestrator/store paths are intentionally outside this transition coverage target.",
    files: nodeFiles.sort(),
    lines: nodeTotals.lines,
    branches: nodeTotals.branches,
  },
  elixirBackendScope: {
    description: "Elixir backend coverage reported by mix test --cover. Mix's built-in cover tool reports line coverage, not branch coverage.",
    lines: { pct: elixirLinePct },
  },
  pass: nodeTotals.lines.pct >= threshold && nodeTotals.branches.pct >= threshold && elixirLinePct >= threshold,
};

mkdirSync(coverageDir, { recursive: true });
writeFileSync(transitionSummaryPath, `${JSON.stringify(summary, null, 2)}\n`);
console.log(`Transition coverage summary written to ${transitionSummaryPath}`);
console.log(`Node frontend scope: lines ${nodeTotals.lines.pct}%, branches ${nodeTotals.branches.pct}%`);
console.log(`Elixir backend scope: lines ${elixirLinePct}%`);

if (!summary.pass) {
  process.exit(1);
}
