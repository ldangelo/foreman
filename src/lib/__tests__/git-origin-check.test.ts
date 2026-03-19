import { describe, it, expect, afterEach } from "vitest";
import { mkdtempSync, writeFileSync, rmSync, realpathSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { branchExistsOnOrigin } from "../git.js";

function makeTempRepo(): string {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-git-origin-test-")));
  execFileSync("git", ["init", "--initial-branch=main"], { cwd: dir });
  execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: dir });
  execFileSync("git", ["config", "user.name", "Test"], { cwd: dir });
  writeFileSync(join(dir, "README.md"), "# init\n");
  execFileSync("git", ["add", "."], { cwd: dir });
  execFileSync("git", ["commit", "-m", "initial commit"], { cwd: dir });
  return dir;
}

const tempDirs: string[] = [];

afterEach(() => {
  for (const dir of tempDirs) {
    rmSync(dir, { recursive: true, force: true });
  }
  tempDirs.length = 0;
});

describe("branchExistsOnOrigin", () => {
  it("returns true when branch exists on origin", async () => {
    // Create origin repo with a branch
    const origin = makeTempRepo();
    tempDirs.push(origin);
    execFileSync("git", ["checkout", "-b", "foreman/seed-abc"], { cwd: origin });
    writeFileSync(join(origin, "file.txt"), "content");
    execFileSync("git", ["add", "."], { cwd: origin });
    execFileSync("git", ["commit", "-m", "add file"], { cwd: origin });

    // Clone origin to create a local repo with a remote
    const local = realpathSync(mkdtempSync(join(tmpdir(), "foreman-git-origin-local-")));
    tempDirs.push(local);
    execFileSync("git", ["clone", origin, local]);
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: local });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: local });

    const result = await branchExistsOnOrigin(local, "foreman/seed-abc");
    expect(result).toBe(true);
  });

  it("returns false when branch does not exist on origin", async () => {
    // Create origin repo
    const origin = makeTempRepo();
    tempDirs.push(origin);

    // Clone origin to create a local repo with a remote
    const local = realpathSync(mkdtempSync(join(tmpdir(), "foreman-git-origin-local-")));
    tempDirs.push(local);
    execFileSync("git", ["clone", origin, local]);
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: local });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: local });

    const result = await branchExistsOnOrigin(local, "foreman/nonexistent-branch");
    expect(result).toBe(false);
  });

  it("returns false when repository has no remote configured", async () => {
    // Standalone repo with no remote
    const repo = makeTempRepo();
    tempDirs.push(repo);

    const result = await branchExistsOnOrigin(repo, "foreman/some-branch");
    expect(result).toBe(false);
  });

  it("returns false for local-only branch (not pushed to origin)", async () => {
    // Create origin repo
    const origin = makeTempRepo();
    tempDirs.push(origin);

    // Clone origin
    const local = realpathSync(mkdtempSync(join(tmpdir(), "foreman-git-origin-local-")));
    tempDirs.push(local);
    execFileSync("git", ["clone", origin, local]);
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: local });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: local });

    // Create a local-only branch (not pushed to origin)
    execFileSync("git", ["checkout", "-b", "foreman/local-only"], { cwd: local });
    writeFileSync(join(local, "local.txt"), "local content");
    execFileSync("git", ["add", "."], { cwd: local });
    execFileSync("git", ["commit", "-m", "local commit"], { cwd: local });

    const result = await branchExistsOnOrigin(local, "foreman/local-only");
    expect(result).toBe(false);
  });

  it("returns true when branch was pushed to origin", async () => {
    // Create origin repo (bare clone acts as origin)
    const origin = makeTempRepo();
    tempDirs.push(origin);

    // Clone origin
    const local = realpathSync(mkdtempSync(join(tmpdir(), "foreman-git-origin-local-")));
    tempDirs.push(local);
    execFileSync("git", ["clone", origin, local]);
    execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: local });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: local });

    // Create and push a branch to origin
    execFileSync("git", ["checkout", "-b", "foreman/pushed-branch"], { cwd: local });
    writeFileSync(join(local, "pushed.txt"), "pushed content");
    execFileSync("git", ["add", "."], { cwd: local });
    execFileSync("git", ["commit", "-m", "pushed commit"], { cwd: local });
    execFileSync("git", ["push", "origin", "foreman/pushed-branch"], { cwd: local });

    const result = await branchExistsOnOrigin(local, "foreman/pushed-branch");
    expect(result).toBe(true);
  });
});
