import chalk from "chalk";
import { ProjectTargetingError, resolveProjectTarget } from "./project-targeting.js";

function emitProjectPathError(message: string, jsonOutput = false): never {
  if (jsonOutput) {
    console.error(JSON.stringify({ error: message }));
  } else {
    console.error(chalk.red(message));
  }
  process.exit(1);
}


/**
 * Resolve a CLI --project option into an absolute project path.
 *
 * Resolution order:
 * 1. no option → current working directory
 * 2. registered project name via ProjectRegistry.resolve()
 * 3. unregistered absolute path under --project → warn and use directly
 * 4. explicit --project-path absolute path → use directly
 * 5. invalid/unknown input → print a helpful error and exit
 */
export function resolveProjectPath(
  opts: { project?: string; projectPath?: string },
  jsonOutput = false,
): string {
  try {
    const result = resolveProjectTarget(opts);
    if (result.warning) {
      console.warn(chalk.yellow(result.warning));
    }
    return result.projectPath;
  } catch (err) {
    if (err instanceof ProjectTargetingError) {
      emitProjectPathError(err.message, jsonOutput);
    }

    throw err;
  }
}
