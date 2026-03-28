import { Command } from "commander";
import chalk from "chalk";
import ora from "ora";
import { readFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import { execFileSync } from "node:child_process";
import { BeadsRustClient } from "../../lib/beads-rust.js";
import { normalizePriority } from "../../lib/priority.js";
// ── Client factory (TRD-015) ──────────────────────────────────────────────
/**
 * Instantiate the br task-tracking client.
 *
 * TRD-024: sd backend removed. Always returns a BeadsRustClient.
 *
 * Exported for unit testing.
 */
export function createBeadClient(projectPath) {
    return new BeadsRustClient(projectPath);
}
// ── Command ──────────────────────────────────────────────────────────────
export const beadCommand = new Command("bead")
    .description("Create beads from natural-language description")
    .argument("<description>", "Natural language description (or path to a file)")
    .option("--type <type>", "Force issue type (task|bug|feature|epic|chore|decision)")
    .option("--priority <priority>", "Force priority (P0-P4)")
    .option("--parent <id>", "Parent bead ID")
    .option("--dry-run", "Show what would be created without creating beads")
    .option("--no-llm", "Skip LLM parsing — create a single bead with the text as title")
    .option("--model <model>", "Claude model to use for parsing")
    .action(async (description, opts) => {
    const projectPath = resolve(".");
    // Resolve input: file path or inline text
    let inputText;
    const resolvedPath = resolve(description);
    if (existsSync(resolvedPath)) {
        inputText = readFileSync(resolvedPath, "utf-8");
        console.log(chalk.dim(`Reading description from: ${resolvedPath}`));
    }
    else {
        inputText = description;
    }
    // Initialise BeadsRust task client
    const beads = createBeadClient(projectPath);
    // Validate prerequisites
    try {
        await beads.ensureBrInstalled();
    }
    catch (err) {
        console.error(chalk.red(err instanceof Error ? err.message : String(err)));
        process.exitCode = 1;
        return;
    }
    if (!(await beads.isInitialized())) {
        console.error(chalk.red(`Beads not initialized in this directory. Run 'foreman init' first.`));
        process.exitCode = 1;
        return;
    }
    // ── Parse input into structured issues ─────────────────────────────
    let parsedIssues;
    if (!opts.llm) {
        // --no-llm: create a single bead directly
        parsedIssues = [
            {
                title: inputText.slice(0, 200),
                description: inputText.length > 200 ? inputText.slice(200) : undefined,
                type: opts.type,
                priority: opts.priority,
            },
        ];
    }
    else {
        // Use Claude Code CLI to parse the natural-language description
        const spinner = ora("Parsing description with Claude...").start();
        try {
            parsedIssues = await parseWithClaude(inputText, opts.model);
            spinner.succeed(`Parsed ${parsedIssues.length} issue(s)`);
        }
        catch (err) {
            spinner.fail("Failed to parse description");
            console.error(chalk.red(err instanceof Error ? err.message : String(err)));
            process.exitCode = 1;
            return;
        }
    }
    // Apply any forced overrides from CLI options
    // Normalize priority so both sd ("P2") and br ("2") get a consistent value
    const normalizedPriority = opts.priority
        ? `P${normalizePriority(opts.priority)}`
        : undefined;
    for (const issue of parsedIssues) {
        if (opts.type)
            issue.type = opts.type;
        if (normalizedPriority)
            issue.priority = normalizedPriority;
    }
    // ── Display planned beads ──────────────────────────────────────────
    console.log(chalk.bold.cyan(`\n Beads to create:\n`));
    for (const issue of parsedIssues) {
        console.log(`  ${chalk.bold(issue.title)}`);
        if (issue.description) {
            const preview = issue.description.replace(/\n/g, " ").slice(0, 100);
            console.log(chalk.dim(`    ${preview}${issue.description.length > 100 ? "…" : ""}`));
        }
        const meta = [];
        if (issue.type)
            meta.push(`type: ${issue.type}`);
        if (issue.priority)
            meta.push(`priority: ${issue.priority}`);
        if (issue.labels?.length)
            meta.push(`labels: ${issue.labels.join(", ")}`);
        if (issue.dependencies?.length) {
            meta.push(`depends on: ${issue.dependencies.join(", ")}`);
        }
        if (meta.length)
            console.log(chalk.dim(`    ${meta.join(" | ")}`));
    }
    if (opts.dryRun) {
        console.log(chalk.yellow("\n--dry-run: No beads were created."));
        return;
    }
    // ── Create beads ───────────────────────────────────────────────────
    const createSpinner = ora("Creating beads...").start();
    const createdBeads = [];
    const titleToId = new Map();
    try {
        for (const issue of parsedIssues) {
            const bead = await beads.create(issue.title, {
                type: issue.type,
                priority: issue.priority,
                parent: opts.parent,
                description: issue.description,
                labels: issue.labels,
            });
            createdBeads.push({ id: bead.id, title: bead.title });
            titleToId.set(issue.title, bead.id);
            createSpinner.text = `Creating beads… (${createdBeads.length}/${parsedIssues.length})`;
        }
        // Add dependencies in a second pass (all beads must exist first)
        for (const issue of parsedIssues) {
            if (!issue.dependencies?.length)
                continue;
            const beadId = titleToId.get(issue.title);
            if (!beadId)
                continue;
            for (const depTitle of issue.dependencies) {
                const depId = titleToId.get(depTitle);
                if (depId) {
                    await beads.addDependency(beadId, depId);
                }
                else {
                    createSpinner.warn(`Warning: dependency "${depTitle}" for "${issue.title}" was not found in the created beads — skipped.`);
                }
            }
        }
        createSpinner.succeed(`Created ${createdBeads.length} bead(s)`);
    }
    catch (err) {
        createSpinner.fail("Failed to create beads");
        console.error(chalk.red(err instanceof Error ? err.message : String(err)));
        if (createdBeads.length > 0) {
            console.error(chalk.yellow(`\nBeads created before failure:`));
            for (const b of createdBeads) {
                console.error(chalk.dim(`  ${b.id} — ${b.title}`));
            }
        }
        process.exitCode = 1;
        return;
    }
    // ── Display results ────────────────────────────────────────────────
    console.log(chalk.bold.green("\n Created beads:\n"));
    for (const bead of createdBeads) {
        console.log(`  ${chalk.cyan(bead.id)} — ${bead.title}`);
    }
    console.log();
    console.log(chalk.dim("Next: foreman run  — to dispatch work on ready beads"));
});
// ── Claude integration ────────────────────────────────────────────────────
/**
 * Call Claude Code CLI to parse a natural-language description into structured issues.
 */
async function parseWithClaude(description, model) {
    const claudePath = findClaude();
    const systemPrompt = [
        "You are a project manager extracting structured issue tickets from a natural-language description.",
        "CRITICAL: Your ENTIRE response must be a single JSON object. No text before or after.",
        "Do NOT explain your thinking. Do NOT say 'here is the JSON'. Start with { and end with }.",
        "The JSON must have an 'issues' array of objects.",
        "Each issue object has these fields:",
        "  title (string, required) — concise action-oriented title, max 80 chars",
        "  description (string, optional) — 1-2 sentence clarification",
        "  type (string) — one of: task, bug, feature, epic, chore, decision",
        "  priority (string) — one of: P0, P1, P2, P3, P4",
        "  labels (string array, optional) — semantic tags",
        "  dependencies (string array, optional) — titles of OTHER issues in this same response that must be done first",
        "Priority mapping: critical/blocking/urgent=P0, high=P1, medium/normal=P2 (default), low=P3, trivial/nice-to-have=P4.",
        "Type mapping: fix/regression=bug, new capability=feature, investigation/research=chore, document/test=task, large body of work=epic, open question=decision.",
        "Extract 1 to 20 issues. If the description is a single task, create one issue.",
        "Keep titles concise and avoid markdown formatting in any field values.",
    ].join(" ");
    const prompt = `Extract issue tickets from this description:\n\n${description}`;
    const args = [
        "--permission-mode",
        "bypassPermissions",
        "--print",
        "--output-format",
        "text",
        "--max-turns",
        "1",
        ...(model ? ["--model", model] : []),
        "--system-prompt",
        systemPrompt,
        "-", // read prompt from stdin
    ];
    let stdout;
    try {
        stdout = execFileSync(claudePath, args, {
            input: prompt,
            encoding: "utf-8",
            timeout: 120_000, // 2 minutes
            maxBuffer: 5 * 1024 * 1024,
            env: {
                ...process.env,
                PATH: `/opt/homebrew/bin:${process.env.PATH}`,
            },
        });
    }
    catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        throw new Error(`Claude parsing failed: ${msg}`);
    }
    const parsed = parseLlmResponse(stdout.trim());
    if (!Array.isArray(parsed.issues) || parsed.issues.length === 0) {
        throw new Error("Claude returned no issues. Try a more detailed description or use --no-llm.");
    }
    // Normalise and validate fields
    return parsed.issues.map(normaliseIssue);
}
/**
 * Normalise an issue from the LLM response, filling in defaults and validating fields.
 * Exported for testing.
 */
export function normaliseIssue(raw) {
    const validTypes = new Set(["task", "bug", "feature", "epic", "chore", "decision"]);
    const validPriorities = new Set(["P0", "P1", "P2", "P3", "P4"]);
    return {
        title: String(raw.title ?? "Untitled").slice(0, 200),
        description: raw.description ? String(raw.description) : undefined,
        type: validTypes.has(raw.type ?? "") ? raw.type : "task",
        priority: validPriorities.has(raw.priority ?? "") ? raw.priority : "P2",
        labels: Array.isArray(raw.labels) ? raw.labels.map(String) : undefined,
        dependencies: Array.isArray(raw.dependencies)
            ? raw.dependencies.map(String)
            : undefined,
    };
}
/**
 * Parse the raw LLM response, stripping markdown fences if present.
 * Exported for testing.
 */
export function parseLlmResponse(raw) {
    let json = raw;
    // Strip markdown code fences
    const fenceMatch = raw.match(/```(?:json)?\s*\n?([\s\S]*?)\n?\s*```/);
    if (fenceMatch) {
        json = fenceMatch[1];
    }
    json = json.trim();
    // Find the JSON object if there's extra leading text
    if (!json.startsWith("{")) {
        const objStart = json.indexOf("{");
        if (objStart >= 0) {
            json = json.slice(objStart);
        }
    }
    // First attempt: parse as-is
    try {
        return JSON.parse(json);
    }
    catch {
        // fall through to repair
    }
    // Second attempt: repair truncated JSON
    const repaired = repairTruncatedJson(json);
    try {
        return JSON.parse(repaired);
    }
    catch (err) {
        throw new Error(`Failed to parse LLM response as JSON: ${err instanceof Error ? err.message : String(err)}\n\nRaw response (first 500 chars):\n${raw.slice(0, 500)}`);
    }
}
/**
 * Locate the Claude CLI binary.
 */
function findClaude() {
    const candidates = [
        "/opt/homebrew/bin/claude",
        `${process.env.HOME}/.local/bin/claude`,
    ];
    for (const path of candidates) {
        try {
            execFileSync("test", ["-x", path]);
            return path;
        }
        catch {
            // not found, try next
        }
    }
    // Fallback: search PATH (augment with Homebrew so it's consistent with execFileSync env above)
    try {
        return execFileSync("which", ["claude"], {
            encoding: "utf-8",
            env: { ...process.env, PATH: `/opt/homebrew/bin:${process.env.PATH}` },
        }).trim();
    }
    catch {
        throw new Error("Claude CLI not found. Install it: https://claude.ai/download");
    }
}
// ── JSON repair utilities ────────────────────────────────────────────────
function scanJsonNesting(str) {
    const stack = [];
    let inString = false;
    let escaped = false;
    for (let i = 0; i < str.length; i++) {
        const ch = str[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (ch === "\\") {
            escaped = true;
            continue;
        }
        if (ch === '"') {
            inString = !inString;
            continue;
        }
        if (inString)
            continue;
        if (ch === "{")
            stack.push("}");
        else if (ch === "[")
            stack.push("]");
        else if (ch === "}" || ch === "]")
            stack.pop();
    }
    return { stack, inString };
}
/** Exported for testing. */
export function repairTruncatedJson(json) {
    const { stack, inString } = scanJsonNesting(json);
    if (stack.length === 0)
        return json;
    let truncateAt = json.length;
    if (inString) {
        const lastQuote = json.lastIndexOf('"');
        if (lastQuote >= 0) {
            truncateAt = lastQuote;
            const beforeQuote = json.slice(0, truncateAt).trimEnd();
            if (beforeQuote.endsWith(",")) {
                truncateAt = beforeQuote.length - 1;
            }
            else if (beforeQuote.endsWith(":")) {
                // Find the key's closing and opening quotes so we can remove the
                // entire key-value pair (e.g. `"title":"Incomplete...`).
                const keyCloseQuote = json.lastIndexOf('"', truncateAt - 2);
                if (keyCloseQuote >= 0) {
                    const keyOpenQuote = json.lastIndexOf('"', keyCloseQuote - 1);
                    const keyStart = keyOpenQuote >= 0 ? keyOpenQuote : keyCloseQuote;
                    truncateAt = keyStart;
                    const beforeKey = json.slice(0, truncateAt).trimEnd();
                    if (beforeKey.endsWith(",")) {
                        truncateAt = beforeKey.length - 1;
                    }
                }
            }
        }
    }
    else {
        const trimmed = json.trimEnd();
        const lastChar = trimmed[trimmed.length - 1];
        if (lastChar !== "}" &&
            lastChar !== "]" &&
            lastChar !== '"' &&
            lastChar !== "e" &&
            lastChar !== "l" &&
            !/\d/.test(lastChar)) {
            const lastComma = trimmed.lastIndexOf(",");
            if (lastComma >= 0) {
                truncateAt = lastComma;
            }
        }
    }
    let result = json.slice(0, truncateAt).trimEnd();
    const { stack: repairStack } = scanJsonNesting(result);
    if (result.endsWith(",")) {
        result = result.slice(0, -1);
    }
    result += repairStack.reverse().join("");
    return result;
}
//# sourceMappingURL=bead.js.map