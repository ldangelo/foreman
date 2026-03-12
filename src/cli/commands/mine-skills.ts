import { Command } from "commander";
import chalk from "chalk";
import { resolve } from "node:path";
import { writeFileSync } from "node:fs";
import { ReportAnalyzer } from "../../orchestrator/report-analyzer.js";
import type { SkillMiningResult, Skill } from "../../orchestrator/types.js";

function renderTable(result: SkillMiningResult): void {
  console.log(chalk.bold("\nSkill Mining Results\n"));

  // Overview
  console.log(chalk.bold("Overview"));
  console.log(`  Reports scanned:     ${chalk.white(result.reportCount)}`);
  console.log(`  Avg completeness:    ${chalk.cyan((result.averageCompleteness * 100).toFixed(1) + "%")}`);
  console.log(
    `  Verdicts:           ${chalk.green(result.verdictDistribution.pass + " pass")}` +
    chalk.dim(" / ") +
    chalk.red(result.verdictDistribution.fail + " fail") +
    chalk.dim(" / ") +
    chalk.yellow(result.verdictDistribution.unknown + " unknown"),
  );
  console.log();

  // Role breakdown
  console.log(chalk.bold("Reports by Role"));
  for (const [role, count] of Object.entries(result.roleBreakdown)) {
    const roleColors: Record<string, (s: string) => string> = {
      explorer: chalk.cyan,
      developer: chalk.green,
      qa: chalk.yellow,
      reviewer: chalk.magenta,
      unknown: chalk.dim,
    };
    const colorFn = roleColors[role] ?? chalk.white;
    console.log(`  ${colorFn(role.padEnd(12))} ${count}`);
  }
  console.log();

  // Top sections
  if (result.sectionFrequency.length > 0) {
    console.log(chalk.bold("Most Common Sections"));
    for (const { section, count, percentage } of result.sectionFrequency.slice(0, 10)) {
      const bar = "█".repeat(Math.round(percentage / 10));
      console.log(`  ${section.padEnd(35)} ${chalk.cyan(bar.padEnd(10))} ${count} (${percentage}%)`);
    }
    console.log();
  }

  // Mined skills
  if (result.skills.length > 0) {
    console.log(chalk.bold("Mined Skills"));
    const categories = ["exploration", "implementation", "testing", "review"] as const;
    for (const cat of categories) {
      const catSkills = result.skills.filter((s: Skill) => s.category === cat);
      if (catSkills.length === 0) continue;

      const catColors: Record<string, (s: string) => string> = {
        exploration: chalk.cyan,
        implementation: chalk.green,
        testing: chalk.yellow,
        review: chalk.magenta,
      };
      const colorFn = catColors[cat] ?? chalk.white;
      console.log(`  ${colorFn(cat.toUpperCase())}`);
      for (const skill of catSkills) {
        const confidence = (skill.confidence * 100).toFixed(0) + "%";
        const successRate = (skill.successRate * 100).toFixed(0) + "%";
        console.log(
          `    ${chalk.white(skill.name.padEnd(35))} ` +
          `seen: ${chalk.cyan(String(skill.frequency).padStart(3))}  ` +
          `success: ${chalk.green(successRate.padStart(4))}  ` +
          `confidence: ${chalk.dim(confidence)}`,
        );
        console.log(`      ${chalk.dim(skill.description)}`);
      }
      console.log();
    }
  } else {
    console.log(chalk.dim("  No skills extracted (need more report data)\n"));
  }
}

export const mineSkillsCommand = new Command("mine-skills")
  .description("Mine patterns and skills from past agent session reports")
  .option("-p, --project <path>", "Project root path (default: current directory)")
  .option("-o, --output <format>", "Output format: table or json (default: table)", "table")
  .option("--save <file>", "Save JSON output to file")
  .action(async (opts: { project?: string; output?: string; save?: string }) => {
    const projectPath = resolve(opts.project ?? ".");
    const outputFormat = opts.output ?? "table";

    const analyzer = new ReportAnalyzer(projectPath);
    const result = analyzer.analyze();

    if (outputFormat === "json" || opts.save) {
      const json = JSON.stringify(result, null, 2);
      if (opts.save) {
        writeFileSync(opts.save, json, "utf-8");
        console.log(chalk.green(`✓ Saved to ${opts.save}`));
      }
      if (outputFormat === "json") {
        console.log(json);
        return;
      }
    }

    renderTable(result);
  });
