#!/usr/bin/env node
import { cpSync, existsSync, mkdirSync } from 'node:fs';
import { join, dirname, basename } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, '..');
const src = join(root, 'src', 'templates');
const dest = join(root, 'dist', 'templates');

if (existsSync(src)) {
  mkdirSync(dest, { recursive: true });
  // Filter by basename so that dots in parent directory names (e.g. .foreman-worktrees)
  // don't accidentally exclude directories from being traversed.
  cpSync(src, dest, { recursive: true, filter: (s) => { const name = basename(s); return !name.includes('.') || name.endsWith('.md'); } });
  console.log('✓ Copied src/templates → dist/templates');
} else {
  console.warn('⚠ src/templates not found, skipping asset copy');
}
