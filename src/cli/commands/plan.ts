import { Command } from "commander";
import chalk from "chalk";
import { readFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";

export const planCommand = new Command("plan")
  .description("Decompose a PRD into beads")
  .argument("<prd>", "Path to PRD file or inline text")
  .action(async (prd: string) => {
    let content: string;

    // Check if it's a file path
    const resolved = resolve(prd);
    if (existsSync(resolved)) {
      content = readFileSync(resolved, "utf-8");
      console.log(chalk.dim(`Reading PRD from: ${resolved}`));
    } else {
      // Treat as inline text
      content = prd;
      console.log(chalk.dim("Using inline PRD text"));
    }

    const lines = content.split("\n").length;
    const chars = content.length;
    console.log(
      chalk.dim(`PRD summary: ${lines} lines, ${chars} characters\n`),
    );

    console.log(chalk.bold("Decomposing PRD into tasks..."));
    // TODO: Send to LLM for decomposition into beads
    console.log(chalk.yellow("(LLM decomposition not yet implemented)"));
  });
