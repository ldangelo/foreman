import { execFile, execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
const execFileAsync = promisify(execFile);
const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const TSX_LOADER = join(__dirname, "..", "..", "node_modules", "tsx", "dist", "loader.mjs");
function buildEnv(extraEnv) {
    return Object.fromEntries(Object.entries({
        ...process.env,
        TSX_DISABLE_IPC: "1",
        NO_COLOR: "1",
        ...extraEnv,
    }).filter(([, value]) => value !== undefined));
}
export async function runTsxModule(modulePath, args, opts) {
    try {
        const { stdout, stderr } = await execFileAsync(process.execPath, ["--import", TSX_LOADER, modulePath, ...args], {
            cwd: opts.cwd,
            timeout: opts.timeout,
            env: buildEnv(opts.env),
        });
        return { stdout, stderr, exitCode: 0 };
    }
    catch (err) {
        return {
            stdout: err.stdout ?? "",
            stderr: err.stderr ?? "",
            exitCode: err.code ?? err.status ?? 1,
        };
    }
}
export function execTsxModuleSync(modulePath, args, opts) {
    return execFileSync(process.execPath, ["--import", TSX_LOADER, modulePath, ...args], {
        cwd: opts?.cwd,
        timeout: opts?.timeout,
        encoding: opts?.encoding ?? "utf-8",
        env: buildEnv(opts?.env),
    });
}
//# sourceMappingURL=tsx-subprocess.js.map