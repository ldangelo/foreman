import { existsSync, mkdirSync, readdirSync, copyFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Command } from "commander";
import chalk from "chalk";
import { getForemanHomePath } from "../../lib/foreman-paths.js";
import { getBundledWorkflowPath, listAvailableWorkflows, listBundledWorkflowNames, loadWorkflowConfig, validateTaskTypeUniqueness } from "../../lib/workflow-loader.js";

export interface WorkflowListRow {
  workflow: string;
  source: "project" | "global" | "bundled" | "missing";
  path: string | null;
}

export function isSafeWorkflowName(workflow: string): boolean {
  return /^[A-Za-z0-9._-]+$/.test(workflow) && workflow.length > 0;
}

function workflowNameFromFile(file: string): string {
  return file.replace(/\.ya?ml$/i, "");
}

function workflowFiles(dir: string): string[] {
  try {
    return readdirSync(dir).filter((file) => file.endsWith(".yaml") || file.endsWith(".yml"));
  } catch {
    return [];
  }
}

function firstExisting(candidates: string[]): string | undefined {
  return candidates.find((candidate) => existsSync(candidate));
}

export function workflowCandidates(projectPath: string, workflow: string): [string, string, string, string] {
  return [
    join(projectPath, ".foreman", "workflows", `${workflow}.yaml`),
    join(projectPath, ".foreman", "workflows", `${workflow}.yml`),
    getForemanHomePath("workflows", `${workflow}.yaml`),
    getForemanHomePath("workflows", `${workflow}.yml`),
  ];
}

export function listWorkflows(projectPath: string): WorkflowListRow[] {
  const names = new Set<string>(listAvailableWorkflows(projectPath));
  for (const file of workflowFiles(join(projectPath, ".foreman", "workflows"))) names.add(workflowNameFromFile(file));
  for (const file of workflowFiles(getForemanHomePath("workflows"))) names.add(workflowNameFromFile(file));

  return [...names].sort().map((workflow) => {
    const [projectYaml, projectYml, globalYaml, globalYml] = workflowCandidates(projectPath, workflow);
    const projectPathResolved = firstExisting([projectYaml, projectYml]);
    if (projectPathResolved) return { workflow, source: "project", path: projectPathResolved };
    const globalPathResolved = firstExisting([globalYaml, globalYml]);
    if (globalPathResolved) return { workflow, source: "global", path: globalPathResolved };
    const bundled = getBundledWorkflowPath(workflow);
    return { workflow, source: bundled ? "bundled" : "missing", path: bundled };
  });
}

export function workflowStub(workflow: string): string {
  return `name: ${workflow}\nkind: task\nversion: 1\n# Optional: task_type: ${workflow}\nphases:\n  - name: prepare-worktree\n    action: prepare-worktree\n  - name: setup-workspace\n    action: setup-workspace\n  - name: write-task-context\n    action: write-task-context\n  - name: developer\n    action: prompt-agent\n    prompt: developer.md\n    model: sonnet\n    maxTurns: 80\n  - name: qa\n    action: prompt-agent\n    prompt: qa.md\n    model: sonnet\n    verdict: true\n    retryWith: developer\n    retryOnFail: 2\n  - name: finalize\n    action: finalize\n    builtin: true\n`;
}

function installBundledWorkflowsToDir(destDir: string, force = false): { installed: string[]; skipped: string[] } {
  const installed: string[] = [];
  const skipped: string[] = [];
  mkdirSync(destDir, { recursive: true });
  for (const name of listBundledWorkflowNames()) {
    const src = getBundledWorkflowPath(name);
    if (!src) continue;
    const file = `${name}.yaml`;
    const dest = join(destDir, file);
    if (existsSync(dest) && !force) skipped.push(file);
    else {
      copyFileSync(src, dest);
      installed.push(file);
    }
  }
  return { installed, skipped };
}

export function validateWorkflows(projectPath: string): { ok: boolean; invalid: string[] } {
  const invalid: string[] = [];
  const seen = new Set<string>();
  const validate = (label: string, workflowRef: string) => {
    if (seen.has(`${label}:${workflowRef}`)) return;
    seen.add(`${label}:${workflowRef}`);
    try {
      loadWorkflowConfig(workflowRef, projectPath);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      invalid.push(`${label}: ${msg}`);
    }
  };

  for (const file of workflowFiles(join(projectPath, ".foreman", "workflows"))) {
    const workflow = workflowNameFromFile(file);
    if (!isSafeWorkflowName(workflow)) invalid.push(`project/${file}: unsafe workflow name`);
    validate(`project/${file}`, join(projectPath, ".foreman", "workflows", file));
  }
  for (const file of workflowFiles(getForemanHomePath("workflows"))) {
    const workflow = workflowNameFromFile(file);
    if (!isSafeWorkflowName(workflow)) invalid.push(`global/${file}: unsafe workflow name`);
    validate(`global/${file}`, getForemanHomePath("workflows", file));
  }
  for (const workflow of listAvailableWorkflows(projectPath)) {
    validate(workflow, workflow);
  }

  const taskTypes = validateTaskTypeUniqueness(projectPath);
  for (const duplicate of taskTypes.duplicates) {
    invalid.push(`task_type/${duplicate.taskType}: declared by multiple workflows: ${duplicate.workflows.join(", ")}`);
  }
  return { ok: invalid.length === 0, invalid };
}

export const workflowsCommand = new Command("workflows")
  .description("Manage Foreman workflow YAML files");

workflowsCommand
  .command("list")
  .description("List bundled, project, and global workflows")
  .option("--json", "Output JSON")
  .action((opts: { json?: boolean }) => {
    const rows = listWorkflows(process.cwd());
    if (opts.json) {
      console.log(JSON.stringify(rows, null, 2));
      return;
    }
    for (const row of rows) {
      const sourceLabel = row.source.padEnd(10);
      const source = row.source === "project" ? chalk.green(sourceLabel) : row.source === "global" ? chalk.cyan(sourceLabel) : chalk.dim(sourceLabel);
      console.log(`${row.workflow.padEnd(22)} ${source} ${row.path ?? ""}`);
    }
  });

workflowsCommand
  .command("show")
  .description("Show the resolved workflow path/source")
  .argument("<workflow>", "Workflow name")
  .option("--json", "Output JSON")
  .action((workflow: string, opts: { json?: boolean }) => {
    const row = listWorkflows(process.cwd()).find((candidate) => candidate.workflow === workflow)
      ?? { workflow, source: "missing" as const, path: null };
    if (!isSafeWorkflowName(workflow)) {
      if (opts.json) console.log(JSON.stringify({ ...row, error: "unsafe workflow name" }, null, 2));
      else console.error(chalk.red(`Unsafe workflow name: ${workflow}`));
      process.exitCode = 1;
      return;
    }
    if (opts.json) {
      console.log(JSON.stringify(row, null, 2));
      return;
    }
    if (row.source === "missing") {
      console.error(chalk.red(`Workflow not found: ${workflow}`));
      process.exitCode = 1;
      return;
    }
    console.log(`${row.workflow}: ${row.path ?? row.source}`);
  });

workflowsCommand
  .command("validate")
  .description("Validate loadable project, global, and bundled workflows")
  .option("--json", "Output JSON")
  .action((opts: { json?: boolean }) => {
    const result = validateWorkflows(process.cwd());
    if (opts.json) console.log(JSON.stringify(result, null, 2));
    else if (result.ok) console.log(chalk.green("Workflows valid"));
    else console.error(chalk.red(`Invalid workflows:\n${result.invalid.join("\n")}`));
    if (!result.ok) process.exitCode = 1;
  });

workflowsCommand
  .command("install")
  .description("Install bundled editable workflow YAML files")
  .option("--force", "Overwrite existing workflow files")
  .option("--global", "Install into ~/.foreman/workflows instead of project .foreman/workflows")
  .option("--json", "Output JSON")
  .action((opts: { force?: boolean; global?: boolean; json?: boolean }) => {
    const dest = opts.global ? getForemanHomePath("workflows") : join(process.cwd(), ".foreman", "workflows");
    const result = installBundledWorkflowsToDir(dest, !!opts.force);
    if (opts.json) console.log(JSON.stringify(result, null, 2));
    else console.log(`Installed ${result.installed.length} workflow(s); skipped ${result.skipped.length}.`);
  });

workflowsCommand
  .command("create")
  .description("Create a project workflow YAML stub")
  .argument("<workflow>", "Workflow name")
  .option("--force", "Overwrite an existing workflow file")
  .option("--global", "Create in ~/.foreman/workflows instead of project .foreman/workflows")
  .option("--json", "Output JSON")
  .action((workflow: string, opts: { force?: boolean; global?: boolean; json?: boolean }) => {
    if (!isSafeWorkflowName(workflow)) {
      if (opts.json) console.log(JSON.stringify({ workflow, created: false, error: "unsafe workflow name" }, null, 2));
      else console.error(chalk.red(`Unsafe workflow name: ${workflow}`));
      process.exitCode = 1;
      return;
    }
    const destDir = opts.global ? getForemanHomePath("workflows") : join(process.cwd(), ".foreman", "workflows");
    const path = join(destDir, `${workflow}.yaml`);
    mkdirSync(destDir, { recursive: true });
    if (existsSync(path) && !opts.force) {
      const result = { workflow, path, created: false, reason: "exists" };
      if (opts.json) console.log(JSON.stringify(result, null, 2));
      else console.error(chalk.yellow(`Workflow already exists: ${path} (use --force to overwrite)`));
      process.exitCode = 1;
      return;
    }
    writeFileSync(path, workflowStub(workflow), "utf8");
    const result = { workflow, path, created: true };
    if (opts.json) console.log(JSON.stringify(result, null, 2));
    else console.log(`Created workflow: ${path}`);
  });
