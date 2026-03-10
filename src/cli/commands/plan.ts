import { Command } from "commander";
import chalk from "chalk";
import { readFileSync, existsSync } from "node:fs";
import { resolve, join } from "node:path";

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

      // Determine input
      let productDescription: string;
      const resolvedPath = resolve(description);
      if (existsSync(resolvedPath)) {
        productDescription = readFileSync(resolvedPath, "utf-8");
        console.log(chalk.dim(`Reading description from: ${resolvedPath}`));
      } else {
        productDescription = description;
      }

      // Define the pipeline
      const pipeline: PipelineStep[] = [];

      if (opts.fromPrd) {
        // Skip PRD steps, start from existing PRD
        const prdPath = resolve(opts.fromPrd);
        if (!existsSync(prdPath)) {
          console.error(chalk.red(`PRD file not found: ${prdPath}`));
          process.exitCode = 1;
          return;
        }
        console.log(chalk.dim(`Using existing PRD: ${prdPath}\n`));
      } else {
        pipeline.push({
          name: "Create PRD",
          command: "/ensemble:create-prd",
          description:
            "Analyze product description, define users, goals, and requirements",
          input: productDescription,
        });
        pipeline.push({
          name: "Refine PRD",
          command: "/ensemble:refine-prd",
          description:
            "Review and strengthen acceptance criteria, edge cases, constraints",
          input: `Review and refine the PRD in ${outputDir}`,
        });
      }

      if (!opts.prdOnly) {
        pipeline.push({
          name: "Create TRD",
          command: "/ensemble:create-trd",
          description:
            "Translate PRD into technical architecture, task breakdown, sprint planning",
          input: opts.fromPrd
            ? resolve(opts.fromPrd)
            : `${outputDir}/PRD.md`,
        });
        pipeline.push({
          name: "Refine TRD",
          command: "/ensemble:refine-trd",
          description:
            "Review technical decisions, validate task dependencies, refine estimates",
          input: `Review and refine the TRD in ${outputDir}`,
        });
      }

      // Display pipeline
      console.log(chalk.bold.cyan("\n🔧 Foreman Planning Pipeline\n"));
      console.log(
        chalk.dim(
          `Runtime: ${opts.runtime} | Output: ${outputDir}\n`,
        ),
      );

      for (let i = 0; i < pipeline.length; i++) {
        const step = pipeline[i];
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
            "\nTo execute, remove --dry-run. Each step spawns a Claude Code agent",
          ),
        );
        console.log(
          chalk.dim(
            "via OpenClaw sessions_spawn with the Ensemble slash commands.",
          ),
        );
        return;
      }

      console.log(chalk.bold("\n▶ Starting pipeline...\n"));

      // Execute pipeline steps sequentially
      for (let i = 0; i < pipeline.length; i++) {
        const step = pipeline[i];
        console.log(
          chalk.bold(
            `\n[${i + 1}/${pipeline.length}] ${step.name}...`,
          ),
        );

        try {
          await executeEnsembleStep(step, opts.runtime, outputDir);
          console.log(chalk.green(`  ✓ ${step.name} complete`));
        } catch (err: any) {
          console.error(
            chalk.red(`  ✗ ${step.name} failed: ${err.message}`),
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

      console.log(chalk.bold.green("\n✓ Planning pipeline complete!"));
      console.log(chalk.dim(`\nOutputs in: ${outputDir}`));
      if (!opts.prdOnly) {
        console.log(
          chalk.dim(
            `\nNext step: foreman decompose ${outputDir}/TRD.md`,
          ),
        );
      }
    },
  );

// ── Types ───────────────────────────────────────────────────────────────

interface PipelineStep {
  name: string;
  command: string;
  description: string;
  input: string;
}

// ── Ensemble Execution ──────────────────────────────────────────────────

async function executeEnsembleStep(
  step: PipelineStep,
  runtime: string,
  outputDir: string,
): Promise<void> {
  // Execute via Claude Code CLI with Ensemble slash commands
  // Alternative: Use OpenClaw sessions_spawn with runtime: "acp" for
  // isolated execution if preferred
  const { execFile } = await import("node:child_process");
  const { promisify } = await import("node:util");
  const execFileAsync = promisify(execFile);

  const claudePath =
    process.env.CLAUDE_PATH || "/opt/homebrew/bin/claude";
  const prompt = `${step.command} ${step.input}\n\nSave all outputs to the ${outputDir}/ directory.`;

  try {
    await execFileAsync(
      claudePath,
      [
        "--permission-mode",
        "bypassPermissions",
        "--print",
        prompt,
      ],
      {
        cwd: process.cwd(),
        timeout: 600_000, // 10 minute timeout per step
        maxBuffer: 10 * 1024 * 1024,
      },
    );
  } catch (err: any) {
    if (err.killed) {
      throw new Error("Timed out after 10 minutes");
    }
    // Claude Code may exit with non-zero but still produce output
    if (err.stderr && !err.stdout) {
      throw new Error(err.stderr);
    }
    // If it produced stdout, consider it a success
    console.log(chalk.dim("  (completed with warnings)"));
  }
}
