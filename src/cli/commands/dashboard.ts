import { Command } from "commander";
import chalk from "chalk";
import { execFile } from "node:child_process";
import { startServer } from "../../dashboard/server.js";

export const dashboardCommand = new Command("dashboard")
  .description("Launch the web dashboard")
  .option("--no-open", "Do not open the browser automatically")
  .action(async (opts) => {
    const url = "http://localhost:3850";
    console.log(chalk.bold(`Foreman Dashboard starting on ${url}`));

    const { close } = startServer();

    // Optionally open browser
    if (opts.open !== false) {
      try {
        const cmd =
          process.platform === "darwin"
            ? "open"
            : process.platform === "win32"
              ? "start"
              : "xdg-open";
        execFile(cmd, [url], () => {});
      } catch {
        // Non-fatal — user can navigate manually
      }
    }

    console.log(chalk.green("Dashboard is running. Press Ctrl+C to stop."));

    const shutdown = async () => {
      console.log(chalk.yellow("\nShutting down dashboard..."));
      await close();
      process.exit(0);
    };

    process.on("SIGINT", shutdown);
    process.on("SIGTERM", shutdown);

    // Keep process alive
    await new Promise(() => {});
  });
