// Shared by the two Herdr mods (the runs panel and the run-detail tab). install.sh copies this one
// file into each mod's folder, because a mod can only import modules from its own folder.
import { exec, home, window } from "herdr";

// Projection statuses: awaiting_worker, in_progress, paused, completed, failed, cancelled.
export const STATUS = {
  in_progress: { color: "working", label: "running", rank: 0 },
  awaiting_worker: { color: "idle", label: "starting", rank: 1 },
  paused: { color: "idle", label: "paused", rank: 2 },
  failed: { color: "blocked", label: "failed", rank: 3 },
  completed: { color: "done", label: "completed", rank: 4 },
  cancelled: { color: "dim", label: "cancelled", rank: 5 },
};
export const info = (s) => STATUS[s] ?? { color: "dim", label: s ?? "unknown", rank: 6 };
export const isActive = (r) => r.status === "in_progress" || r.status === "awaiting_worker";

export function ago(ms) {
  if (!ms) return "";
  const s = Math.max(0, Math.floor((Date.now() - ms) / 1000));
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h`;
  return `${Math.floor(s / 86400)}d`;
}

// Wall-clock HH:MM:SS.
export const clock = (ms) => {
  const d = new Date(ms);
  return [d.getHours(), d.getMinutes(), d.getSeconds()].map((n) => String(n).padStart(2, "0")).join(":");
};

// The server's /api needs FOREMAN_API_TOKEN once one is configured, and the app's environment
// does not carry it. Read it from the Foreman checkout's .env (only when the environment lacks
// it), inside the shell so the secret never lands in a process argument list. ops/herdr-sidebar/
// install.sh rewrites the next line to the path of the checkout it was run from.
const ENV_FILE = `${home()}/Development/Fortium/foreman/.env`;
const LOAD_TOKEN =
  'if [ -z "$FOREMAN_API_TOKEN" ]; then FOREMAN_API_TOKEN=$(sed -n "s/^FOREMAN_API_TOKEN=//p" "$1" 2>/dev/null); export FOREMAN_API_TOKEN; fi; shift;';
export const foremanArgv = (args) => ["sh", "-c", `${LOAD_TOKEN} exec foreman "$@"`, "sh", ENV_FILE, ...args];

// Runs `foreman <args>` and returns its parsed JSON, or throws the CLI's own error line.
export async function foreman(args) {
  const [cmd, ...rest] = foremanArgv(args);
  const r = await exec(cmd, rest, { timeout: 15000 });
  if (r.code !== 0) throw new Error(r.stderr.trim().replace(/^foreman:\s*/, "") || `foreman exited ${r.code}`);
  return JSON.parse(r.stdout);
}

// GET <server>/api/... as parsed JSON, for what the CLI does not offer (docs/cli-reference.md lists
// thread transcripts as HTTP/MCP only). The server is FOREMAN_API_URL, as for the CLI. The bearer
// token travels on a pipe into curl's header file (-H @-): never in an argument list. curl's -w puts
// the HTTP status on a last line of its own, so a caller can tell a server that has no such route (its
// own HTML or plain 404 page) from an answer.
const API_SCRIPT =
  `${LOAD_TOKEN} url="\${FOREMAN_API_URL:-http://127.0.0.1:4766}$1"; ` +
  'if [ -n "$FOREMAN_API_TOKEN" ]; then printf "Authorization: Bearer %s\\n" "$FOREMAN_API_TOKEN" | curl -sS --max-time 10 -w "\\n%{http_code}" -H @- "$url"; ' +
  'else curl -sS --max-time 10 -w "\\n%{http_code}" "$url"; fi';

// An Error that carries the HTTP status (null when there was none) and, for a JSON {error: code} body, the code.
// A body's `error` field is an error only on an HTTP error status: a 200 body may carry one as data (the
// artifact route answers {state: "missing", error: "<why>"} with 200).
const apiError = (message, status, code) => Object.assign(new Error(message), { status, code });

export async function api(path) {
  if (!/^\/api\/[A-Za-z0-9_.:\/?=&%-]+$/.test(path)) throw new Error(`refusing odd API path: ${path}`);
  const r = await exec("sh", ["-c", API_SCRIPT, "sh", ENV_FILE, path], { timeout: 15000 });
  if (r.code !== 0) throw new Error(r.stderr.trim().split("\n")[0] || `curl exited ${r.code}`);
  const route = path.split("?")[0];
  const cut = r.stdout.lastIndexOf("\n");
  if (cut < 0) throw apiError(`unexpected response from ${route}`, null);
  const status = Number(r.stdout.slice(cut + 1));
  let body;
  try { body = JSON.parse(r.stdout.slice(0, cut)); } catch { throw apiError(`unexpected response from ${route} (HTTP ${status})`, status); }
  const httpError = status >= 400;
  if (body?.error && (httpError || !Number.isFinite(status))) throw apiError(`${body.error}${body.detail ? `: ${body.detail}` : body.cause ? `: ${body.cause}` : ""}`, status, String(body.error));
  if (httpError) throw apiError(`HTTP ${status} from ${route}`, status);
  return body;
}

// The projection's top-level workflow_name can be null; the snapshot taken at run start has it.
export const workflowName = (r) => r.workflow_name ?? r.workflow_snapshot?.workflow_name ?? "run";
// The run's pull request URL when it has a usable (http/https) one, else null.
export const prUrl = (r) => (typeof r.pr_url === "string" && /^https?:\/\//.test(r.pr_url) ? r.pr_url : null);

// The command that opens a URL in the default browser on this platform.
export const openUrlArgv = (url) => {
  const platform = window()?.platform;
  return platform === "macos" ? ["open", [url]] : platform === "windows" ? ["cmd", ["/c", "start", "", url]] : ["xdg-open", [url]];
};
