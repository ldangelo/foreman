#!/usr/bin/env node
import { cpSync, existsSync, mkdirSync } from 'node:fs';
import { join, dirname, basename } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, '..');

// Filter function: skip files with dots in basename unless they end with .md or .yaml
const filter = (s) => {
  const name = basename(s);
  return !name.includes('.') || name.endsWith('.md') || name.endsWith('.yaml');
};

// Copy src/templates → dist/templates (legacy; template-loader.ts still references this)
const legacySrc = join(root, 'src', 'templates');
const legacyDest = join(root, 'dist', 'templates');
if (existsSync(legacySrc)) {
  mkdirSync(legacyDest, { recursive: true });
  cpSync(legacySrc, legacyDest, { recursive: true, filter });
  console.log('✓ Copied src/templates → dist/templates');
}

// Copy src/defaults → dist/defaults (prompt templates + skills)
const defaultsSrc = join(root, 'src', 'defaults');
const defaultsDest = join(root, 'dist', 'defaults');
if (existsSync(defaultsSrc)) {
  mkdirSync(defaultsDest, { recursive: true });
  cpSync(defaultsSrc, defaultsDest, { recursive: true, filter });
  console.log('✓ Copied src/defaults → dist/defaults');
} else {
  console.warn('⚠ src/defaults not found, skipping asset copy');
}
