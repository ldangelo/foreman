import { Command } from "commander";
import chalk from "chalk";
import { resolve } from "node:path";
import { ForemanStore } from "../../lib/store.js";
import { SeedsClient } from "../../lib/seeds.js";
import { GroupManager } from "../../orchestrator/group-manager.js";

// ── group create ──────────────────────────────────────────────────────────

const groupCreateCommand = new Command("create")
  .description("Create a new task group")
  .argument("<name>", "Group name")
  .option("--parent <seed-id>", "Parent seed to auto-close when group completes")
  .option("--project <path>", "Project path (default: current directory)")
  .action(async (name: string, opts: { parent?: string; project?: string }) => {
    const projectPath = resolve(opts.project ?? ".");
    const store = new ForemanStore();
    try {
      const project = store.getProjectByPath(projectPath);
      if (!project) {
        console.error(chalk.red("Project not found. Run 'foreman init' first."));
        process.exit(1);
      }

      const group = store.createGroup(project.id, name, opts.parent);
      console.log(chalk.green("✓") + ` Created group ${chalk.bold(group.name)}`);
      console.log(`  Name:   ${group.name}`);
      if (group.parent_seed_id) {
        console.log(`  Parent: ${group.parent_seed_id}`);
      }
      console.log();
      console.log(chalk.dim("Group ID: ") + group.id);
    } finally {
      store.close();
    }
  });

// ── group add ─────────────────────────────────────────────────────────────

const groupAddCommand = new Command("add")
  .description("Add seed(s) to a task group")
  .argument("<group-id>", "Group ID")
  .argument("<seed-ids...>", "Seed ID(s) to add")
  .action(async (groupId: string, seedIds: string[]) => {
    const store = new ForemanStore();
    try {
      const group = store.getGroup(groupId);
      if (!group) {
        console.error(chalk.red(`Group '${groupId}' not found.`));
        process.exit(1);
      }

      for (const seedId of seedIds) {
        store.addGroupMember(groupId, seedId);
        console.log(chalk.green("✓") + ` Added ${seedId} to group ${chalk.bold(groupId)}`);
      }
    } finally {
      store.close();
    }
  });

// ── group status ──────────────────────────────────────────────────────────

const groupStatusCommand = new Command("status")
  .description("Show task group status")
  .argument("[group-id]", "Group ID (shows all groups if omitted)")
  .option("--project <path>", "Project path (default: current directory)")
  .action(async (groupId: string | undefined, opts: { project?: string }) => {
    const projectPath = resolve(opts.project ?? ".");
    const store = new ForemanStore();
    const seeds = new SeedsClient(projectPath);
    const manager = new GroupManager(store, seeds);

    try {
      if (groupId) {
        // Show status for a specific group
        const status = await manager.getGroupStatus(groupId);
        if (!status) {
          console.error(chalk.red(`Group '${groupId}' not found.`));
          process.exit(1);
        }

        const { group, members, total, completed, progress } = status;
        const statusColor = group.status === "completed" ? chalk.green :
                            group.status === "failed" ? chalk.red : chalk.yellow;

        console.log(chalk.bold(`Group: ${group.name}`));
        console.log(`  ID:       ${group.id}`);
        console.log(`  Status:   ${statusColor(group.status)}`);
        if (group.parent_seed_id) {
          console.log(`  Parent:   ${group.parent_seed_id}`);
        }
        console.log(`  Progress: ${chalk.cyan(`${completed}/${total}`)} (${progress}%)`);
        console.log();

        if (members.length === 0) {
          console.log(chalk.dim("  (no members)"));
        } else {
          console.log(chalk.bold("Members:"));
          for (const m of members) {
            const isDone = m.status === "closed" || m.status === "completed";
            const statusIcon = isDone ? chalk.green("✓") : chalk.yellow("○");
            console.log(`  ${statusIcon} ${m.seed_id} — ${chalk.dim(m.status)} — ${m.title}`);
          }
        }
      } else {
        // Show all groups for the project
        const project = store.getProjectByPath(projectPath);
        if (!project) {
          console.error(chalk.red("Project not found. Run 'foreman init' first."));
          process.exit(1);
        }

        const groups = store.listGroupsByProject(project.id);
        if (groups.length === 0) {
          console.log(chalk.dim("No task groups found."));
          return;
        }

        console.log(chalk.bold(`Task Groups (${groups.length})`));
        console.log();
        for (const g of groups) {
          const members = store.getGroupMembers(g.id);
          const statusColor = g.status === "completed" ? chalk.green :
                              g.status === "failed" ? chalk.red : chalk.yellow;
          console.log(`  ${statusColor("●")} ${chalk.bold(g.name)} ${chalk.dim(`(${g.id})`)}`);
          console.log(`    Status: ${statusColor(g.status)}  Members: ${members.length}${g.parent_seed_id ? `  Parent: ${g.parent_seed_id}` : ""}`);
        }
      }
    } finally {
      store.close();
    }
  });

// ── group (parent command) ────────────────────────────────────────────────

export const groupCommand = new Command("group")
  .description("Manage task groups for batch coordination")
  .addCommand(groupCreateCommand)
  .addCommand(groupAddCommand)
  .addCommand(groupStatusCommand);
