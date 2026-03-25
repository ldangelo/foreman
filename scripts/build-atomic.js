#!/usr/bin/env node
/**
 * build-atomic.js — Zero-downtime atomic build
 *
 * Problem: `npm run clean` deletes dist/ then tsc recompiles. During the 2-5s
 * recompilation window, any spawned agent-worker processes crash with
 * ERR_MODULE_NOT_FOUND because dist/orchestrator/agent-worker.js is missing.
 *
 * Solution: Build into a temp directory (dist-new-<timestamp>/), then atomically
 * rename it over the old dist/ directory. Workers never see a missing dist/.
 *
 * Usage:
 *   node scripts/build-atomic.js         # replaces dist/ atomically
 *   node scripts/build-atomic.js --dry   # skips final swap (for testing)
 */

import { execSync } from 'node:child_process';
import {
  existsSync,
  mkdirSync,
  renameSync,
  rmSync,
  cpSync,
} from 'node:fs';
import { join, dirname, basename } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, '..');
const dryRun = process.argv.includes('--dry');

const ts = Date.now();
const tmpDir = join(root, `dist-new-${ts}`);
const oldBackup = join(root, `dist-old-${ts}`);
const finalDir = join(root, 'dist');

console.error(`[build-atomic] tmp  → ${tmpDir}`);
console.error(`[build-atomic] dest → ${finalDir}`);

// ── Step 1: compile TypeScript into tmpDir ────────────────────────────────────
console.error('[build-atomic] Running tsc …');
execSync(
  `npx tsc -p tsconfig.build.json --outDir ${tmpDir}`,
  { cwd: root, stdio: 'inherit' },
);

// ── Step 2: copy static assets into tmpDir ────────────────────────────────────
console.error('[build-atomic] Copying assets …');
const filter = (s) => {
  const name = basename(s);
  return !name.includes('.') || name.endsWith('.md') || name.endsWith('.yaml');
};

const legacySrc = join(root, 'src', 'templates');
if (existsSync(legacySrc)) {
  mkdirSync(join(tmpDir, 'templates'), { recursive: true });
  cpSync(legacySrc, join(tmpDir, 'templates'), { recursive: true, filter });
  console.error('  ✓ Copied src/templates → dist-new/templates');
}

const defaultsSrc = join(root, 'src', 'defaults');
if (existsSync(defaultsSrc)) {
  mkdirSync(join(tmpDir, 'defaults'), { recursive: true });
  cpSync(defaultsSrc, join(tmpDir, 'defaults'), { recursive: true, filter });
  console.error('  ✓ Copied src/defaults → dist-new/defaults');
}

// ── Step 3: build workspace package into tmpDir/packages ────────────────────
// The workspace (foreman-pi-extensions) builds to its own dist/ in
// packages/foreman-pi-extensions/dist/. We don't need to move it because it
// is not inside the main dist/ directory — workers load it from its own path.
console.error('[build-atomic] Building foreman-pi-extensions …');
execSync('npm run build --workspace=packages/foreman-pi-extensions', {
  cwd: root,
  stdio: 'inherit',
});

// ── Step 4 (skip in dry run): atomic swap ────────────────────────────────────
if (dryRun) {
  console.error('[build-atomic] --dry mode: skipping atomic swap');
  console.error(`[build-atomic] Removing temp dir ${tmpDir}`);
  rmSync(tmpDir, { recursive: true, force: true });
  console.error('[build-atomic] Done (dry run).');
  process.exit(0);
}

console.error('[build-atomic] Performing atomic swap …');

// Rename old dist/ → dist-old-<ts>/ (if it exists)
if (existsSync(finalDir)) {
  renameSync(finalDir, oldBackup);
}

// Rename dist-new-<ts>/ → dist/
renameSync(tmpDir, finalDir);

// Remove old backup
if (existsSync(oldBackup)) {
  rmSync(oldBackup, { recursive: true, force: true });
}

console.error('[build-atomic] ✓ dist/ updated atomically — no downtime window.');
