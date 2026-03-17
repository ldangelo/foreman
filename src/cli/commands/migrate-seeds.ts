import { Command } from "commander";
import chalk from "chalk";
import { readFileSync, existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { BeadsRustClient, type BrIssue } from "../../lib/beads-rust.js";
import { formatPriorityForBr } from "../../lib/priority.js";

// ── Types ─────────────────────────────────────────────────────────────────

interface SeedIssue {
  id: string;
  title: string;
  type: string;
  priority: string;
  status: string;
  description?: string;
  dependencies?: string[];
}

export interface MigrationResult {
  created: number;
  skipped: number;
  failed: number;
  closed: number;
  planned: number;
  reportPath: string;
}

/** Minimal interface used by runMigration — allows injection in tests. */
export interface BrClientLike {
  ensureBrInstalled(): Promise<void>;
  list(opts?: { limit?: number }): Promise<BrIssue[]>;
  create(title: string, opts?: { type?: string; priority?: string; description?: string }): Promise<BrIssue>;
  close(id: string, reason?: string): Promise<void>;
  addDependency(childId: string, parentId: string): Promise<void>;
}

interface MigrationOpts {
  dryRun: boolean;
  /** Injected client — used in tests; defaults to a real BeadsRustClient when absent. */
  client?: BrClientLike;
}

// ── Exported helpers (used by tests) ─────────────────────────────────────

const VALID_BR_TYPES = new Set([
  "task",
  "bug",
  "feature",
  "epic",
  "chore",
  "decision",
]);

/**
 * Ensure the seed type is a valid br type.
 * Seeds types map 1:1 to br types; fall back to "task" for unknown values.
 */
export function normalizeSeedType(type: string | undefined): string {
  if (type && VALID_BR_TYPES.has(type)) return type;
  return "task";
}

/**
 * Parse the raw content of a .seeds/issues.jsonl file.
 * Returns an array of parsed seed objects, skipping blank lines.
 */
export function parseSeedsJsonl(content: string): SeedIssue[] {
  const seeds: SeedIssue[] = [];
  for (const rawLine of content.split("\n")) {
    const line = rawLine.trim();
    if (!line) continue;
    try {
      const parsed = JSON.parse(line) as SeedIssue;
      seeds.push(parsed);
    } catch {
      // silently skip malformed lines
    }
  }
  return seeds;
}

// ── Core migration logic ──────────────────────────────────────────────────

/**
 * Run the migration from seeds to br.
 * Exported for unit testing (allows mocking BeadsRustClient).
 */
export async function runMigration(
  projectPath: string,
  opts: MigrationOpts,
): Promise<MigrationResult> {
  const seedsJsonlPath = join(projectPath, ".seeds", "issues.jsonl");

  if (!existsSync(seedsJsonlPath)) {
    throw new Error(
      `.seeds/issues.jsonl not found in ${projectPath}. ` +
        "Ensure the project has a Seeds (.seeds) directory to migrate from.",
    );
  }

  const content = readFileSync(seedsJsonlPath, "utf-8");
  const seeds = parseSeedsJsonl(content);
  const reportPath = join(projectPath, "docs", "seeds-migration-report.md");

  // ── Dry-run: report what would happen ──────────────────────────────────

  if (opts.dryRun) {
    console.log(chalk.bold.cyan("\n[dry-run] Seeds that would be migrated:\n"));
    for (const seed of seeds) {
      const priority = formatPriorityForBr(seed.priority);
      console.log(
        `  ${chalk.cyan(seed.id)} — ${chalk.bold(seed.title)} ` +
          chalk.dim(`[${normalizeSeedType(seed.type)} P${priority} ${seed.status}]`),
      );
      if (seed.dependencies?.length) {
        console.log(chalk.dim(`    depends on: ${seed.dependencies.join(", ")}`));
      }
    }
    console.log();
    console.log(chalk.yellow(`--dry-run: no issues created. Would process ${seeds.length} seed(s).`));

    return {
      created: 0,
      skipped: 0,
      failed: 0,
      closed: 0,
      planned: seeds.length,
      reportPath,
    };
  }

  // ── Live run ──────────────────────────────────────────────────────────

  const br: BrClientLike = opts.client ?? new BeadsRustClient(projectPath);
  await br.ensureBrInstalled();

  // Fetch existing br issues to enable idempotency check
  const existingIssues = await br.list({ limit: 0 });
  const existingTitles = new Set(existingIssues.map((i) => i.title));

  // old-seed-id → new-br-id mapping (used for dependency replay)
  const idMap = new Map<string, string>();

  let created = 0;
  let skipped = 0;
  let failed = 0;
  let closed = 0;

  // Track migration details for report
  const reportLines: string[] = [];
  const createdEntries: { seedId: string; brId: string; title: string; wasClosed: boolean }[] = [];
  const skippedEntries: { seedId: string; title: string }[] = [];
  const failedEntries: { seedId: string; title: string; error: string }[] = [];

  // ── Phase 1: create issues ─────────────────────────────────────────────

  for (const seed of seeds) {
    if (existingTitles.has(seed.title)) {
      console.log(chalk.dim(`  skip  ${seed.id} — "${seed.title}" (already exists in br)`));
      // Still track the mapping so deps can reference skipped existing items
      const existingIssue = existingIssues.find((i) => i.title === seed.title);
      if (existingIssue) {
        idMap.set(seed.id, existingIssue.id);
      }
      skipped++;
      skippedEntries.push({ seedId: seed.id, title: seed.title });
      continue;
    }

    try {
      const issue = await br.create(seed.title, {
        type: normalizeSeedType(seed.type),
        priority: formatPriorityForBr(seed.priority),
        description: seed.description,
      });

      idMap.set(seed.id, issue.id);
      created++;

      const wasClosed = seed.status === "closed";
      if (wasClosed) {
        await br.close(issue.id, "Migrated from seeds (was closed)");
        closed++;
      }

      createdEntries.push({ seedId: seed.id, brId: issue.id, title: seed.title, wasClosed });
      console.log(
        chalk.green(`  create ${seed.id} → ${issue.id} — "${seed.title}"`) +
          (wasClosed ? chalk.dim(" [closed]") : ""),
      );
    } catch (err) {
      const errorMsg = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`  fail   ${seed.id} — "${seed.title}": ${errorMsg}`));
      failed++;
      failedEntries.push({ seedId: seed.id, title: seed.title, error: errorMsg });
    }
  }

  // ── Phase 2: replay dependency edges ──────────────────────────────────

  let depsAdded = 0;
  for (const seed of seeds) {
    if (!seed.dependencies?.length) continue;
    const childBrId = idMap.get(seed.id);
    if (!childBrId) continue;

    for (const depSeedId of seed.dependencies) {
      const blockerBrId = idMap.get(depSeedId);
      if (!blockerBrId) {
        console.warn(
          chalk.yellow(
            `  warn   dependency ${depSeedId} for ${seed.id} has no br mapping — skipped`,
          ),
        );
        continue;
      }
      try {
        await br.addDependency(childBrId, blockerBrId);
        depsAdded++;
      } catch (err) {
        console.warn(
          chalk.yellow(
            `  warn   dep ${childBrId} → ${blockerBrId} failed: ${
              err instanceof Error ? err.message : String(err)
            }`,
          ),
        );
      }
    }
  }

  // ── Phase 3: write migration report ───────────────────────────────────

  reportLines.push("# Seeds Migration Report");
  reportLines.push("");
  reportLines.push(`**Date:** ${new Date().toISOString()}`);
  reportLines.push(`**Source:** \`.seeds/issues.jsonl\``);
  reportLines.push("");
  reportLines.push("## Summary");
  reportLines.push("");
  reportLines.push(`| Metric | Count |`);
  reportLines.push(`|--------|-------|`);
  reportLines.push(`| Created | ${created} |`);
  reportLines.push(`| Skipped (already exist) | ${skipped} |`);
  reportLines.push(`| Failed | ${failed} |`);
  reportLines.push(`| Closed after create | ${closed} |`);
  reportLines.push(`| Dependencies added | ${depsAdded} |`);
  reportLines.push("");

  if (createdEntries.length > 0) {
    reportLines.push("## Created Issues");
    reportLines.push("");
    reportLines.push("| Seeds ID | BR ID | Title | Closed |");
    reportLines.push("|----------|-------|-------|--------|");
    for (const e of createdEntries) {
      reportLines.push(`| ${e.seedId} | ${e.brId} | ${e.title} | ${e.wasClosed ? "yes" : "no"} |`);
    }
    reportLines.push("");
  }

  if (skippedEntries.length > 0) {
    reportLines.push("## Skipped Issues (Already Exist)");
    reportLines.push("");
    reportLines.push("| Seeds ID | Title |");
    reportLines.push("|----------|-------|");
    for (const e of skippedEntries) {
      reportLines.push(`| ${e.seedId} | ${e.title} |`);
    }
    reportLines.push("");
  }

  if (failedEntries.length > 0) {
    reportLines.push("## Failed Issues");
    reportLines.push("");
    reportLines.push("| Seeds ID | Title | Error |");
    reportLines.push("|----------|-------|-------|");
    for (const e of failedEntries) {
      reportLines.push(`| ${e.seedId} | ${e.title} | ${e.error} |`);
    }
    reportLines.push("");
  }

  mkdirSync(join(projectPath, "docs"), { recursive: true });
  writeFileSync(reportPath, reportLines.join("\n"), "utf-8");

  return { created, skipped, failed, closed, planned: seeds.length, reportPath };
}

// ── CLI Command ───────────────────────────────────────────────────────────

export const migrateSeedsCommand = new Command("migrate-seeds")
  .description(
    "Migrate seeds (.seeds/issues.jsonl) to beads_rust (br). " +
      "Creates corresponding issues in br, replays dependency edges, and writes a migration report.",
  )
  .option("--dry-run", "Report what would be migrated without creating anything")
  .action(async (opts: { dryRun?: boolean }) => {
    const projectPath = resolve(".");

    console.log(chalk.bold.cyan("foreman migrate-seeds\n"));

    let result: MigrationResult;
    try {
      result = await runMigration(projectPath, { dryRun: opts.dryRun ?? false });
    } catch (err) {
      console.error(
        chalk.red(
          `Migration failed: ${err instanceof Error ? err.message : String(err)}`,
        ),
      );
      process.exitCode = 1;
      return;
    }

    if (!opts.dryRun) {
      console.log();
      console.log(chalk.bold("Migration complete:"));
      console.log(`  Created: ${chalk.green(String(result.created))}`);
      if (result.closed > 0) {
        console.log(`  Closed:  ${chalk.dim(String(result.closed))} (were closed in seeds)`);
      }
      console.log(
        `  Skipped: ${chalk.yellow(String(result.skipped))} (already exist)`,
      );
      console.log(`  Failed:  ${result.failed > 0 ? chalk.red(String(result.failed)) : "0"}`);
      console.log(`  Report:  ${chalk.dim(result.reportPath)}`);
    }
  });
