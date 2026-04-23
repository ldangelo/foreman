#!/usr/bin/env node

import { spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

const LEGACY_TIMESTAMP_WARNING = /^Can't determine timestamp for 0000000000000\d-/;

if (!process.env.DATABASE_URL) {
  const dotEnvPath = join(process.cwd(), ".env");
  if (existsSync(dotEnvPath)) {
    const match = readFileSync(dotEnvPath, "utf8").match(/^\s*DATABASE_URL=(.+)\s*$/m);
    if (match?.[1]) {
      process.env.DATABASE_URL = match[1].trim().replace(/^['"]|['"]$/g, "");
    }
  }
}

function writeFiltered(stream, chunk) {
  const text = chunk.toString();
  const filtered = text
    .split(/\r?\n/)
    .filter((line) => line.length === 0 || !LEGACY_TIMESTAMP_WARNING.test(line))
    .join("\n");

  if (filtered.length > 0) {
    stream.write(filtered);
    if (text.endsWith("\n")) {
      stream.write("\n");
    }
  }
}

const child = spawn(
  "npx",
  ["node-pg-migrate", ...process.argv.slice(2)],
  {
    stdio: ["inherit", "pipe", "pipe"],
    env: process.env,
  },
);

child.stdout.on("data", (chunk) => writeFiltered(process.stdout, chunk));
child.stderr.on("data", (chunk) => writeFiltered(process.stderr, chunk));

child.on("exit", (code, signal) => {
  if (signal) {
    process.kill(process.pid, signal);
    return;
  }
  process.exit(code ?? 0);
});
