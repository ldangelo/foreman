#!/usr/bin/env node
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

const patterns = [
  'pool-manager',
  'postgres-adapter',
  'postgres-store',
  'postgres-merge-queue',
  'PostgresMergeQueue',
  'PostgresAdapter',
  'PostgresStore',
  'PoolManager',
];

const paths = ['src/cli', 'src/orchestrator', 'src/lib', 'src/daemon', 'dist/cli', 'dist/orchestrator', 'dist/lib', 'dist/daemon'];
const ignoredDirectory = '__tests__';
const ignored = [
  'src/lib/project-registry.ts',
  'src/lib/postgres-mail-client.ts',
  'src/orchestrator/elixir-merge-queue.ts',
  'dist/lib/project-registry.js',
  'dist/lib/project-registry.d.ts',
  'dist/lib/postgres-mail-client.js',
  'dist/lib/postgres-mail-client.d.ts',
  'dist/orchestrator/elixir-merge-queue.js',
  'dist/orchestrator/elixir-merge-queue.d.ts',
];

function collectFiles(path) {
  if (!existsSync(path)) return [];
  const stat = statSync(path);
  if (stat.isFile()) return [path];
  if (!stat.isDirectory()) return [];

  return readdirSync(path, { withFileTypes: true }).flatMap((entry) => {
    if (entry.isDirectory() && entry.name === ignoredDirectory) return [];
    return collectFiles(join(path, entry.name));
  });
}

const hits = paths
  .flatMap(collectFiles)
  .filter((file) => !ignored.includes(file))
  .flatMap((file) => {
    const lines = readFileSync(file, 'utf8').split('\n');
    return lines.flatMap((line, index) => (
      patterns.some((pattern) => line.includes(pattern)) ? [`${file}:${index + 1}:${line}`] : []
    ));
  });
if (hits.length > 0) {
  console.error('Legacy direct Postgres runtime references found:');
  console.error(hits.join('\n'));
  process.exit(1);
}
