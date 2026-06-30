import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import istanbulCoverage from "istanbul-lib-coverage";
import libReport from "istanbul-lib-report";
import reports from "istanbul-reports";

const { createCoverageMap } = istanbulCoverage;

const root = process.cwd();
const coverageDir = join(root, ".foreman", "coverage");
const rawDir = join(coverageDir, "raw");

const lanes = [
  { name: "unit", config: "vitest.unit.config.ts" },
  { name: "integration", config: "vitest.integration.config.ts" },
  { name: "e2e-smoke", config: "vitest.e2e.smoke.config.ts" },
  { name: "e2e-full-run", config: "vitest.e2e.full-run.config.ts" },
];

function run(command, args) {
  const result = spawnSync(command, args, {
    cwd: root,
    stdio: "inherit",
    env: process.env,
  });

  if (result.status !== 0) {
    process.exit(result.status ?? 1);
  }
}

rmSync(coverageDir, { recursive: true, force: true });
mkdirSync(rawDir, { recursive: true });

for (const lane of lanes) {
  const reportsDir = join(rawDir, lane.name);
  run("npx", [
    "vitest",
    "run",
    "-c",
    lane.config,
    "--coverage.enabled",
    "--coverage.provider=v8",
    "--coverage.reporter=json",
    `--coverage.reportsDirectory=${reportsDir}`,
  ]);
}

const coverageMap = createCoverageMap({});
for (const lane of lanes) {
  const reportPath = join(rawDir, lane.name, "coverage-final.json");
  coverageMap.merge(JSON.parse(readFileSync(reportPath, "utf8")));
}

writeFileSync(join(coverageDir, "coverage-final.json"), JSON.stringify(coverageMap.toJSON(), null, 2));
writeFileSync(join(coverageDir, "coverage-summary.json"), JSON.stringify({ total: coverageMap.getCoverageSummary().toJSON() }, null, 2));

const context = libReport.createContext({
  dir: coverageDir,
  coverageMap,
});

for (const reporter of ["text-summary", "json-summary", "lcov"]) {
  reports.create(reporter).execute(context);
}
