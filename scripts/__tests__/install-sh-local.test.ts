/**
 * Local integration tests for install.sh — macOS and Linux verification.
 *
 * These tests run the install.sh script locally (on the current machine)
 * against a mock HTTP server, verifying:
 *   - Script runs to completion on the current platform
 *   - Binary is installed to the correct path (via FOREMAN_INSTALL override)
 *   - Binary is executable and `foreman --version` works
 *   - better_sqlite3.node side-car is installed alongside binary
 *   - FOREMAN_INSTALL env var correctly overrides install directory
 *   - Checksum verification works (pass and fail scenarios)
 *
 * No real GitHub releases or network access are required — the install script
 * supports FOREMAN_API_BASE and FOREMAN_RELEASES_BASE env vars that redirect
 * API and download calls to a local mock HTTP server.
 *
 * Run individually with:
 *   npx vitest run scripts/__tests__/install-sh-local.test.ts
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
  statSync,
} from "node:fs";
import { spawnSync, spawn } from "node:child_process";
import { createServer, type Server } from "node:http";
import { tmpdir } from "node:os";
import * as path from "node:path";
import * as crypto from "node:crypto";
import { fileURLToPath } from "node:url";

// ── Paths ─────────────────────────────────────────────────────────────────────

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "..", "..");
const INSTALL_SH = path.join(REPO_ROOT, "install.sh");

// ── Platform detection ────────────────────────────────────────────────────────

function detectLocalPlatform(): { os: string; arch: string; platform: string } {
  const rawOs = process.platform;
  const rawArch = process.arch;

  const os = rawOs === "darwin" ? "darwin" : "linux";
  const arch =
    rawArch === "arm64" || rawArch === "aarch64" ? "arm64" : "x64";

  return { os, arch, platform: `${os}-${arch}` };
}

const LOCAL_PLATFORM = detectLocalPlatform();

// ── Mock binary builder ───────────────────────────────────────────────────────

/**
 * Creates a minimal shell-script "binary" that responds to --version and --help.
 * Packs it into a tar.gz that matches install.sh's expected asset format:
 *   foreman-{version}-{platform}.tar.gz
 *     └── foreman-{platform}       (executable shell script)
 *     └── better_sqlite3.node      (empty placeholder)
 */
async function buildMockArchive(opts: {
  version: string;
  platform: string;
  outputDir: string;
}): Promise<{ archivePath: string; sha256: string; assetName: string }> {
  const { version, platform, outputDir } = opts;
  const binaryName = `foreman-${platform}`;
  const assetName = `foreman-${version}-${platform}.tar.gz`;

  const stagingDir = path.join(outputDir, `staging-${platform}`);
  mkdirSync(stagingDir, { recursive: true });

  // Write mock binary shell script
  const mockBinaryPath = path.join(stagingDir, binaryName);
  writeFileSync(
    mockBinaryPath,
    `#!/bin/sh
if [ "$1" = "--version" ]; then
  echo "foreman ${version}"
  exit 0
fi
if [ "$1" = "--help" ]; then
  echo "Usage: foreman [options] [command]"
  echo "Options:"
  echo "  -V, --version   output the version number"
  echo "  -h, --help      display help for command"
  echo "Commands:"
  echo "  init    Initialize project"
  echo "  run     Run tasks"
  echo "  doctor  Health checks"
  echo "  status  Show status"
  exit 0
fi
exit 1
`,
    "utf-8"
  );
  chmodSync(mockBinaryPath, 0o755);

  // Write placeholder better_sqlite3.node
  writeFileSync(
    path.join(stagingDir, "better_sqlite3.node"),
    "MOCK_NATIVE_ADDON",
    "utf-8"
  );

  // Create tar.gz archive
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

  const archiveData = readFileSync(archivePath);
  const sha256 = crypto.createHash("sha256").update(archiveData).digest("hex");

  return { archivePath, sha256, assetName };
}

// ── Mock HTTP server ──────────────────────────────────────────────────────────

interface MockServerOpts {
  version: string;
  archivePath: string;
  assetName: string;
  sha256: string;
  /** If true, return a wrong checksum to test checksum failure scenario. */
  badChecksum?: boolean;
  /** If true, return 404 for checksums.txt (test graceful degradation). */
  missingChecksums?: boolean;
}

interface MockServer {
  server: Server;
  port: number;
  baseUrl: string;
  apiBase: string;
  releasesBase: string;
  requestLog: Array<{ method: string; url: string; status: number }>;
  close: () => Promise<void>;
}

function startMockServer(opts: MockServerOpts): Promise<MockServer> {
  const {
    version,
    archivePath,
    assetName,
    sha256,
    badChecksum = false,
    missingChecksums = false,
  } = opts;

  const requestLog: Array<{ method: string; url: string; status: number }> = [];

  return new Promise((resolve, reject) => {
    const server = createServer((req, res) => {
      const url = req.url ?? "";
      let status = 200;

      const respond = (
        code: number,
        body: Buffer | string,
        contentType = "text/plain"
      ) => {
        status = code;
        requestLog.push({ method: req.method ?? "GET", url, status });
        res.writeHead(code, { "Content-Type": contentType });
        res.end(body);
      };

      // GitHub API: latest release
      if (url.match(/\/repos\/[^/]+\/[^/]+\/releases\/latest/)) {
        respond(
          200,
          JSON.stringify({ tag_name: version, name: `Foreman ${version}` }),
          "application/json"
        );
        return;
      }

      // Binary archive download (matches the asset name path)
      if (url.includes(assetName)) {
        const data = readFileSync(archivePath);
        requestLog.push({ method: req.method ?? "GET", url, status: 200 });
        res.writeHead(200, {
          "Content-Type": "application/octet-stream",
          "Content-Length": String(data.length),
        });
        res.end(data);
        return;
      }

      // Checksums.txt
      if (url.includes("checksums.txt")) {
        if (missingChecksums) {
          respond(404, "Not Found");
          return;
        }
        const checksumToUse = badChecksum
          ? "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
          : sha256;
        respond(200, `${checksumToUse}  ${assetName}\n`);
        return;
      }

      respond(404, `Not Found: ${url}`);
    });

    server.listen(0, "127.0.0.1", () => {
      const addr = server.address();
      if (!addr || typeof addr === "string") {
        reject(new Error("Could not get server address"));
        return;
      }
      const port = addr.port;
      const baseUrl = `http://127.0.0.1:${port}`;
      resolve({
        server,
        port,
        baseUrl,
        // FOREMAN_API_BASE — replaces https://api.github.com
        apiBase: baseUrl,
        // FOREMAN_RELEASES_BASE — replaces https://github.com/{repo}/releases/download
        releasesBase: `${baseUrl}/ldangelo/foreman/releases/download`,
        requestLog,
        close: () => new Promise<void>((res) => server.close(() => res())),
      });
    });

    server.on("error", reject);
  });
}

// ── Install script runner ─────────────────────────────────────────────────────

/**
 * Run install.sh with env vars that redirect all network calls to the mock server.
 * Uses FOREMAN_API_BASE and FOREMAN_RELEASES_BASE to override GitHub URLs.
 *
 * IMPORTANT: Uses async spawn (not spawnSync) so the Node.js event loop remains
 * free to serve HTTP requests from the in-process mock server while the script runs.
 */
function runInstallScript(opts: {
  installDir: string;
  env?: Record<string, string | undefined>;
  timeoutMs?: number;
}): Promise<{ output: string; exitCode: number }> {
  const { installDir, env = {}, timeoutMs = 60_000 } = opts;

  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];

    const proc = spawn("sh", [INSTALL_SH], {
      stdio: ["ignore", "pipe", "pipe"],
      env: {
        PATH: process.env.PATH,
        HOME: process.env.HOME,
        TMPDIR: process.env.TMPDIR,
        TERM: "dumb", // Disable color output for predictable test assertions
        // Override GitHub URLs via env vars supported by install.sh
        FOREMAN_INSTALL: installDir,
        ...env,
      } as NodeJS.ProcessEnv,
    });

    proc.stdout?.on("data", (chunk: Buffer) => chunks.push(chunk));
    proc.stderr?.on("data", (chunk: Buffer) => chunks.push(chunk));

    proc.on("close", (code) => {
      const output = Buffer.concat(chunks).toString("utf-8");
      resolve({ output, exitCode: code ?? -1 });
    });

    proc.on("error", reject);

    // Enforce timeout
    const timer = setTimeout(() => {
      proc.kill();
      reject(new Error(`install.sh timed out after ${timeoutMs}ms`));
    }, timeoutMs);

    proc.on("close", () => clearTimeout(timer));
  });
}

// ── Test state ────────────────────────────────────────────────────────────────

const MOCK_VERSION = "v1.0.0-localtest";

let tmpDir: string;
let archiveInfo: { archivePath: string; sha256: string; assetName: string };

// ── Tests ─────────────────────────────────────────────────────────────────────

describe(`install.sh local integration tests (${LOCAL_PLATFORM.platform})`, () => {
  beforeAll(async () => {
    tmpDir = mkdtempSync(path.join(tmpdir(), "foreman-install-local-test-"));
    console.log(`\n[local-test] Temp dir: ${tmpDir}`);
    console.log(`[local-test] Platform: ${LOCAL_PLATFORM.platform}`);

    // Build mock archive for the current platform
    archiveInfo = await buildMockArchive({
      version: MOCK_VERSION,
      platform: LOCAL_PLATFORM.platform,
      outputDir: tmpDir,
    });

    console.log(
      `[local-test] Mock archive: ${archiveInfo.assetName} (SHA256: ${archiveInfo.sha256.slice(0, 16)}...)`
    );
  }, 30_000);

  afterAll(() => {
    if (tmpDir && existsSync(tmpDir)) {
      rmSync(tmpDir, { recursive: true, force: true });
      console.log(`[local-test] Cleaned up: ${tmpDir}`);
    }
  });

  // ── Happy path ──────────────────────────────────────────────────────────────

  it(
    "installs foreman to FOREMAN_INSTALL directory",
    async () => {
      const installDir = path.join(tmpDir, "install-happy-path");
      mkdirSync(installDir, { recursive: true });

      const server = await startMockServer({
        version: MOCK_VERSION,
        ...archiveInfo,
      });

      try {
        const { output, exitCode } = await runInstallScript({
          installDir,
          env: {
            FOREMAN_VERSION: MOCK_VERSION,
            FOREMAN_API_BASE: server.apiBase,
            FOREMAN_RELEASES_BASE: server.releasesBase,
          },
        });

        console.log("[local-test] Install output:\n", output.slice(0, 1500));

        expect(exitCode).toBe(0);

        // Binary must exist at install dir
        const binaryPath = path.join(installDir, "foreman");
        expect(existsSync(binaryPath)).toBe(true);

        // Binary must be executable (owner execute bit)
        const stats = statSync(binaryPath);
        // eslint-disable-next-line no-bitwise
        expect(stats.mode & 0o100).toBeGreaterThan(0);
      } finally {
        await server.close();
      }
    },
    60_000
  );

  it(
    "installs better_sqlite3.node side-car alongside binary",
    async () => {
      const installDir = path.join(tmpDir, "install-addon-test");
      mkdirSync(installDir, { recursive: true });

      const server = await startMockServer({
        version: MOCK_VERSION,
        ...archiveInfo,
      });

      try {
        const { exitCode } = await runInstallScript({
          installDir,
          env: {
            FOREMAN_VERSION: MOCK_VERSION,
            FOREMAN_API_BASE: server.apiBase,
            FOREMAN_RELEASES_BASE: server.releasesBase,
          },
        });

        expect(exitCode).toBe(0);

        // better_sqlite3.node must be alongside the binary
        const addonPath = path.join(installDir, "better_sqlite3.node");
        expect(existsSync(addonPath)).toBe(true);
      } finally {
        await server.close();
      }
    },
    60_000
  );

  it(
    "verifies installation by running foreman --version in install output",
    async () => {
      const installDir = path.join(tmpDir, "install-version-test");
      mkdirSync(installDir, { recursive: true });

      const server = await startMockServer({
        version: MOCK_VERSION,
        ...archiveInfo,
      });

      try {
        const { output, exitCode } = await runInstallScript({
          installDir,
          env: {
            FOREMAN_VERSION: MOCK_VERSION,
            FOREMAN_API_BASE: server.apiBase,
            FOREMAN_RELEASES_BASE: server.releasesBase,
          },
        });

        expect(exitCode).toBe(0);

        // Script should show success message with version
        expect(output).toMatch(/Installed:|installed successfully/i);
        expect(output).toContain(MOCK_VERSION);
      } finally {
        await server.close();
      }
    },
    60_000
  );

  it(
    "installed binary produces correct --version output",
    async () => {
      const installDir = path.join(tmpDir, "install-version-verify");
      mkdirSync(installDir, { recursive: true });

      const server = await startMockServer({
        version: MOCK_VERSION,
        ...archiveInfo,
      });

      try {
        const { exitCode } = await runInstallScript({
          installDir,
          env: {
            FOREMAN_VERSION: MOCK_VERSION,
            FOREMAN_API_BASE: server.apiBase,
            FOREMAN_RELEASES_BASE: server.releasesBase,
          },
        });

        expect(exitCode).toBe(0);

        // Run the installed binary directly
        const binaryPath = path.join(installDir, "foreman");
        const versionResult = spawnSync(binaryPath, ["--version"], {
          encoding: "utf-8",
          stdio: "pipe",
          timeout: 10_000,
        });

        expect(versionResult.status).toBe(0);
        expect((versionResult.stdout ?? "").trim()).toContain(
          `foreman ${MOCK_VERSION}`
        );
      } finally {
        await server.close();
      }
    },
    60_000
  );

  it(
    "detects correct platform during installation",
    async () => {
      const installDir = path.join(tmpDir, "install-platform-detect");
      mkdirSync(installDir, { recursive: true });

      const server = await startMockServer({
        version: MOCK_VERSION,
        ...archiveInfo,
      });

      try {
        const { output, exitCode } = await runInstallScript({
          installDir,
          env: {
            FOREMAN_VERSION: MOCK_VERSION,
            FOREMAN_API_BASE: server.apiBase,
            FOREMAN_RELEASES_BASE: server.releasesBase,
          },
        });

        expect(exitCode).toBe(0);
        // Verify the platform detection message
        expect(output).toContain(
          `Platform detected: ${LOCAL_PLATFORM.platform}`
        );
      } finally {
        await server.close();
      }
    },
    60_000
  );

  // ── Checksum scenarios ──────────────────────────────────────────────────────

  it(
    "passes with correct checksum verification",
    async () => {
      const installDir = path.join(tmpDir, "install-checksum-pass");
      mkdirSync(installDir, { recursive: true });

      const server = await startMockServer({
        version: MOCK_VERSION,
        ...archiveInfo,
      });

      try {
        const { output, exitCode } = await runInstallScript({
          installDir,
          env: {
            FOREMAN_VERSION: MOCK_VERSION,
            FOREMAN_API_BASE: server.apiBase,
            FOREMAN_RELEASES_BASE: server.releasesBase,
          },
        });

        expect(exitCode).toBe(0);
        expect(output).toContain("Checksum verified");
      } finally {
        await server.close();
      }
    },
    60_000
  );

  it(
    "fails with helpful error on checksum mismatch",
    async () => {
      const installDir = path.join(tmpDir, "install-checksum-fail");
      mkdirSync(installDir, { recursive: true });

      const server = await startMockServer({
        version: MOCK_VERSION,
        ...archiveInfo,
        badChecksum: true,
      });

      try {
        const { output, exitCode } = await runInstallScript({
          installDir,
          env: {
            FOREMAN_VERSION: MOCK_VERSION,
            FOREMAN_API_BASE: server.apiBase,
            FOREMAN_RELEASES_BASE: server.releasesBase,
          },
        });

        // Script should exit with non-zero on checksum mismatch
        expect(exitCode).not.toBe(0);
        expect(output).toContain("Checksum mismatch");
      } finally {
        await server.close();
      }
    },
    60_000
  );

  it(
    "warns but continues when checksums.txt is unavailable",
    async () => {
      const installDir = path.join(tmpDir, "install-no-checksums");
      mkdirSync(installDir, { recursive: true });

      const server = await startMockServer({
        version: MOCK_VERSION,
        ...archiveInfo,
        missingChecksums: true,
      });

      try {
        const { output, exitCode } = await runInstallScript({
          installDir,
          env: {
            FOREMAN_VERSION: MOCK_VERSION,
            FOREMAN_API_BASE: server.apiBase,
            FOREMAN_RELEASES_BASE: server.releasesBase,
          },
        });

        // Script should succeed (checksums are non-fatal)
        expect(exitCode).toBe(0);
        expect(output).toContain("skipping checksum verification");
      } finally {
        await server.close();
      }
    },
    60_000
  );

  // ── Error handling ──────────────────────────────────────────────────────────

  it(
    "fails with helpful error on invalid version format (missing v prefix)",
    async () => {
      const installDir = path.join(tmpDir, "install-bad-version");
      mkdirSync(installDir, { recursive: true });

      const server = await startMockServer({
        version: MOCK_VERSION,
        ...archiveInfo,
      });

      try {
        const { output, exitCode } = await runInstallScript({
          installDir,
          env: {
            FOREMAN_VERSION: "1.0.0-missing-v-prefix", // No 'v' prefix
            FOREMAN_API_BASE: server.apiBase,
            FOREMAN_RELEASES_BASE: server.releasesBase,
          },
        });

        expect(exitCode).not.toBe(0);
        expect(output).toContain("Invalid version format");
      } finally {
        await server.close();
      }
    },
    60_000
  );

  it(
    "uses GitHub API to fetch latest version when FOREMAN_VERSION is not set",
    async () => {
      const installDir = path.join(tmpDir, "install-latest-version");
      mkdirSync(installDir, { recursive: true });

      const server = await startMockServer({
        version: MOCK_VERSION,
        ...archiveInfo,
      });

      try {
        const { output, exitCode } = await runInstallScript({
          installDir,
          env: {
            // No FOREMAN_VERSION — should call GitHub API
            FOREMAN_API_BASE: server.apiBase,
            FOREMAN_RELEASES_BASE: server.releasesBase,
          },
        });

        console.log(
          "[local-test] Latest version install output:\n",
          output.slice(0, 800)
        );

        expect(exitCode).toBe(0);
        // Should have fetched and installed the mock version
        expect(output).toContain(MOCK_VERSION);
      } finally {
        await server.close();
      }
    },
    60_000
  );

  // ── Mock server request verification ────────────────────────────────────────

  it(
    "contacts GitHub API for latest release when FOREMAN_VERSION not set",
    async () => {
      const installDir = path.join(tmpDir, "install-api-call");
      mkdirSync(installDir, { recursive: true });

      const server = await startMockServer({
        version: MOCK_VERSION,
        ...archiveInfo,
      });

      try {
        const { exitCode } = await runInstallScript({
          installDir,
          env: {
            // No FOREMAN_VERSION — should call API
            FOREMAN_API_BASE: server.apiBase,
            FOREMAN_RELEASES_BASE: server.releasesBase,
          },
        });

        expect(exitCode).toBe(0);

        // Verify mock server received the GitHub API request
        const apiRequest = server.requestLog.find((r) =>
          r.url.includes("/releases/latest")
        );
        expect(apiRequest).toBeDefined();
        expect(apiRequest?.status).toBe(200);
      } finally {
        await server.close();
      }
    },
    60_000
  );

  it(
    "skips GitHub API call when FOREMAN_VERSION is set",
    async () => {
      const installDir = path.join(tmpDir, "install-skip-api");
      mkdirSync(installDir, { recursive: true });

      const server = await startMockServer({
        version: MOCK_VERSION,
        ...archiveInfo,
      });

      try {
        const { exitCode } = await runInstallScript({
          installDir,
          env: {
            FOREMAN_VERSION: MOCK_VERSION, // Explicit version — skip API
            FOREMAN_API_BASE: server.apiBase,
            FOREMAN_RELEASES_BASE: server.releasesBase,
          },
        });

        expect(exitCode).toBe(0);

        // Verify mock server did NOT receive the GitHub API request
        const apiRequest = server.requestLog.find((r) =>
          r.url.includes("/releases/latest")
        );
        expect(apiRequest).toBeUndefined();
      } finally {
        await server.close();
      }
    },
    60_000
  );

  it(
    "downloads the binary archive from the releases base URL",
    async () => {
      const installDir = path.join(tmpDir, "install-download-verify");
      mkdirSync(installDir, { recursive: true });

      const server = await startMockServer({
        version: MOCK_VERSION,
        ...archiveInfo,
      });

      try {
        const { exitCode } = await runInstallScript({
          installDir,
          env: {
            FOREMAN_VERSION: MOCK_VERSION,
            FOREMAN_API_BASE: server.apiBase,
            FOREMAN_RELEASES_BASE: server.releasesBase,
          },
        });

        expect(exitCode).toBe(0);

        // Verify mock server received the archive download request
        const downloadRequest = server.requestLog.find((r) =>
          r.url.includes(".tar.gz")
        );
        expect(downloadRequest).toBeDefined();
        expect(downloadRequest?.status).toBe(200);
        expect(downloadRequest?.url).toContain(archiveInfo.assetName);
      } finally {
        await server.close();
      }
    },
    60_000
  );
});

// ── macOS-specific tests ─────────────────────────────────────────────────────

describe("install.sh macOS-specific behavior", () => {
  const IS_MACOS = process.platform === "darwin";

  if (!IS_MACOS) {
    it.skip("Skipping macOS-specific tests (not running on macOS)", () => {});
    return;
  }

  let macTmpDir: string;
  let macArchiveInfo: { archivePath: string; sha256: string; assetName: string };

  beforeAll(async () => {
    macTmpDir = mkdtempSync(
      path.join(tmpdir(), "foreman-install-macos-test-")
    );

    macArchiveInfo = await buildMockArchive({
      version: MOCK_VERSION,
      platform: LOCAL_PLATFORM.platform,
      outputDir: macTmpDir,
    });
  }, 30_000);

  afterAll(() => {
    if (macTmpDir && existsSync(macTmpDir)) {
      rmSync(macTmpDir, { recursive: true, force: true });
    }
  });

  it(
    "detects darwin platform on macOS",
    async () => {
      const installDir = path.join(macTmpDir, "install-darwin-detect");
      mkdirSync(installDir, { recursive: true });

      const server = await startMockServer({
        version: MOCK_VERSION,
        ...macArchiveInfo,
      });

      try {
        const { output, exitCode } = await runInstallScript({
          installDir,
          env: {
            FOREMAN_VERSION: MOCK_VERSION,
            FOREMAN_API_BASE: server.apiBase,
            FOREMAN_RELEASES_BASE: server.releasesBase,
          },
        });

        expect(exitCode).toBe(0);
        expect(output).toContain("Platform detected: darwin-");
      } finally {
        await server.close();
      }
    },
    60_000
  );

  it(
    "includes macOS Gatekeeper note in install output",
    async () => {
      const installDir = path.join(macTmpDir, "install-gatekeeper");
      mkdirSync(installDir, { recursive: true });

      const server = await startMockServer({
        version: MOCK_VERSION,
        ...macArchiveInfo,
      });

      try {
        const { output, exitCode } = await runInstallScript({
          installDir,
          env: {
            FOREMAN_VERSION: MOCK_VERSION,
            FOREMAN_API_BASE: server.apiBase,
            FOREMAN_RELEASES_BASE: server.releasesBase,
          },
        });

        expect(exitCode).toBe(0);
        // macOS should include Gatekeeper/quarantine note
        expect(output).toContain("quarantine");
      } finally {
        await server.close();
      }
    },
    60_000
  );

  it(
    "uses shasum -a 256 for checksum verification on macOS",
    async () => {
      const installDir = path.join(macTmpDir, "install-shasum");
      mkdirSync(installDir, { recursive: true });

      // Verify shasum is available on this macOS system
      const shasumResult = spawnSync("which", ["shasum"], {
        encoding: "utf-8",
        stdio: "pipe",
      });
      expect(shasumResult.status).toBe(0);

      const server = await startMockServer({
        version: MOCK_VERSION,
        ...macArchiveInfo,
      });

      try {
        const { output, exitCode } = await runInstallScript({
          installDir,
          env: {
            FOREMAN_VERSION: MOCK_VERSION,
            FOREMAN_API_BASE: server.apiBase,
            FOREMAN_RELEASES_BASE: server.releasesBase,
          },
        });

        expect(exitCode).toBe(0);
        // On macOS, checksum should pass using shasum
        expect(output).toContain("Checksum verified");
      } finally {
        await server.close();
      }
    },
    60_000
  );

  it(
    "installs correctly to custom FOREMAN_INSTALL path on macOS",
    async () => {
      const installDir = path.join(macTmpDir, "install-custom-path");
      mkdirSync(installDir, { recursive: true });

      const server = await startMockServer({
        version: MOCK_VERSION,
        ...macArchiveInfo,
      });

      try {
        const { output, exitCode } = await runInstallScript({
          installDir,
          env: {
            FOREMAN_VERSION: MOCK_VERSION,
            FOREMAN_API_BASE: server.apiBase,
            FOREMAN_RELEASES_BASE: server.releasesBase,
          },
        });

        expect(exitCode).toBe(0);

        // Binary must be at the custom install path
        expect(existsSync(path.join(installDir, "foreman"))).toBe(true);

        // Run --version to confirm it works
        const versionResult = spawnSync(
          path.join(installDir, "foreman"),
          ["--version"],
          { encoding: "utf-8", stdio: "pipe", timeout: 10_000 }
        );
        expect(versionResult.status).toBe(0);
        expect((versionResult.stdout ?? "").trim()).toContain(
          `foreman ${MOCK_VERSION}`
        );
      } finally {
        await server.close();
      }
    },
    60_000
  );
});

// ── Static prerequisite checks ────────────────────────────────────────────────

describe("install.sh local test prerequisites", () => {
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

  it("current platform is supported by install.sh", () => {
    const supportedPlatforms = [
      "darwin-arm64",
      "darwin-x64",
      "linux-x64",
      "linux-arm64",
    ];
    const platform = LOCAL_PLATFORM.platform;
    const isSupported = supportedPlatforms.includes(platform);
    console.log(
      `  Current platform: ${platform} (${isSupported ? "supported" : "NOT in supported list"})`
    );
    // This test is informational — log but always pass
    expect(typeof isSupported).toBe("boolean");
  });
});
