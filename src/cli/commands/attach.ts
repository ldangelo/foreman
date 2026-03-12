import { Command } from "commander";
import { spawn } from "node:child_process";
import { join } from "node:path";
import { ForemanStore } from "../../lib/store.js";

export const attachCommand = new Command("attach")
  .description("Attach to a running or completed agent's Claude session")
  .argument("[id]", "Run ID or seed ID to attach to")
  .option("--list", "List all attachable sessions")
  .option("--worktree", "Open a shell in the agent's worktree instead of attaching")
  .action(async (id: string | undefined, opts: { list?: boolean; worktree?: boolean }) => {
    const store = new ForemanStore();

    if (opts.list) {
      listSessions(store);
      store.close();
      return;
    }

    if (!id) {
      console.error("Usage: foreman attach <run-id|seed-id>");
      console.error("       foreman attach --list");
      store.close();
      process.exit(1);
    }

    // Look up by run ID first, then by seed ID (most recent run)
    let run = store.getRun(id);
    if (!run) {
      // Try as seed ID — get the most recent run for this seed
      const project = store.getProjectByPath(process.cwd());
      if (project) {
        const runs = store.getRunsForSeed(id, project.id);
        if (runs.length > 0) {
          run = runs[0]; // Most recent
        }
      }
    }

    if (!run) {
      console.error(`No run found for "${id}". Use 'foreman attach --list' to see available sessions.`);
      store.close();
      process.exit(1);
    }

    // Extract session ID
    const sessionId = extractSessionId(run.session_key);

    if (opts.worktree) {
      if (!run.worktree_path) {
        console.error(`Run ${run.id} has no worktree path.`);
        store.close();
        process.exit(1);
      }
      console.log(`Opening shell in ${run.worktree_path}`);
      store.close();
      const shell = process.env.SHELL ?? "/bin/bash";
      spawn(shell, [], {
        cwd: run.worktree_path,
        stdio: "inherit",
      }).on("exit", (code) => process.exit(code ?? 0));
      return;
    }

    if (!sessionId) {
      console.error(`Run ${run.id} has no SDK session ID.`);
      console.error("The agent may not have established a session yet, or this was a CLI-spawned run.");
      console.error("Try again shortly, or use 'foreman run --resume' instead.");
      store.close();
      process.exit(1);
    }

    console.log(`Attaching to ${run.seed_id} [${run.agent_type}] session=${sessionId}`);
    console.log(`  Status: ${run.status}`);
    if (run.worktree_path) {
      console.log(`  Worktree: ${run.worktree_path}`);
    }
    console.log();

    store.close();

    // Spawn claude --resume interactively
    const child = spawn("claude", ["--resume", sessionId], {
      cwd: run.worktree_path ?? process.cwd(),
      stdio: "inherit",
    });

    child.on("error", (err) => {
      console.error(`Failed to launch claude: ${err.message}`);
      console.error("Ensure 'claude' CLI is installed and in your PATH.");
      process.exit(1);
    });

    child.on("exit", (code) => {
      process.exit(code ?? 0);
    });
  });

function listSessions(store: ForemanStore): void {
  const project = store.getProjectByPath(process.cwd());
  if (!project) {
    console.error("No project registered for this directory. Run 'foreman init' first.");
    return;
  }

  // Get all runs with session IDs
  const statuses = ["running", "completed", "stuck", "failed"] as const;
  const allRuns = statuses.flatMap((s) => store.getRunsByStatus(s, project.id));

  if (allRuns.length === 0) {
    console.log("No sessions found.");
    return;
  }

  console.log("Attachable sessions:\n");
  console.log(
    "  " +
    "RUN ID".padEnd(14) +
    "SEED".padEnd(20) +
    "STATUS".padEnd(12) +
    "MODEL".padEnd(22) +
    "SESSION",
  );
  console.log("  " + "─".repeat(90));

  for (const run of allRuns) {
    const sessionId = extractSessionId(run.session_key);
    const sessionDisplay = sessionId ? sessionId.slice(0, 16) + "…" : "(none)";
    const model = run.agent_type.replace("claude-", "").replace("-20251001", "");
    console.log(
      "  " +
      run.id.slice(0, 12).padEnd(14) +
      run.seed_id.padEnd(20) +
      run.status.padEnd(12) +
      model.padEnd(22) +
      sessionDisplay,
    );
  }
  console.log();
}

function extractSessionId(sessionKey: string | null): string | null {
  if (!sessionKey) return null;
  const m = sessionKey.match(/session-(.+)$/);
  return m ? m[1] : null;
}
