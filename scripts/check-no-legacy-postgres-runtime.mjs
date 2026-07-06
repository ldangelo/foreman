#!/usr/bin/env node
import { execFileSync } from 'node:child_process';

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
const glob = '!**/__tests__/**';
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

let output = '';
try {
  output = execFileSync('rg', ['-n', ...patterns.flatMap((p) => ['-e', p]), '--glob', glob, ...paths], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
} catch (err) {
  if (err.status === 1) process.exit(0);
  throw err;
}

const hits = output.split('\n').filter(Boolean).filter((line) => !ignored.some((file) => line.startsWith(`${file}:`)));
if (hits.length > 0) {
  console.error('Legacy direct Postgres runtime references found:');
  console.error(hits.join('\n'));
  process.exit(1);
}
