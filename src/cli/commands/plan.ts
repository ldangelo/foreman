import { Command } from "commander";
import chalk from "chalk";
import { readFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";

import { BeadsClient } from "../../lib/beads.js";
import { ForemanStore } from "../../lib/store.js";
import { Dispatcher } from "../../orchestrator/dispatcher.js";
import type { PlanStepDefinition } from "../../orchestrator/types.js";

export const planCommand = new Command("plan")
  .description(
    "Run Ensemble PRD → TRD pipeline (create-prd, refine-prd, create-trd, refine-trd)",
  )
  .argument(
    "<description>",
    "Product description text or path to a description file",
  )
  .option(
    "--prd-only",
    "Stop after PRD creation and refinement (skip TRD)",
  )
  .option(
    "--from-prd <path>",
    "Skip PRD creation, start from existing PRD file",
  )
  .option(
    "--output-dir <dir>",
    "Directory to save PRD/TRD output (default: ./docs)",
    "./docs",
  )
  .option(
    "--runtime <runtime>",
    "AI runtime to use (claude-code | codex)",
    "claude-code",
  )
  .option("--dry-run", "Show the pipeline steps without executing")
  .action(
    async (
      description: string,
      opts: {
        prdOnly?: boolean;
        fromPrd?: string;
        outputDir: string;
        runtime: string;
        dryRun?: boolean;
      },
    ) => {
      const outputDir = resolve(opts.outputDir);
      const projectPath = resolve(".");

      // Determine input
      let productDescription: string;
      const resolvedPath = resolve(description);
      if (existsSync(resolvedPath)) {
        productDescription = readFileSync(resolvedPath, "utf-8");
        console.log(chalk.dim(`Reading description from: ${resolvedPath}`));
      } else {
        productDescription = description;
      }

      // Initialize clients
      const store = new ForemanStore();
      const beads = new BeadsClient(projectPath);
      const dispatcher = new Dispatcher(beads, store, projectPath);

      try {
        // Ensure project is registered
        const project = store.getProjectByPath(projectPath);
        if (!project) {
          console.error(
            chalk.red(
              "No project registered for this directory. Run 'foreman init' first.",
            ),
          );
          process.exitCode = 1;
          return;
        }

        // Validate --from-prd path
        if (opts.fromPrd) {
          const prdPath = resolve(opts.fromPrd);
          if (!existsSync(prdPath)) {
            console.error(chalk.red(`PRD file not found: ${prdPath}`));
            process.exitCode = 1;
            return;
          }
          console.log(chalk.dim(`Using existing PRD: ${prdPath}\n`));
        }

        // Build pipeline step definitions
        const steps = buildPipelineSteps(
          productDescription,
          outputDir,
          opts.fromPrd,
          opts.prdOnly,
        );

        // Display pipeline
        console.log(chalk.bold.cyan("\n Planning Pipeline\n"));
        console.log(
          chalk.dim(`Runtime: ${opts.runtime} | Output: ${outputDir}\n`),
        );
        for (let i = 0; i < steps.length; i++) {
          const step = steps[i];
          const num = `${i + 1}`.padStart(2);
          console.log(
            `  ${chalk.bold(`${num}.`)} ${chalk.cyan(step.name)} ${chalk.dim(`(${step.command})`)}`,
          );
          console.log(chalk.dim(`      ${step.description}`));
        }

        if (opts.dryRun) {
          console.log(
            chalk.yellow("\n--dry-run: Pipeline not executed."),
          );
          console.log(
            chalk.dim(
              "\nWhen run without --dry-run, Foreman will:",
            ),
          );
          console.log(chalk.dim("  1. Create an epic bead with child beads (sequential dependencies)"));
          console.log(chalk.dim("  2. Dispatch each step via Claude Code + Ensemble"));
          console.log(chalk.dim("  3. Track progress in SQLite"));
          console.log(chalk.dim("  4. Suggest 'foreman decompose' on completion"));
          return;
        }

        // Create epic bead
        const epicTitle = `Plan: ${productDescription.slice(0, 80)}${productDescription.length > 80 ? "..." : ""}`;
        const epic = await beads.create(epicTitle, {
          type: "epic",
          priority: "P1",
          description: `Planning pipeline for: ${productDescription.slice(0, 200)}`,
        });
        console.log(
          chalk.dim(`\nEpic bead: ${epic.id} — ${epicTitle}`),
        );

        // Create child beads with sequential dependencies
        const beadIds: string[] = [];
        for (let i = 0; i < steps.length; i++) {
          const step = steps[i];
          const child = await beads.create(step.name, {
            type: "task",
            priority: "P1",
            parent: epic.id,
            description: `${step.command} ${step.input}`,
          });

          // Add dependency on the previous bead (sequential chain)
          if (i > 0) {
            await beads.addDependency(child.id, beadIds[i - 1]);
          }

          beadIds.push(child.id);
          console.log(
            chalk.dim(
              `  Bead ${child.id}: ${step.name}${i > 0 ? ` (depends on ${beadIds[i - 1]})` : " (ready)"}`,
            ),
          );
        }

        // Sequential dispatch loop
        console.log(chalk.bold("\n Starting pipeline...\n"));
        const beadIdSet = new Set(beadIds);
        let completedCount = 0;

        while (completedCount < beadIds.length) {
          // Find ready beads that belong to our epic
          const readyBeads = await beads.ready();
          const epicReady = readyBeads.filter((b) => beadIdSet.has(b.id));

          if (epicReady.length === 0) {
            // No ready beads yet — poll until one becomes ready
            await sleep(10_000);
            continue;
          }

          for (const readyBead of epicReady) {
            const stepIndex = beadIds.indexOf(readyBead.id);
            const step = steps[stepIndex];
            console.log(
              chalk.bold(
                `\n[${completedCount + 1}/${beadIds.length}] ${step.name}...`,
              ),
            );

            try {
              const result = await dispatcher.dispatchPlanStep(
                project.id,
                {
                  id: readyBead.id,
                  title: readyBead.title,
                  type: readyBead.type,
                  priority: readyBead.priority,
                },
                step.command,
                step.input,
                outputDir,
              );

              // Close the bead on success
              await beads.close(readyBead.id, "Completed");
              console.log(
                chalk.green(
                  `  ${step.name} complete (run: ${result.runId})`,
                ),
              );
              completedCount++;
            } catch (err: unknown) {
              const message = err instanceof Error ? err.message : String(err);
              console.error(
                chalk.red(`  ${step.name} failed: ${message}`),
              );
              console.log(
                chalk.yellow(
                  "\nPipeline paused. Fix the issue and re-run with --from-prd if needed.",
                ),
              );
              process.exitCode = 1;
              return;
            }
          }
        }

        // All done — close the epic
        await beads.close(epic.id, "All planning steps completed");
        console.log(chalk.bold.green("\n Planning pipeline complete!"));
        console.log(chalk.dim(`\nOutputs in: ${outputDir}`));
        console.log(chalk.dim(`Epic: ${epic.id}`));
        if (!opts.prdOnly) {
          console.log(
            chalk.dim(
              `\nNext step: foreman decompose ${outputDir}/TRD.md`,
            ),
          );
        }
      } finally {
        store.close();
      }
    },
  );

// ── Helpers ──────────────────────────────────────────────────────────────

function buildPipelineSteps(
  productDescription: string,
  outputDir: string,
  fromPrd: string | undefined,
  prdOnly: boolean | undefined,
): PlanStepDefinition[] {
  const steps: PlanStepDefinition[] = [];

  if (!fromPrd) {
    steps.push({
      name: "Create PRD",
      command: "/ensemble:create-prd",
      description:
        "Analyze product description, define users, goals, and requirements",
      input: productDescription,
    });
    steps.push({
      name: "Refine PRD",
      command: "/ensemble:refine-prd",
      description:
        "Review and strengthen acceptance criteria, edge cases, constraints",
      input: `Review and refine the PRD in ${outputDir}`,
    });
  }

  if (!prdOnly) {
    steps.push({
      name: "Create TRD",
      command: "/ensemble:create-trd",
      description:
        "Translate PRD into technical architecture, task breakdown, sprint planning",
      input: fromPrd
        ? resolve(fromPrd)
        : `${outputDir}/PRD.md`,
    });
    steps.push({
      name: "Refine TRD",
      command: "/ensemble:refine-trd",
      description:
        "Review technical decisions, validate task dependencies, refine estimates",
      input: `Review and refine the TRD in ${outputDir}`,
    });
  }

  return steps;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
