// ── TRD Table Parser ─────────────────────────────────────────────────────
//
// Deterministic parser for structured TRD markdown documents.
// Extracts task hierarchies from markdown tables (not checklists).
const COLUMN_ALIASES = {
    id: ["id"],
    task: ["task", "description", "title"],
    estimate: ["est.", "est", "estimate", "hours", "time"],
    deps: ["deps", "dependencies", "dep", "depends on", "depends"],
    files: ["files", "file", "affected files"],
    status: ["status", "done", "state"],
};
/**
 * Auto-detect column indices from a markdown table header row.
 * Returns a ColumnMap. Throws SLING-010 if ID or Task columns are missing.
 */
export function parseTableHeader(headerRow) {
    const cells = splitTableRow(headerRow);
    const map = {};
    for (let i = 0; i < cells.length; i++) {
        const normalized = cells[i].toLowerCase().trim();
        for (const [key, aliases] of Object.entries(COLUMN_ALIASES)) {
            if (aliases.includes(normalized) && !(key in map)) {
                map[key] = i;
            }
        }
    }
    if (map.id == null || map.task == null) {
        const found = cells.map((c) => c.trim()).join(", ");
        throw new Error(`SLING-010: Table header missing required columns. ` +
            `Found: [${found}]. Required: ID, Task`);
    }
    return {
        id: map.id,
        task: map.task,
        estimate: map.estimate ?? null,
        deps: map.deps ?? null,
        files: map.files ?? null,
        status: map.status ?? null,
    };
}
// ── Row parsing ──────────────────────────────────────────────────────────
/**
 * Split a markdown table row into cell values, trimming whitespace.
 */
export function splitTableRow(row) {
    // Remove leading/trailing pipes, then split on | while respecting backtick spans.
    // Pipes inside backtick code spans (e.g., `string | null`) are NOT column delimiters.
    const trimmed = row.trim();
    const withoutPipes = trimmed.startsWith("|")
        ? trimmed.slice(1)
        : trimmed;
    const end = withoutPipes.endsWith("|")
        ? withoutPipes.slice(0, -1)
        : withoutPipes;
    const cells = [];
    let current = "";
    let inBacktick = false;
    for (let i = 0; i < end.length; i++) {
        const ch = end[i];
        if (ch === "`") {
            inBacktick = !inBacktick;
            current += ch;
        }
        else if (ch === "|" && !inBacktick) {
            cells.push(current.trim());
            current = "";
        }
        else {
            current += ch;
        }
    }
    cells.push(current.trim());
    return cells;
}
/**
 * Parse a single table row into a TrdTask using the column map.
 */
export function parseTableRow(row, columns) {
    const cells = splitTableRow(row);
    const id = cells[columns.id] ?? "";
    const title = cells[columns.task] ?? "";
    const estimateRaw = columns.estimate != null ? (cells[columns.estimate] ?? "") : "";
    const depsRaw = columns.deps != null ? (cells[columns.deps] ?? "") : "";
    const filesRaw = columns.files != null ? (cells[columns.files] ?? "") : "";
    const statusRaw = columns.status != null ? (cells[columns.status] ?? "") : "";
    return {
        trdId: id,
        title: title.replace(/\s+/g, " ").trim(),
        estimateHours: parseEstimate(estimateRaw),
        dependencies: parseDeps(depsRaw),
        files: parseFiles(filesRaw),
        status: parseStatus(statusRaw),
    };
}
function parseEstimate(raw) {
    const match = raw.match(/(\d+(?:\.\d+)?)\s*h/i);
    return match ? parseFloat(match[1]) : 0;
}
function parseDeps(raw) {
    const trimmed = raw.trim();
    if (!trimmed || trimmed === "--")
        return [];
    const parts = trimmed
        .split(/[,;]\s*/)
        .map((d) => d.trim())
        .filter(Boolean);
    // Expand range expressions like "AT-T001 through AT-T008"
    const expanded = [];
    for (const part of parts) {
        const rangeMatch = part.match(/^([A-Z]+-T)(\d+)\s+through\s+\1(\d+)$/i);
        if (rangeMatch) {
            const prefix = rangeMatch[1];
            const start = parseInt(rangeMatch[2], 10);
            const end = parseInt(rangeMatch[3], 10);
            for (let n = start; n <= end; n++) {
                expanded.push(`${prefix}${String(n).padStart(rangeMatch[2].length, "0")}`);
            }
        }
        else {
            expanded.push(part);
        }
    }
    return expanded;
}
function parseFiles(raw) {
    // Extract backtick-delimited paths
    const matches = raw.match(/`([^`]+)`/g);
    if (!matches)
        return [];
    return matches.map((m) => m.replace(/`/g, "").trim()).filter(Boolean);
}
function parseStatus(raw) {
    const trimmed = raw.trim();
    if (trimmed.includes("[x]") || trimmed.toLowerCase() === "done")
        return "completed";
    if (trimmed.includes("[~]"))
        return "in_progress";
    return "open";
}
// ── Section detection ────────────────────────────────────────────────────
function isSeparatorRow(line) {
    return /^\|[\s-:|]+\|$/.test(line.trim());
}
export function parseEpic(content) {
    const lines = content.split("\n");
    let title = "";
    let description = "";
    let documentId = "";
    let version;
    let epicId;
    // Find H1
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        if (line.startsWith("# ") && !line.startsWith("## ")) {
            title = line.slice(2).trim();
            // Collect description until next ## or ---
            const descLines = [];
            for (let j = i + 1; j < lines.length; j++) {
                if (lines[j].startsWith("## ") || lines[j].trim() === "---")
                    break;
                descLines.push(lines[j]);
            }
            description = descLines.join("\n").trim();
            break;
        }
    }
    // Extract frontmatter fields
    const docIdMatch = content.match(/\*\*Document ID:\*\*\s*(.+)/);
    if (docIdMatch)
        documentId = docIdMatch[1].trim();
    const versionMatch = content.match(/\*\*Version:\*\*\s*(.+)/);
    if (versionMatch)
        version = versionMatch[1].trim();
    const epicIdMatch = content.match(/\*\*Epic ID:\*\*\s*(.+)/);
    if (epicIdMatch)
        epicId = epicIdMatch[1].trim();
    return { title, description, documentId, version, epicId };
}
// ── Sprint parser ────────────────────────────────────────────────────────
const SPRINT_PATTERN = /^###\s+\d+\.\d+[a-z]?\s+Sprint\s+(\d+[a-z]?)\s*[:-]?\s*(.*)/i;
export function parseSprintHeader(line) {
    const match = line.match(SPRINT_PATTERN);
    if (!match)
        return null;
    const rawNumber = match[1];
    const suffix = rawNumber.replace(/^\d+/, "");
    const number = parseInt(rawNumber, 10);
    const rest = match[2].trim();
    // Extract FR references: (FR-1, FR-2)
    const frMatch = rest.match(/\(([^)]+)\)/);
    const frRefs = [];
    let titlePart = rest;
    if (frMatch) {
        const refs = frMatch[1].split(",").map((r) => r.trim());
        frRefs.push(...refs.filter((r) => /^FR-\d+/.test(r)));
        titlePart = rest.replace(frMatch[0], "").trim();
    }
    // Extract priority from text
    const priority = parsePriorityFromText(titlePart, number);
    // Clean up title: remove trailing dashes, "-- Quick Wins", etc.
    const goal = titlePart.replace(/\s*--\s*.*$/, "").trim();
    const fullTitle = `Sprint ${rawNumber}: ${goal}`;
    return { number, suffix, title: fullTitle, goal, frRefs, priority };
}
function parsePriorityFromText(text, sprintNumber) {
    // Check for explicit priority in text
    const priMatch = text.match(/P([0-4])/i);
    if (priMatch) {
        const n = parseInt(priMatch[1], 10);
        if (n <= 1)
            return "critical";
        if (n === 2)
            return "high";
        if (n === 3)
            return "medium";
        return "low";
    }
    if (/critical/i.test(text))
        return "critical";
    if (/\bhigh\b/i.test(text))
        return "high";
    // Ordinal fallback
    if (sprintNumber <= 2)
        return "critical";
    if (sprintNumber <= 5)
        return "high";
    return "medium";
}
// ── Story parser ─────────────────────────────────────────────────────────
const STORY_PATTERN = /^####\s+Story\s+(\d+\.\d+)\s*[:-]?\s*(.*)/i;
export function parseStoryHeader(line) {
    const match = line.match(STORY_PATTERN);
    if (!match)
        return null;
    return { ref: match[1], title: match[2].trim() };
}
// ── Acceptance Criteria parser ───────────────────────────────────────────
export function parseAcceptanceCriteria(content) {
    const acMap = new Map();
    const lines = content.split("\n");
    let inSection5 = false;
    let currentFr = null;
    const currentAcs = [];
    for (const line of lines) {
        // Detect Section 5 start
        if (/^##\s+5\.\s/i.test(line) || /^##\s+5\s/i.test(line) || line.match(/^## 5\. Acceptance/i)) {
            inSection5 = true;
            continue;
        }
        // End of Section 5 on next top-level section
        if (inSection5 && /^##\s+\d+\./.test(line) && !line.match(/^##\s+5\./)) {
            // Flush last FR
            if (currentFr && currentAcs.length > 0) {
                acMap.set(currentFr, currentAcs.join("\n"));
            }
            break;
        }
        if (!inSection5)
            continue;
        // FR subsection: ### 5.1 FR-1: ... or ### 5.2 FR-2: ...
        const frMatch = line.match(/^###\s+5\.\d+\s+(FR-\d+)/i);
        if (frMatch) {
            // Flush previous FR
            if (currentFr && currentAcs.length > 0) {
                acMap.set(currentFr, currentAcs.join("\n"));
            }
            currentFr = frMatch[1];
            currentAcs.length = 0;
            continue;
        }
        // AC lines
        if (currentFr && (line.match(/^-\s+\[/) || line.match(/^-\s+AC-/))) {
            currentAcs.push(line.trim());
        }
    }
    // Flush last FR
    if (currentFr && currentAcs.length > 0) {
        acMap.set(currentFr, currentAcs.join("\n"));
    }
    return acMap;
}
// ── Risk Register parser ─────────────────────────────────────────────────
export function parseRiskRegister(content) {
    const riskMap = new Map();
    const lines = content.split("\n");
    let inSection7 = false;
    let columns = null;
    for (const line of lines) {
        if (/^##\s+7\.\s/i.test(line) || line.match(/^## 7\. Risk/i)) {
            inSection7 = true;
            continue;
        }
        if (inSection7 && /^##\s+\d+\./.test(line) && !line.match(/^##\s+7\./)) {
            break;
        }
        if (!inSection7)
            continue;
        // Detect table header
        if (line.includes("|") && /Risk/i.test(line) && /Tasks?\s*Affected/i.test(line)) {
            const cells = splitTableRow(line);
            columns = {
                likelihood: cells.findIndex((c) => /likelihood/i.test(c)),
                impact: cells.findIndex((c) => /impact/i.test(c)),
                tasksAffected: cells.findIndex((c) => /tasks?\s*affected/i.test(c)),
            };
            continue;
        }
        if (!columns || isSeparatorRow(line) || !line.includes("|"))
            continue;
        const cells = splitTableRow(line);
        if (cells.length <= columns.tasksAffected)
            continue;
        const likelihood = (cells[columns.likelihood] ?? "").toLowerCase().trim();
        const impact = (cells[columns.impact] ?? "").toLowerCase().trim();
        const tasksAffected = cells[columns.tasksAffected] ?? "";
        // Determine risk level
        let riskLevel;
        if (likelihood === "high" || impact === "high") {
            riskLevel = "high";
        }
        else if (likelihood === "medium" || impact === "medium") {
            riskLevel = "medium";
        }
        else {
            continue;
        }
        // Extract task IDs from the "Tasks Affected" cell
        const taskIds = tasksAffected.match(/[A-Z]+-T\d+/g);
        if (taskIds) {
            for (const id of taskIds) {
                // Keep the highest risk level
                if (riskMap.get(id) !== "high") {
                    riskMap.set(id, riskLevel);
                }
            }
        }
    }
    return riskMap;
}
// ── Quality Requirements parser ──────────────────────────────────────────
export function parseQualityRequirements(content) {
    const lines = content.split("\n");
    let inSection6 = false;
    const qualityLines = [];
    for (const line of lines) {
        if (/^##\s+6\.\s/i.test(line) || line.match(/^## 6\. Quality/i)) {
            inSection6 = true;
            continue;
        }
        if (inSection6 && /^##\s+\d+\./.test(line) && !line.match(/^##\s+6\./)) {
            break;
        }
        if (inSection6) {
            qualityLines.push(line);
        }
    }
    const result = qualityLines.join("\n").trim();
    return result || undefined;
}
export function parseSprintSummary(content) {
    const summaryMap = new Map();
    const lines = content.split("\n");
    let inSection3 = false;
    let headerColumns = null;
    for (const line of lines) {
        if (/^##\s+3\.\s/i.test(line) || line.match(/^## 3\. Sprint/i)) {
            inSection3 = true;
            continue;
        }
        if (inSection3 && /^##\s+\d+\./.test(line) && !line.match(/^##\s+3\./)) {
            break;
        }
        if (!inSection3)
            continue;
        // Detect table header
        if (line.includes("|") && /Sprint/i.test(line) && /Focus|Tasks/i.test(line)) {
            const cells = splitTableRow(line);
            headerColumns = {
                sprint: cells.findIndex((c) => /sprint/i.test(c)),
                focus: cells.findIndex((c) => /focus/i.test(c)),
                hours: cells.findIndex((c) => /hours?|est/i.test(c)),
                deliverables: cells.findIndex((c) => /deliver|key/i.test(c)),
            };
            continue;
        }
        if (!headerColumns || isSeparatorRow(line) || !line.includes("|"))
            continue;
        const cells = splitTableRow(line);
        const sprintCell = (cells[headerColumns.sprint] ?? "").trim();
        // Extract sprint number
        const sprintMatch = sprintCell.match(/(\d+)/);
        if (!sprintMatch)
            continue;
        const sprintNum = parseInt(sprintMatch[1], 10);
        const focus = (cells[headerColumns.focus] ?? "").trim();
        const hoursRaw = (cells[headerColumns.hours] ?? "").trim();
        const hoursMatch = hoursRaw.match(/(\d+)/);
        const estimatedHours = hoursMatch ? parseInt(hoursMatch[1], 10) : 0;
        const deliverables = headerColumns.deliverables >= 0
            ? (cells[headerColumns.deliverables] ?? "").trim()
            : "";
        summaryMap.set(sprintNum, { focus, estimatedHours, deliverables });
    }
    return summaryMap;
}
// ── Top-level parser ─────────────────────────────────────────────────────
/**
 * Parse a TRD markdown document into a SlingPlan.
 * Throws SLING-002 if no tasks are extracted.
 */
export function parseTrd(content) {
    const epic = parseEpic(content);
    const lines = content.split("\n");
    const sprints = [];
    let currentSprint = null;
    let currentStory = null;
    let currentColumns = null;
    let currentFrRefs = [];
    let expectingHeader = false;
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        // H2 section header — flush any open story/sprint and reset
        if (line.startsWith("## ")) {
            if (currentStory && currentSprint) {
                currentSprint.stories.push(currentStory);
                currentStory = null;
            }
            if (currentSprint) {
                sprints.push(currentSprint);
                currentSprint = null;
            }
            currentColumns = null;
            expectingHeader = false;
            continue;
        }
        // Sprint header
        const sprintHeader = parseSprintHeader(line);
        if (sprintHeader) {
            // Flush previous story into sprint
            if (currentStory && currentSprint) {
                currentSprint.stories.push(currentStory);
                currentStory = null;
            }
            // Flush previous sprint
            if (currentSprint) {
                sprints.push(currentSprint);
            }
            currentSprint = {
                number: sprintHeader.number,
                title: sprintHeader.title,
                goal: sprintHeader.goal,
                priority: sprintHeader.priority,
                stories: [],
            };
            currentFrRefs = sprintHeader.frRefs;
            currentColumns = null;
            expectingHeader = false;
            continue;
        }
        // Story header
        const storyHeader = parseStoryHeader(line);
        if (storyHeader) {
            // Flush previous story
            if (currentStory && currentSprint) {
                currentSprint.stories.push(currentStory);
            }
            currentStory = {
                title: storyHeader.title,
                frNumber: currentFrRefs.length > 0 ? currentFrRefs.join(", ") : undefined,
                tasks: [],
            };
            currentColumns = null;
            expectingHeader = true;
            continue;
        }
        // Table header detection (only within a story)
        if (currentStory && line.includes("|") && !isSeparatorRow(line)) {
            if (expectingHeader) {
                try {
                    currentColumns = parseTableHeader(line);
                    expectingHeader = false;
                    continue;
                }
                catch {
                    // Not a valid header — skip
                    expectingHeader = false;
                }
            }
            // Table data row
            if (currentColumns && !isSeparatorRow(line)) {
                try {
                    const task = parseTableRow(line, currentColumns);
                    if (task.trdId) {
                        currentStory.tasks.push(task);
                    }
                }
                catch {
                    // Skip malformed rows
                }
            }
        }
        // Separator row — skip
        if (isSeparatorRow(line)) {
            continue;
        }
        // Reset header expectation on non-table content
        if (currentStory && !line.includes("|") && line.trim() !== "") {
            expectingHeader = true;
        }
    }
    // Flush remaining story/sprint
    if (currentStory && currentSprint) {
        currentSprint.stories.push(currentStory);
    }
    if (currentSprint) {
        sprints.push(currentSprint);
    }
    // Count total tasks
    const totalTasks = sprints.reduce((sum, s) => sum + s.stories.reduce((ss, st) => ss + st.tasks.length, 0), 0);
    if (totalTasks === 0) {
        throw new Error("SLING-002: No tasks extracted from TRD. " +
            "The document may not match the expected table format.");
    }
    // Parse metadata sections
    const acceptanceCriteria = parseAcceptanceCriteria(content);
    const riskMap = parseRiskRegister(content);
    const qualityNotes = parseQualityRequirements(content);
    const sprintSummary = parseSprintSummary(content);
    // Apply risk levels to tasks
    for (const sprint of sprints) {
        for (const story of sprint.stories) {
            for (const task of story.tasks) {
                const risk = riskMap.get(task.trdId);
                if (risk) {
                    task.riskLevel = risk;
                }
            }
        }
    }
    // Apply sprint summaries
    for (const sprint of sprints) {
        const summary = sprintSummary.get(sprint.number);
        if (summary) {
            sprint.summary = summary;
        }
    }
    // Apply ACs to stories
    for (const sprint of sprints) {
        for (const story of sprint.stories) {
            if (story.frNumber) {
                // Handle comma-separated FR refs
                const frNums = story.frNumber.split(",").map((f) => f.trim());
                const acs = [];
                for (const fr of frNums) {
                    const ac = acceptanceCriteria.get(fr);
                    if (ac)
                        acs.push(ac);
                }
                if (acs.length > 0) {
                    story.acceptanceCriteria = acs.join("\n\n");
                }
            }
        }
    }
    return {
        epic: {
            title: epic.title,
            description: epic.description,
            documentId: epic.documentId,
            qualityNotes,
        },
        sprints,
        acceptanceCriteria,
        riskMap,
    };
}
//# sourceMappingURL=trd-parser.js.map