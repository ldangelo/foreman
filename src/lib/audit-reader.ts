/**
 * audit-reader.ts
 *
 * Utility for reading JSONL audit files written by the foreman-audit extension.
 * Files are stored at ~/.foreman/audit/{runId}.jsonl.
 *
 * The reader locates the most recent run for a given seedId by querying the
 * project-local SQLite store, then reads and filters the corresponding JSONL file.
 */

import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { homedir } from "node:os";
import Database from "better-sqlite3";
import { mkdirSync } from "node:fs";

// ── Public types ──────────────────────────────────────────────────────────────

export interface AuditEntry {
  timestamp: string;
  runId: string;
  seedId: string;
  phase: string;
  eventType: string;
  toolName?: string;
  blocked?: boolean;
  blockReason?: string;
  turnNumber?: number;
  totalTokens?: number;
  durationMs?: number;
  /** Additional optional fields from the audit logger */
  [key: string]: unknown;
}

export interface AuditFilter {
  /** Filter entries where entry.phase === filter.phase */
  phase?: string;
  /** Filter entries where entry.eventType === filter.eventType */
  eventType?: string;
  /** Include only entries where entry.timestamp >= since (ISO string) */
  since?: string;
  /** Include only entries where entry.timestamp <= until (ISO string) */
  until?: string;
  /** Include only entries whose raw JSON line contains this text (case-insensitive) */
  search?: string;
}

// ── Implementation ────────────────────────────────────────────────────────────

/**
 * Find the most recent runId for a given seedId by opening the project-local
 * (or user-level fallback) Foreman SQLite database.
 *
 * Returns null if no run is found or the DB cannot be opened.
 */
function findRunIdForSeed(seedId: string): string | null {
  // Try the project-local DB first (matches ForemanStore.forProject pattern),
  // then fall back to the home-directory DB used by older installations.
  const candidates: string[] = [
    join(process.cwd(), ".foreman", "foreman.db"),
    join(homedir(), ".foreman", "foreman.db"),
  ];

  for (const dbPath of candidates) {
    try {
      mkdirSync(join(dbPath, ".."), { recursive: true });
      const db = new Database(dbPath, { readonly: true, fileMustExist: true });
      try {
        const row = db
          .prepare(
            "SELECT id FROM runs WHERE seed_id = ? ORDER BY created_at DESC, rowid DESC LIMIT 1"
          )
          .get(seedId) as { id: string } | undefined;
        if (row) {
          return row.id;
        }
      } finally {
        db.close();
      }
    } catch {
      // DB doesn't exist or query failed — try the next candidate.
    }
  }

  return null;
}

/**
 * Read and filter audit entries for the most recent run associated with the
 * given seedId.
 *
 * - Returns `[]` if no run is found for the seedId.
 * - Returns `[]` if the JSONL file cannot be read (e.g. ENOENT, permissions).
 * - Skips malformed JSON lines rather than throwing.
 * - Never throws.
 */
export async function readAuditEntries(
  seedId: string,
  filter?: AuditFilter
): Promise<AuditEntry[]> {
  // 1. Resolve the run ID.
  const runId = findRunIdForSeed(seedId);
  if (!runId) {
    return [];
  }

  // 2. Build the path to the JSONL audit file.
  const auditDir = join(homedir(), ".foreman", "audit");
  const auditFilePath = join(auditDir, `${runId}.jsonl`);

  // 3. Read the file.
  let raw: string;
  try {
    raw = await readFile(auditFilePath, "utf-8");
  } catch {
    return [];
  }

  // 4. Parse each line, silently skipping malformed ones.
  const entries: AuditEntry[] = [];
  for (const line of raw.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    try {
      const parsed = JSON.parse(trimmed) as AuditEntry;
      entries.push(parsed);
    } catch {
      // Malformed line — skip.
    }
  }

  // 5. Apply filters.
  if (!filter) {
    return entries;
  }

  return entries.filter((entry) => {
    if (filter.phase !== undefined && entry.phase !== filter.phase) {
      return false;
    }
    if (filter.eventType !== undefined && entry.eventType !== filter.eventType) {
      return false;
    }
    if (filter.since !== undefined && entry.timestamp < filter.since) {
      return false;
    }
    if (filter.until !== undefined && entry.timestamp > filter.until) {
      return false;
    }
    if (filter.search !== undefined) {
      // Re-serialize to raw JSON for a consistent case-insensitive string search.
      const rawLine = JSON.stringify(entry).toLowerCase();
      if (!rawLine.includes(filter.search.toLowerCase())) {
        return false;
      }
    }
    return true;
  });
}
