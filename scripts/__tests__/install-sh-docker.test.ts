/**
 * Docker integration tests for install.sh — Ubuntu Linux verification.
 *
 * These tests spin up a real ubuntu:latest Docker container, run the
 * install.sh script against a local mock HTTP server (no real GitHub
 * releases needed), and verify:
 *   - Correct binary is downloaded
 *   - Binary is installed to the correct path
 *   - `foreman --version` works after install
 *   - better_sqlite3.node side-car is installed alongside binary
 *
 * The mock server is an in-process Node.js HTTP server. The install script
 * uses FOREMAN_API_BASE and FOREMAN_RELEASES_BASE env vars to redirect
 * all GitHub calls to the local mock server.
 *
 * Docker containers access the host mock server via --network=host
 * (Linux) or host.docker.internal (macOS Docker Desktop).
 *
 * Prerequisites:
 *   - Docker daemon must be running (`docker info` should succeed)
 *   - Tests are skipped automatically when Docker is unavailable
 *
 * Run individually with:
 *   npx vitest run scripts/__tests__/install-sh-docker.test.ts
 */

import { describe, it, expect, beforeAll, afterAll } from "vitest";
import {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  rmSync,
  readFileSync,
  existsSync,
  chmodSync,
} from "node:fs";
import { spawnSync, spawn } from "node:child_process";
import { createServer, type Server } from "node:http";
import { tmpdir, networkInterfaces } from "node:os";
import * as path from "node:path";
import * as crypto from "node:crypto";
import { fileURLToPath } from "node:url";

// ── Paths ─────────────────────────────────────────────────────────────────────

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "..", "..");
const INSTALL_SH = path.join(REPO_ROOT, "install.sh");

// ── Docker availability check ─────────────────────────────────────────────────

function isDockerAvailable(): boolean {
  try {
    const result = spawnSync("docker", ["info"], {
      stdio: "pipe",
      timeout: 15_000,
    });
    return result.status === 0;
  } catch {
    return false;
  }
}

function dockerPull(image: string): boolean {
  try {
    const result = spawnSync("docker", ["pull", "--quiet", image], {
      stdio: "pipe",
      timeout: 120_000,
    });
    return result.status === 0;
  } catch {
    return false;
  }
}

/**
 * Get the host IP address that Docker containers can reach.
 * On Linux --network=host, 127.0.0.1 works.
 * On macOS Docker Desktop, host.docker.internal resolves to the host.
 */
function getDockerHostAddress(): string {
  // Check if we're on Linux (where --network=host makes 127.0.0.1 work)
  if (process.platform === "linux") {
    return "127.0.0.1";
  }
  // On macOS/Windows Docker Desktop, host.docker.internal is available
  return "host.docker.internal";
}

// ── Mock binary builder ───────────────────────────────────────────────────────

/**
 * Creates a minimal shell script that behaves like `foreman --version`.
 * Packs it into a tar.gz that matches the format install.sh expects:
 *   foreman-v<version>-linux-<arch>.tar.gz
 *     └── foreman-linux-<arch>       (executable shell script)
 *     └── better_sqlite3.node        (empty placeholder)
 */
async function buildMockArchive(opts: {
  version: string;
  arch: string; // "x64" | "arm64"
  outputDir: string;
}): Promise<{ archivePath: string; sha256: string; assetName: string }> {
  const { version, arch, outputDir } = opts;
  const platform = `linux-${arch}`;
  const binaryName = `foreman-${platform}`;
  const assetName = `foreman-${version}-${platform}.tar.gz`;

  // Create a staging dir for the archive contents
  const stagingDir = path.join(outputDir, "staging");
  mkdirSync(stagingDir, { recursive: true });

  // Write a shell script that mimics `foreman --version`
  const mockBinaryPath = path.join(stagingDir, binaryName);
  writeFileSync(
    mockBinaryPath,
    `#!/bin/sh
# Mock foreman binary for testing install.sh
if [ "$1" = "--version" ]; then
  echo "foreman ${version}"
  exit 0
fi
if [ "$1" = "--help" ]; then
  echo "Usage: foreman [options] [command]"
  echo ""
  echo "Options:"
  echo "  -V, --version   output the version number"
  echo "  -h, --help      display help for command"
  echo ""
  echo "Commands:"
  echo "  init    Initialize project"
  echo "  run     Run tasks"
  echo "  doctor  Health checks"
  echo "  status  Show status"
  exit 0
fi
echo "foreman: command not found: $*" >&2
exit 1
`,
    "utf-8"
  );
  chmodSync(mockBinaryPath, 0o755);

  // Write a placeholder better_sqlite3.node side-car
  const addonPath = path.join(stagingDir, "better_sqlite3.node");
  writeFileSync(addonPath, "MOCK_NATIVE_ADDON", "utf-8");

  // Pack into tar.gz
  const archivePath = path.join(outputDir, assetName);
  const tarResult = spawnSync(
    "tar",
    ["czf", archivePath, "-C", stagingDir, binaryName, "better_sqlite3.node"],
    { stdio: "pipe", timeout: 30_000 }
  );

  if (tarResult.status !== 0) {
    throw new Error(
      `Failed to create mock archive: ${tarResult.stderr?.toString()}`
    );
  }

  // Compute SHA256 of the archive
  const archiveData = readFileSync(archivePath);
  const sha256 = crypto.createHash("sha256").update(archiveData).digest("hex");

  return { archivePath, sha256, assetName };
}

// ── Mock HTTP server ──────────────────────────────────────────────────────────

interface MockServerState {
  server: Server;
  port: number;
  version: string;
  assetName: string;
  /** Base URL for FOREMAN_API_BASE env var */
  apiBase: string;
  /** Base URL for FOREMAN_RELEASES_BASE env var */
  releasesBase: string;
  requestLog: Array<{ method: string; url: string }>;
  close: () => Promise<void>;
}

function startMockServer(opts: {
  version: string;
  archivePath: string;
  assetName: string;
  sha256: string;
  hostAddress: string;
}): Promise<MockServerState> {
  const { version, archivePath, assetName, sha256, hostAddress } = opts;
  const requestLog: Array<{ method: string; url: string }> = [];

  return new Promise((resolve, reject) => {
    const server = createServer((req, res) => {
      const url = req.url ?? "";
      requestLog.push({ method: req.method ?? "GET", url });

      // GitHub API: latest release info
      if (url.match(/\/repos\/[^/]+\/[^/]+\/releases\/latest/)) {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(
          JSON.stringify({
            tag_name: version,
            name: `Foreman ${version}`,
            prerelease: false,
            draft: false,
            published_at: new Date().toISOString(),
          })
        );
        return;
      }

      // GitHub Releases: binary archive download
      if (url.includes(assetName)) {
        const archiveData = readFileSync(archivePath);
        res.writeHead(200, {
          "Content-Type": "application/octet-stream",
          "Content-Length": String(archiveData.length),
        });
        res.end(archiveData);
        return;
      }

      // GitHub Releases: checksums.txt
      if (url.includes("checksums.txt")) {
        res.writeHead(200, { "Content-Type": "text/plain" });
        res.end(`${sha256}  ${assetName}\n`);
        return;
      }

      // Unknown routes
      res.writeHead(404, { "Content-Type": "text/plain" });
      res.end(`Not Found: ${url}`);
    });

    // Listen on all interfaces so Docker containers can reach us
    server.listen(0, "0.0.0.0", () => {
      const addr = server.address();
      if (!addr || typeof addr === "string") {
        reject(new Error("Could not get server address"));
        return;
      }
      const port = addr.port;
      const baseUrl = `http://${hostAddress}:${port}`;
      resolve({
        server,
        port,
        version,
        assetName,
        apiBase: baseUrl,
        releasesBase: `${baseUrl}/ldangelo/foreman/releases/download`,
        requestLog,
        close: () => new Promise<void>((res) => server.close(() => res())),
      });
    });

    server.on("error", reject);
  });
}

// ── Docker runner ─────────────────────────────────────────────────────────────

/**
 * Run a shell command inside a fresh ubuntu:latest container.
 * Returns the combined stdout+stderr output.
 *
 * Uses async spawn so the Node.js event loop stays free for the mock HTTP
 * server to handle requests from inside the container.
 */
function runInDocker(opts: {
  image: string;
  command: string;
  env?: Record<string, string>;
  timeoutMs?: number;
}): Promise<{ output: string; exitCode: number }> {
  const { image, command, env = {}, timeoutMs = 120_000 } = opts;

  const dockerArgs: string[] = [
    "run",
    "--rm",
    "--network=host", // Linux: 127.0.0.1 = host; macOS: requires host.docker.internal
  ];

  // Add env vars
  for (const [key, value] of Object.entries(env)) {
    dockerArgs.push("-e", `${key}=${value}`);
  }

  dockerArgs.push(image, "sh", "-c", command);

  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    const proc = spawn("docker", dockerArgs, {
      stdio: ["ignore", "pipe", "pipe"],
    });

    proc.stdout?.on("data", (chunk: Buffer) => chunks.push(chunk));
    proc.stderr?.on("data", (chunk: Buffer) => chunks.push(chunk));

    proc.on("close", (code) => {
      const output = Buffer.concat(chunks).toString("utf-8");
      resolve({ output, exitCode: code ?? -1 });
    });

    proc.on("error", reject);

    const timer = setTimeout(() => {
      proc.kill();
      reject(new Error(`docker run timed out after ${timeoutMs}ms`));
    }, timeoutMs);

    proc.on("close", () => clearTimeout(timer));
  });
}

// ── Test state ────────────────────────────────────────────────────────────────

const DOCKER_AVAILABLE = isDockerAvailable();
const MOCK_VERSION = "v1.0.0-test";
const HOST_ADDRESS = getDockerHostAddress();

let tmpDir: string;
let mockServer: MockServerState | undefined;

// ── Test suite ────────────────────────────────────────────────────────────────

describe("install.sh Docker integration tests (ubuntu:latest)", () => {
  if (!DOCKER_AVAILABLE) {
    it.skip(
      "Docker daemon is not running — skipping Docker integration tests",
      () => {}
    );
    return;
  }

  beforeAll(
    async () => {
      // Create temporary workspace
      tmpDir = mkdtempSync(
        path.join(tmpdir(), "foreman-install-docker-test-")
      );
      console.log(`\n[docker-test] Temp dir: ${tmpDir}`);
      console.log(`[docker-test] Host address for Docker: ${HOST_ADDRESS}`);

      // Detect the Docker container architecture
      // On macOS Apple Silicon, Docker may use arm64 containers
      const hostArchResult = spawnSync("uname", ["-m"], {
        encoding: "utf-8",
        stdio: "pipe",
      });
      const rawArch = (hostArchResult.stdout ?? "x86_64").trim();
      const dockerArch =
        rawArch === "arm64" || rawArch === "aarch64" ? "arm64" : "x64";

      console.log(
        `[docker-test] Building mock archive for linux-${dockerArch}...`
      );

      const { archivePath, sha256, assetName } = await buildMockArchive({
        version: MOCK_VERSION,
        arch: dockerArch,
        outputDir: tmpDir,
      });

      console.log(
        `[docker-test] Mock archive: ${assetName} (SHA256: ${sha256.slice(0, 16)}...)`
      );

      // Start mock HTTP server on all interfaces
      mockServer = await startMockServer({
        version: MOCK_VERSION,
        archivePath,
        assetName,
        sha256,
        hostAddress: HOST_ADDRESS,
      });
      console.log(
        `[docker-test] Mock server: port=${mockServer.port}, apiBase=${mockServer.apiBase}`
      );
    },
    60_000
  );

  afterAll(async () => {
    if (mockServer) {
      await mockServer.close();
      console.log("[docker-test] Mock server stopped");
    }

    if (tmpDir && existsSync(tmpDir)) {
      rmSync(tmpDir, { recursive: true, force: true });
      console.log(`[docker-test] Cleaned up: ${tmpDir}`);
    }
  });

  // ── Docker image availability ───────────────────────────────────────────────

  it(
    "can pull ubuntu:latest image",
    () => {
      const ok = dockerPull("ubuntu:latest");
      expect(ok).toBe(true);
    },
    120_000
  );

  // ── Basic install flow ──────────────────────────────────────────────────────

  it(
    "installs foreman to ~/.local/bin in a fresh ubuntu container",
    async () => {
      if (!mockServer) {
        expect.fail("Test setup failed — no mock server");
      }

      // Install apt prerequisites + run installer via env var redirect
      const command = [
        "apt-get update -qq 2>/dev/null",
        "apt-get install -y -qq curl tar 2>/dev/null",
        `FOREMAN_VERSION=${MOCK_VERSION} FOREMAN_INSTALL=/root/.local/bin FOREMAN_API_BASE=${mockServer.apiBase} FOREMAN_RELEASES_BASE=${mockServer.releasesBase} sh /dev/stdin < /dev/null`,
        "test -f /root/.local/bin/foreman && echo 'BINARY_EXISTS: YES' || echo 'BINARY_EXISTS: NO'",
        "test -x /root/.local/bin/foreman && echo 'BINARY_EXECUTABLE: YES' || echo 'BINARY_EXECUTABLE: NO'",
        "/root/.local/bin/foreman --version 2>&1 | head -1",
      ].join(" && ");

      // Mount install.sh and run it
      const installCmd = [
        "apt-get update -qq 2>/dev/null",
        "apt-get install -y -qq curl tar 2>/dev/null",
        "sh /install.sh",
        "test -f /root/.local/bin/foreman && echo 'BINARY_EXISTS: YES' || echo 'BINARY_EXISTS: NO'",
        "test -x /root/.local/bin/foreman && echo 'BINARY_EXECUTABLE: YES' || echo 'BINARY_EXECUTABLE: NO'",
        "/root/.local/bin/foreman --version 2>&1 | head -1",
      ].join(" && ");

      // Copy install.sh to a location Docker can access
      const installShInMount = path.join(tmpDir, "install.sh");
      if (!existsSync(installShInMount)) {
        writeFileSync(installShInMount, readFileSync(INSTALL_SH), { mode: 0o755 });
      }

      const dockerArgs = [
        "run", "--rm",
        "--network=host",
        "-v", `${installShInMount}:/install.sh:ro`,
        "-e", `FOREMAN_VERSION=${MOCK_VERSION}`,
        "-e", `FOREMAN_INSTALL=/root/.local/bin`,
        "-e", `FOREMAN_API_BASE=${mockServer.apiBase}`,
        "-e", `FOREMAN_RELEASES_BASE=${mockServer.releasesBase}`,
        "-e", "TERM=dumb",
        "ubuntu:latest", "sh", "-c", installCmd,
      ];

      const { output, exitCode } = await new Promise<{ output: string; exitCode: number }>((resolve, reject) => {
        const chunks: Buffer[] = [];
        const proc = spawn("docker", dockerArgs, { stdio: ["ignore", "pipe", "pipe"] });
        proc.stdout?.on("data", (d: Buffer) => chunks.push(d));
        proc.stderr?.on("data", (d: Buffer) => chunks.push(d));
        proc.on("close", (code) => resolve({ output: Buffer.concat(chunks).toString(), exitCode: code ?? -1 }));
        proc.on("error", reject);
        setTimeout(() => { proc.kill(); reject(new Error("timeout")); }, 120_000);
      });

      console.log("[docker-test] Container output:\n", output.slice(0, 2000));

      expect(exitCode).toBe(0);
      expect(output).toContain("BINARY_EXISTS: YES");
      expect(output).toContain("BINARY_EXECUTABLE: YES");
      expect(output).toContain(`foreman ${MOCK_VERSION}`);
    },
    180_000
  );

  it(
    "installs better_sqlite3.node side-car alongside binary",
    async () => {
      if (!mockServer) {
        expect.fail("Test setup failed — no mock server");
      }

      const installShInMount = path.join(tmpDir, "install.sh");
      if (!existsSync(installShInMount)) {
        writeFileSync(installShInMount, readFileSync(INSTALL_SH), { mode: 0o755 });
      }

      const installCmd = [
        "apt-get update -qq 2>/dev/null",
        "apt-get install -y -qq curl tar 2>/dev/null",
        "sh /install.sh",
        "test -f /root/.local/bin/better_sqlite3.node && echo 'ADDON_EXISTS: YES' || echo 'ADDON_EXISTS: NO'",
      ].join(" && ");

      const dockerArgs = [
        "run", "--rm", "--network=host",
        "-v", `${installShInMount}:/install.sh:ro`,
        "-e", `FOREMAN_VERSION=${MOCK_VERSION}`,
        "-e", "FOREMAN_INSTALL=/root/.local/bin",
        "-e", `FOREMAN_API_BASE=${mockServer.apiBase}`,
        "-e", `FOREMAN_RELEASES_BASE=${mockServer.releasesBase}`,
        "-e", "TERM=dumb",
        "ubuntu:latest", "sh", "-c", installCmd,
      ];

      const { output, exitCode } = await new Promise<{ output: string; exitCode: number }>((resolve, reject) => {
        const chunks: Buffer[] = [];
        const proc = spawn("docker", dockerArgs, { stdio: ["ignore", "pipe", "pipe"] });
        proc.stdout?.on("data", (d: Buffer) => chunks.push(d));
        proc.stderr?.on("data", (d: Buffer) => chunks.push(d));
        proc.on("close", (code) => resolve({ output: Buffer.concat(chunks).toString(), exitCode: code ?? -1 }));
        proc.on("error", reject);
        setTimeout(() => { proc.kill(); reject(new Error("timeout")); }, 120_000);
      });

      expect(exitCode).toBe(0);
      expect(output).toContain("ADDON_EXISTS: YES");
    },
    180_000
  );

  it(
    "detects linux platform and x64/arm64 architecture correctly",
    async () => {
      if (!mockServer) {
        expect.fail("Test setup failed — no mock server");
      }

      const installShInMount = path.join(tmpDir, "install.sh");
      if (!existsSync(installShInMount)) {
        writeFileSync(installShInMount, readFileSync(INSTALL_SH), { mode: 0o755 });
      }

      const installCmd = [
        "apt-get update -qq 2>/dev/null",
        "apt-get install -y -qq curl tar 2>/dev/null",
        "sh /install.sh 2>&1",
      ].join(" && ");

      const dockerArgs = [
        "run", "--rm", "--network=host",
        "-v", `${installShInMount}:/install.sh:ro`,
        "-e", `FOREMAN_VERSION=${MOCK_VERSION}`,
        "-e", "FOREMAN_INSTALL=/tmp/foreman-platform-test",
        "-e", `FOREMAN_API_BASE=${mockServer.apiBase}`,
        "-e", `FOREMAN_RELEASES_BASE=${mockServer.releasesBase}`,
        "-e", "TERM=dumb",
        "ubuntu:latest", "sh", "-c", installCmd,
      ];

      const { output } = await new Promise<{ output: string; exitCode: number }>((resolve, reject) => {
        const chunks: Buffer[] = [];
        const proc = spawn("docker", dockerArgs, { stdio: ["ignore", "pipe", "pipe"] });
        proc.stdout?.on("data", (d: Buffer) => chunks.push(d));
        proc.stderr?.on("data", (d: Buffer) => chunks.push(d));
        proc.on("close", (code) => resolve({ output: Buffer.concat(chunks).toString(), exitCode: code ?? -1 }));
        proc.on("error", reject);
        setTimeout(() => { proc.kill(); reject(new Error("timeout")); }, 120_000);
      });

      // Script should report platform detection
      expect(output).toMatch(/Platform detected: linux-(x64|arm64)/);
    },
    180_000
  );

  it(
    "verifies mock server received expected archive download request",
    () => {
      if (!mockServer) {
        expect.fail("Mock server not initialized");
      }

      const requestUrls = mockServer.requestLog.map((r) => r.url);
      console.log(
        "[docker-test] Requests received by mock server:",
        requestUrls
      );

      // Archive download must have been made
      const archiveDownloaded = requestUrls.some((url) =>
        url.includes(".tar.gz")
      );
      expect(archiveDownloaded).toBe(true);
    },
    5_000
  );

  // ── Error handling ──────────────────────────────────────────────────────────

  it(
    "fails with helpful error on invalid version format",
    async () => {
      if (!mockServer) {
        expect.fail("Test setup failed — no mock server");
      }

      const installShInMount = path.join(tmpDir, "install.sh");
      if (!existsSync(installShInMount)) {
        writeFileSync(installShInMount, readFileSync(INSTALL_SH), { mode: 0o755 });
      }

      const installCmd = [
        "apt-get update -qq 2>/dev/null",
        "apt-get install -y -qq curl tar 2>/dev/null",
        "sh /install.sh 2>&1 || true",
      ].join(" && ");

      const dockerArgs = [
        "run", "--rm", "--network=host",
        "-v", `${installShInMount}:/install.sh:ro`,
        "-e", "FOREMAN_VERSION=1.0.0-no-v-prefix", // Invalid: no 'v' prefix
        "-e", "FOREMAN_INSTALL=/tmp/test-bad-version",
        "-e", `FOREMAN_API_BASE=${mockServer.apiBase}`,
        "-e", `FOREMAN_RELEASES_BASE=${mockServer.releasesBase}`,
        "-e", "TERM=dumb",
        "ubuntu:latest", "sh", "-c", installCmd,
      ];

      const { output } = await new Promise<{ output: string; exitCode: number }>((resolve, reject) => {
        const chunks: Buffer[] = [];
        const proc = spawn("docker", dockerArgs, { stdio: ["ignore", "pipe", "pipe"] });
        proc.stdout?.on("data", (d: Buffer) => chunks.push(d));
        proc.stderr?.on("data", (d: Buffer) => chunks.push(d));
        proc.on("close", (code) => resolve({ output: Buffer.concat(chunks).toString(), exitCode: code ?? -1 }));
        proc.on("error", reject);
        setTimeout(() => { proc.kill(); reject(new Error("timeout")); }, 120_000);
      });

      expect(output).toContain("Invalid version format");
    },
    180_000
  );
});

// ── Static prerequisite checks ────────────────────────────────────────────────

describe("install.sh Docker test prerequisites", () => {
  it("Docker daemon status is reported", () => {
    const available = isDockerAvailable();
    console.log(
      `  Docker daemon: ${available ? "✓ running" : "✗ not running (Docker tests will be skipped)"}`
    );
    // Always pass — just informational
    expect(typeof available).toBe("boolean");
  });

  it("install.sh exists and is readable", () => {
    expect(existsSync(INSTALL_SH)).toBe(true);
    const content = readFileSync(INSTALL_SH, "utf-8");
    expect(content.length).toBeGreaterThan(0);
  });

  it("install.sh supports FOREMAN_API_BASE env var override", () => {
    const content = readFileSync(INSTALL_SH, "utf-8");
    expect(content).toContain("FOREMAN_API_BASE");
  });

  it("install.sh supports FOREMAN_RELEASES_BASE env var override", () => {
    const content = readFileSync(INSTALL_SH, "utf-8");
    expect(content).toContain("FOREMAN_RELEASES_BASE");
  });
});
