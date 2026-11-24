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

// Runs `foreman <args>` and returns what it printed, or throws the CLI's own error line. `timeout` (ms) is how long
// the CLI may run before it is killed; the default suits reads.
async function foremanText(args, timeout) {
  const [cmd, ...rest] = foremanArgv(args);
  const r = await exec(cmd, rest, { timeout });
  if (r.code !== 0) throw new Error(r.stderr.trim().replace(/^foreman:\s*/, "") || `foreman exited ${r.code}`);
  return r.stdout;
}

// Runs `foreman <args>` and returns its parsed JSON, or throws the CLI's own error line.
export async function foreman(args, timeout = 15000) {
  return JSON.parse(await foremanText(args, timeout));
}

// Runs a verb that changes the server. It worked when the CLI exited 0, whatever it printed: its JSON answer is not
// read, so an answer that cannot be parsed is never mistaken for a refusal of something the server did accept.
export async function foremanDo(args, timeout = 15000) {
  await foremanText(args, timeout);
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
// The same, for a JSON POST (the command boundary: POST /api/commands). The body travels as an argument: it carries ids
// and names, never a secret; the token still goes by pipe.
const POST_SCRIPT =
  `${LOAD_TOKEN} url="\${FOREMAN_API_URL:-http://127.0.0.1:4766}$1"; ` +
  'if [ -n "$FOREMAN_API_TOKEN" ]; then printf "Authorization: Bearer %s\\n" "$FOREMAN_API_TOKEN" | curl -sS --max-time 15 -X POST -H @- -H "Content-Type: application/json" --data "$2" -w "\\n%{http_code}" "$url"; ' +
  'else curl -sS --max-time 15 -X POST -H "Content-Type: application/json" --data "$2" -w "\\n%{http_code}" "$url"; fi';

// An Error that carries the HTTP status (null when there was none) and, for a JSON {error: code} body, the code.
// A body's `error` field is an error only on an HTTP error status: a 200 body may carry one as data (the
// artifact route answers {state: "missing", error: "<why>"} with 200).
const apiError = (message, status, code) => Object.assign(new Error(message), { status, code });

async function callApi(script, path, extraArgs, timeout) {
  if (!/^\/api\/[A-Za-z0-9_.:\/?=&%-]+$/.test(path)) throw new Error(`refusing odd API path: ${path}`);
  const r = await exec("sh", ["-c", script, "sh", ENV_FILE, path, ...extraArgs], { timeout });
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

export const api = (path) => callApi(API_SCRIPT, path, [], 15000);
export const apiPost = (path, body) => callApi(POST_SCRIPT, path, [JSON.stringify(body)], 20000);

// The projection's top-level workflow_name can be null; the snapshot taken at run start has it.
export const workflowName = (r) => r.workflow_name ?? r.workflow_snapshot?.workflow_name ?? "run";
// The run's pull request URL when it has a usable (http/https) one, else null.
export const prUrl = (r) => (typeof r.pr_url === "string" && /^https?:\/\//.test(r.pr_url) ? r.pr_url : null);
// The bead a run (or queued item) works on, for copying into `br show <id>`. A beads task's id is
// "beads:<project>:<bead id>" and the bead id may itself hold dots ("foreman-vbfmo.1"); anything else
// (coord-…, adhoc-…, another provider) is not a bead and gives null. Takes anything with a `task_id`.
export const beadId = (x) => {
  const m = /^beads:[^:]+:(.+)$/.exec(typeof x?.task_id === "string" ? x.task_id : "");
  return m ? m[1] : null;
};

// Clearing a run hides it from the runs panel and nothing else: the run, its events and its files are untouched
// (the plugin only reads). The panel keeps `cleared`, a plain object of run id -> the status the run had when it was
// cleared. Only finished runs that did not succeed can be cleared.
export const CLEARABLE = new Set(["failed", "stuck", "cancelled"]);
export const isClearable = (r) => CLEARABLE.has(r?.status);
// A cleared run stays hidden only while it still has the status it was cleared with: one that is retried, resumed
// or moves on (stuck -> failed) is news again and shows.
const isCleared = (cleared, r) => cleared[r.run_id] === r.status;
export const hideCleared = (runs, cleared) => runs.filter((r) => !isCleared(cleared, r));
export const countCleared = (runs, cleared) => runs.filter((r) => isCleared(cleared, r)).length;
// `cleared` plus these runs (the clearable ones among them); the input is not changed.
export const clearRuns = (cleared, runs) => {
  const next = { ...cleared };
  for (const r of runs) if (isClearable(r)) next[r.run_id] = r.status;
  return next;
};
// Entries for runs that are no longer listed are dropped, so the stored map cannot grow forever. An empty listing
// (a failed or racing read) drops nothing.
export const pruneCleared = (cleared, runs) => {
  if (runs.length === 0) return cleared;
  const listed = new Set(runs.map((r) => r.run_id));
  return Object.fromEntries(Object.entries(cleared).filter(([id]) => listed.has(id)));
};
// What localStorage held: only string-to-string entries of a JSON object count; anything else is no clearing.
export const parseCleared = (text) => {
  try {
    const o = JSON.parse(text ?? "{}");
    if (o === null || typeof o !== "object" || Array.isArray(o)) return {};
    return Object.fromEntries(Object.entries(o).filter(([, v]) => typeof v === "string"));
  } catch {
    return {};
  }
};

// Unlike clearing, a reset changes the server: `foreman run reset` (run.reset) drops the run's record from the run
// list; its event history stays and the work is not restarted (docs/user-guide.md, `run reset`). The server accepts
// a failed, stuck, blocked or paused run; the panel offers it on failed runs only.
export const isResettable = (r) => r?.status === "failed";
// The confirmation's wording: which run, and what a reset does and does not do.
export const resetPrompt = (r) => {
  const which = [workflowName(r), beadId(r) ?? r.task_id].filter(Boolean).join(" ");
  return {
    title: "Reset this run?",
    detail: `${which} (${r.run_id}). This removes the run's record from Foreman's run list; its event history stays. ` +
      "It does not restart the work: to try again, submit the work as a new run. Foreman has no command to bring a reset run back.",
  };
};

// Approving is the one action here that starts work: `task.approve` moves an open task to ready and the server then
// dispatches a run for it. `foreman task approve` was removed (TRD-018), so the panel sends the command itself, with the
// body that verb sent: task_id and approved_by. No command_id: the command controller mints a unique one per request
// (`default_command_id`, command_controller.ex), and the gateway makes it the approval_id and so the run_id. A fixed id
// would turn a later re-approval of the same task into an idempotent retry of the first and dispatch nothing. The
// gateway rejects an approval_id, approved_at, run_id or workflow_snapshot from a client. Only an `open` task is
// approvable (`Task.require_approvable/1`): the server refuses any other status.
export const isApprovable = (e) => e?.kind === "open" && e.stale !== true && typeof e.task_id === "string" && e.task_id !== "";
export const approveBody = (taskId) => ({ type: "task.approve", payload: { task_id: taskId, approved_by: "herdr-sidebar" } });
// The entry of the queue that is awaiting approval for this task. Not just the first entry of that task: a stale slot
// entry left over from an earlier run of the same task comes first in the queue and must not hide the open one.
export const findApprovable = (entries, taskId) => entries.find((x) => x.task_id === taskId && isApprovable(x));
// Sends the approval. It resolves only for an accepted command (HTTP 201 `{status: "accepted"}`); a refusal, a failed
// call or any other answer throws with what the server said, so the caller can never report success it did not get.
export async function approveTask(taskId) {
  const body = await apiPost("/api/commands", approveBody(taskId));
  if (body?.status !== "accepted") throw new Error(`unexpected answer: ${JSON.stringify(body).slice(0, 120)}`);
  return body;
}
// The confirmation's wording for a queue entry that is awaiting approval.
export const approvePrompt = (e) => {
  const which = [e.title, beadId(e) ?? e.task_id].filter(Boolean).join(" · ");
  return {
    title: "Approve this task?",
    detail: `${which}${e.project_id ? ` (project ${e.project_id})` : ""}. Approving it starts a run: an agent will work on the task ` +
      "(the run waits if the project is paused or at a limit). The server refuses if the task's dependencies are not all closed.",
  };
};

// The command that opens a URL in the default browser on this platform.
export const openUrlArgv = (url) => {
  const platform = window()?.platform;
  return platform === "macos" ? ["open", [url]] : platform === "windows" ? ["cmd", ["/c", "start", "", url]] : ["xdg-open", [url]];
};

// ------------------------------------------------------------------------------------ completion notifications
// The runs panel raises a Herdr notification when a run completes, and clicking it opens the run's detail tab on
// Activity. What is not Herdr (what counts as a completion, what the notification says, what its click delivers)
// lives here so that test/common.test.js can run it.

// A run in any other status is still going: in_progress, awaiting_worker, paused, and the stall detector's stuck / blocked.
const ENDED = new Set(["completed", "failed", "cancelled"]);

// One poll of the run list: the runs that completed since the poll before, and the state to give the next call (null
// before the first poll that worked). Pure: nothing it is given is changed.
//   - The first poll only records what is there. A run that is already completed is not news, and neither is one that
//     completed while the app was closed.
//   - A run is news when the poll before saw it in a status that is not an end status and it is now `completed`. A run
//     first seen already completed was not seen going, so it is not announced. failed and cancelled never are.
//   - A run is announced at most once (`notified`), however its status flaps between the sources the list is built from.
//   - An empty listing is a failed or racing read (as for pruneCleared): it changes nothing.
export function trackCompletions(state, runs) {
  if (state !== null && runs.length === 0) return { state, completed: [] };
  const seen = new Map();
  for (const r of runs) if (typeof r?.run_id === "string" && typeof r.status === "string") seen.set(r.run_id, r.status);
  if (state === null) return { state: { seen, notified: new Set() }, completed: [] };
  const notified = new Set(state.notified);
  const completed = [];
  for (const r of runs) {
    const before = state.seen.get(r?.run_id);
    if (r?.status === "completed" && before !== undefined && !ENDED.has(before) && !notified.has(r.run_id)) {
      completed.push(r);
      notified.add(r.run_id);
    }
  }
  return { state: { seen, notified }, completed };
}

// The notify() argument for a completed run. Herdr drops `args` when a notification (or a key) runs a mod command and
// delivers only "<command>[:<value>]" to the mod's nextCommand(), so the run id travels in the command's name. A toast
// lasts about 6 s unless told otherwise, too short to notice and click while looking elsewhere: this one stays 30 s.
const COMPLETION_TOAST_MS = 30000;
export const completionToast = (r) => ({
  title: "Foreman",
  body: `${workflowName(r)} ${beadId(r) ?? r.task_id ?? r.title ?? r.run_id} completed`,
  level: "success",
  timeout: COMPLETION_TOAST_MS,
  action: { name: `foreman-runs.open-run-activity:${r.run_id}` },
});

const RUN_ID = /^[A-Za-z0-9_.-]+$/;
// What the panel's command loop gets for `foreman-runs.open-run-activity:<run id>`: null when it is another command,
// else {runId}, runId being null when the id is missing or is not a run id.
export function parseActivityCommand(raw) {
  const m = /^(?:foreman-runs[.:])?open-run-activity(?::([\s\S]*))?$/.exec(String(raw ?? ""));
  if (!m) return null;
  return { runId: m[1] !== undefined && RUN_ID.test(m[1]) ? m[1] : null };
}

// ------------------------------------------------------------------------------------------------ merging a PR
// The run-detail tab can merge a run's pull request: two operator-only steps on the server, sent through the
// `foreman` verbs so that the CLI builds the command and prints the server's own refusal
// (packages/foreman_cli/cmd/foreman/run.go):
//   foreman run approve-merge --id <run> --approver <login> --identity github:<login> --head-sha <FULL sha> [--repo-id <id>]
//   foreman run merge --id <run> [--repo-id <id>]
// The server enforces the gate whatever this file decides: approve-merge re-reads the PR's head from GitHub and refuses
// any other commit than the one named, and merge squash-merges on GitHub only a head that was approved.

const FULL_SHA = /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/i;
const GH_LOGIN = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$/;
const REPO_ID = /^[a-z0-9][a-z0-9-]{0,31}$/; // a server repository id (Projects.RepoValidation)
export const isFullSha = (s) => typeof s === "string" && FULL_SHA.test(s);
export const shortSha = (s) => String(s ?? "").slice(0, 8);
const reasonCode = (x) => `${x?.code ?? "?"}${x?.subject ? ` (${x.subject})` : ""}`;

// Whether one PR may be merged with one click: {ok: true, step} or {ok: false, reason}. `p` is model.js's summary of
// the server's PR record (GET /api/runs/:id/prs, ForemanServer.PrWatch.DTO). `step` is what is left to do: "approve"
// (then merge) while the PR's merge gate is pending, "merge" once it is approved. Every condition has to hold:
//   - status is exactly "open" (the server's other values: conflicted, merged, closed),
//   - the head is a FULL commit SHA (an approval names the exact commit that was reviewed),
//   - eligibility.status is exactly "eligible". The server's values are off | eligible | ineligible | waived | unknown;
//     `off` (the project has no required checks) would need the explicit --acknowledge-gate-off, and `waived` is an
//     operator's override of evidence, so neither is one-click; a value this code does not know is not a pass either,
//   - no check is failing (the server's eligibility counts the required ones only),
//   - the merge gate is pending or approved. The server reports it only for the run's primary PR.
export function canMerge(p) {
  const no = (reason) => ({ ok: false, reason });
  if (!p) return no("the server has no pull request recorded for this run");
  if (p.status === "merged") return no("it is already merged");
  if (p.status === "closed") return no("it was closed without being merged");
  if (p.status === "conflicted") return no("it has merge conflicts");
  if (p.status !== "open") return no(p.status ? `its status is ${p.status}, not open` : "the server reported no status for it");
  if (!isFullSha(p.headSha)) return no("the server reported no full head commit SHA, and an approval names the exact commit reviewed");
  const status = p.eligibility?.status ?? "unknown";
  const reasons = (p.eligibility?.reasons ?? []).map(reasonCode).join("; ");
  if (status === "off") return no("the project has no required checks (merge gate off), so no CI evidence was checked; approving it anyway takes `foreman run approve-merge --acknowledge-gate-off`");
  if (status === "waived") return no(`its evidence is eligible only through an operator's waiver (${(p.eligibility.waived ?? []).map(reasonCode).join("; ") || "no codes listed"}); approve it deliberately with \`foreman run approve-merge\``);
  if (status === "ineligible") return no(`the server says it is not eligible: ${reasons || "no reason given"}`);
  if (status === "unknown") return no(`the server could not judge its evidence${reasons ? `: ${reasons}` : ""}`);
  if (status !== "eligible") return no(`its eligibility is ${status}, not eligible`);
  const failing = p.checks?.fail ?? 0;
  if (failing > 0) return no(`${failing} check${failing === 1 ? " is" : "s are"} failing (the server's eligibility counts the required checks only)`);
  if (p.gate === "approved") return { ok: true, step: "merge", reason: "" };
  if (p.gate === "pending") return { ok: true, step: "approve", reason: "" };
  return no(p.gate ? `its merge gate is ${p.gate}: there is no approval to give or use` : "the server reports no merge gate for it (it reports the gate of a run's primary PR only)");
}

const need = (ok, what) => {
  if (!ok) throw new Error(`refusing to build a merge command: ${what}`);
};
const str = (re, v) => typeof v === "string" && re.test(v);

// `foreman run approve-merge …` for one PR. The head SHA must be the FULL commit the operator was shown. There is no
// --acknowledge-gate-off: canMerge refuses a project whose gate is off, so this never sends it.
export function approveMergeArgs({ runId, login, headSha, repoId = null }) {
  need(str(RUN_ID, runId), "not a run id");
  need(str(GH_LOGIN, login), "not a GitHub login");
  need(isFullSha(headSha), "the head is not a full commit SHA");
  need(repoId === null || str(REPO_ID, repoId), "not a repository id");
  return ["run", "approve-merge", "--id", runId, "--approver", login, "--identity", `github:${login}`, "--head-sha", headSha, ...(repoId === null ? [] : ["--repo-id", repoId])];
}

// `foreman run merge …`: the server builds the whole merge from the approval, so only the run (and repository) is named.
export function mergeArgs({ runId, repoId = null }) {
  need(str(RUN_ID, runId), "not a run id");
  need(repoId === null || str(REPO_ID, repoId), "not a repository id");
  return ["run", "merge", "--id", runId, ...(repoId === null ? [] : ["--repo-id", repoId])];
}

// The operator's login, from `gh api user --jq .login` (a login and a newline). Anything else is no login.
export const parseGhLogin = (stdout) => {
  const s = String(stdout ?? "").trim();
  return GH_LOGIN.test(s) ? s : null;
};

// Herdr's confirmation dialog for the merge: which PR, which base and head, and that it cannot be taken back.
// `step` is canMerge's; `label` names the run; `login` is who approves.
export function mergePrompt(p, { step, login, label }) {
  const what = `${label ? `${label}: ` : ""}PR #${p.number ?? "?"} into ${p.base ?? "its base branch"}, head ${shortSha(p.headSha)}.`;
  const how = step === "merge"
    ? "It is already approved; this merges it: squash merge on GitHub; this cannot be undone."
    : `Approves it as github:${login}, then merges it: squash merge on GitHub; this cannot be undone.`;
  return { title: `Merge PR #${p.number ?? "?"}?`, detail: `${what} ${how}` };
}

// Whether the installed `foreman` has the two verbs, from the usage `foreman run --help` prints (it prints it to stderr
// and exits 1, and reads nothing from the server). {ok: true}, or {ok: false, reason} with the toast's text. An output
// that is not that usage at all says so rather than claiming the verbs are missing.
const MERGE_VERBS = ["approve-merge", "merge"];
export function mergeVerbsCheck(usage) {
  const text = String(usage ?? "");
  if (!/^\s*foreman run list(?=\s|$)/m.test(text)) return { ok: false, reason: "could not read the usage of the installed foreman (`foreman run --help`); nothing was sent" };
  const missing = MERGE_VERBS.filter((v) => !new RegExp(`^\\s*foreman run ${v}(?=\\s|$)`, "m").test(text));
  if (missing.length === 0) return { ok: true };
  return { ok: false, reason: `installed foreman lacks ${missing.map((v) => `\`run ${v}\``).join(" and ")}; update it` };
}

// A refusal of the server as the CLI prints it: "HTTP <status>: <JSON body>" with the body's `message`, `error` (what
// Elixir's inspect/1 made of the reason) or `code`. The server's text is always kept; the refusals this flow can meet
// get a plain-words explanation in front of it. Anything else (no server, a timeout) is shown as the CLI said it.
const MERGE_REFUSALS = [
  [/^:unauthorized_approver\b/, "the server does not accept this GitHub identity as a merge approver (its approver allowlist)"],
  [/^\{:head_sha_mismatch\b/, "the PR's head on GitHub is not the commit that was shown"],
  [/^\{:head_moved_since_approval\b/, "the PR's head moved after it was approved, which voids the approval"],
  [/^\{:evidence_ineligible\b/, "the server judged the PR's evidence not eligible"],
  [/^:merge_gate_already_approved\b/, "the merge gate is already approved"],
  [/^:pr_not_acceptable\b/, "the merge gate is not approved"],
];
export function mergeErrorText(text) {
  const line = String(text ?? "").split("\n")[0].trim();
  const m = /^HTTP (\d{3}): (.*)$/.exec(line);
  if (!m) return line || "the foreman command failed";
  let body = null;
  try {
    body = JSON.parse(m[2]);
  } catch {
    /* not JSON: shown as it is */
  }
  const said = [body?.message, body?.error, body?.code].find((v) => typeof v === "string" && v !== "") ?? m[2];
  const why = MERGE_REFUSALS.find(([re]) => re.test(said))?.[1];
  return why ? `${why} (${said})` : said;
}
