// Foreman runs grouped by project, from `foreman run list` ({"runs": [...]}), and each project's queue
// (work waiting for a run slot, and open tasks awaiting approval). Click a run to open its detail tab;
// click a project, status or queue header to collapse it.
import { View, div } from "gpui-kit";
import { v_flex, h_flex, ScrollHandle } from "gpui-base";
import { theme, checking, run, focused, nextCommand, notify, keys, layout, shared, setShared, exec, window, openOverlay } from "herdr";
import { info, isActive, ago, clock, foreman, api, beadId, workflowName, runLabel, prUrl, openUrlArgv, isClearable, hideCleared, countCleared, clearRuns, pruneCleared, parseCleared, isResettable, resetPrompt, isApprovable, findApprovable, approveTask, approvePrompt, trackCompletions, completionToast, parseActivityCommand } from "./common.js";

const POLL_MS = 10000;
const RESET_CONFIRM_MS = 60000; // a confirmation answered later than this is ignored: the reset it was for is long forgotten
const APPROVE_CONFIRM_MS = 60000; // likewise for an approval: an answer later than this is ignored
const LIMIT = 40;
const PROJECT_RETRY_MS = 60000;
const HISTORY_LIMIT = 500; // each project's runs read for the history (the newest ones; the poll reads LIMIT overall)
const HISTORY_EVERY_MS = 60000; // the history changes slowly and costs far more than the poll: ~7 KB a run
const QUEUE_EVERY_MS = 30000; // the queue changes slowly and its lookups are heavier than the run list
const TERMINAL_RUN = new Set(["completed", "failed", "cancelled"]);

// The queue of every project, from per-project server reads. There is no machine-wide queue: run slots
// are per project, so `GET /api/queue` needs a `project_id` (422 `project_required` without one).
//   queues   one `GET /api/queue?project_id=<id>` per project:
//            {project_id, limit, running_runs, waiting_runs, running: [run_id],
//             waiting: [{run_id, position, waited_ms}]}; waiting is in that project's slot order (position is
//            1-based), runs the server admitted but has no free slot for yet.
//   open     GET /api/tasks?status=open: tasks not yet approved (no run); "ready" means approved and bound to a run.
//   resolved Map run_id -> {project_id, task_id, title, stale}: what each waiting run is for.
// A waiting id that resolves to nothing, or to a run that has already ended, is a leftover in the
// server's queue; it is kept (never hidden) but marked stale, and not counted as queued.
function buildQueue(queues, open, resolved) {
  const slot = queues.flatMap((q) => (q.waiting ?? []).map((w, i) => {
    const run_id = typeof w === "string" ? w : w.run_id;
    const r = resolved.get(run_id);
    return { kind: "slot", pos: w?.position ?? i + 1, run_id, project_id: r?.project_id ?? q.project_id ?? null, task_id: r?.task_id ?? null, title: r?.title ?? null, stale: !r || r.stale === true };
  }));
  const notStarted = open
    .filter((t) => t.run_id == null)
    .map((t) => ({ kind: "open", task_id: t.task_id, project_id: t.project_id ?? null, title: t.title ?? null, created: t.created_at_ms ?? 0, stale: false }))
    .sort((a, b) => a.created - b.created);
  return [...slot, ...notStarted];
}

// The sidebar is narrowed to a rail by its width, not a flag (dragging its edge narrows it too),
// the same test the shipped agents mod uses. The hint footer would stack one hint per line there.
const findNode = (node, id) => {
  if (node?.id === id) return node;
  for (const child of node?.children ?? []) {
    const found = findNode(child, id);
    if (found) return found;
  }
  return null;
};
const narrow = () => (findNode(layout(), "sidebar")?.size?.px ?? Infinity) < 160;

// Shortcut hints shown under the list: [mod command, label]. The chord shown is whatever keys.json
// actually binds to it, so a hint can never name a key that does nothing; unbound commands are skipped.
const HINTS = [
  ["focus-panel", "select"],
  ["open-pr", "open PR"],
  ["copy-id", "copy id"],
  ["copy-bead", "copy bead"],
  ["copy-pr", "copy PR"],
  ["clear-run", "clear"],
  ["clear-all", "clear all"],
  ["reset-run", "reset"],
  ["approve-next", "approve"],
  ["restore-cleared", "restore"],
  ["toggle-failed", "failed only"],
  ["refresh", "reload"],
  ["toggle-all", "fold projects"],
  ["toggle-statuses", "fold status"],
  ["toggle-sidebar", "rail"],
];

// "cmd-shift-j" -> "⇧⌘J" (macOS) or "Ctrl+Shift+J", same spelling as the shipped status bar.
const chordFor = (action) => {
  const b = keys().find((k) => (k.section === "layout:foreman" || k.section === "global") && k.action === action);
  if (!b) return null;
  const mac = window()?.platform === "macos";
  const mod = { cmd: mac ? "⌘" : "Ctrl+", ctrl: mac ? "⌃" : "Ctrl+", shift: mac ? "⇧" : "Shift+", alt: mac ? "⌥" : "Alt+", option: mac ? "⌥" : "Alt+" };
  const parts = b.keys.endsWith("--") ? [...b.keys.slice(0, -2).split("-"), "-"] : b.keys.split("-");
  const order = ["ctrl", "alt", "option", "shift", "cmd"]; // macOS convention: ⌃⌥⇧⌘
  const mods = parts.slice(0, -1).sort((x, y) => order.indexOf(x.toLowerCase()) - order.indexOf(y.toLowerCase()));
  return [...mods, parts[parts.length - 1]].map((p) => mod[p.toLowerCase()] ?? p.toUpperCase()).join("");
};

export default class ForemanRuns extends View {
  init(_props, cx) {
    this.runs = [];
    this.projectNames = new Map(); // project_id -> display name
    this.projectsTriedAt = 0;
    // Collapsed headers, kept across restarts (localStorage is a file; per mod copy). Keys are
    // project ids and "<project>::<status>" for a status group inside a project.
    try { this.collapsed = new Set(JSON.parse(localStorage.getItem("collapsed") ?? "[]")); } catch { this.collapsed = new Set(); }
    // Runs cleared from the panel (run id -> the status it had when cleared): view state only, kept across restarts.
    try { this.cleared = parseCleared(localStorage.getItem("cleared")); } catch { this.cleared = {}; }
    this.allRuns = []; // the listing as the server gave it, cleared runs included (this.runs is it without them)
    this.completions = null; // trackCompletions' state: null until the first poll that worked (see announceCompletions)
    this.pendingReset = null; // {run_id, at}: the run Herdr's confirm dialog is asking about
    this.resetBusy = false;
    this.pendingApprove = null; // {task_id, at}: the task Herdr's confirm dialog is asking about
    this.approveBusy = false;
    this.error = null;
    this.loaded = false;
    this.busy = false;
    this.refreshing = false; // a manual refresh is in flight (drives the button's tint)
    this.onlyFailed = false; // header filter: show only failed runs (not persisted)
    this.handle = cx.focus_handle(); // lets the panel receive keys (Escape, arrows, Enter)
    this.returnTo = null; // pane/terminal that had the keyboard before the panel took it
    this.cursor = null; // run_id selected for keyboard navigation
    this.scroll = ScrollHandle.new(); // brings the selected row into view
    this.updatedAt = 0; // ms of the last successful refresh
    this.queue = { capacity: null, running: 0, entries: [] }; // see buildQueue()
    this.queueAt = 0; // ms of the last queue read (the poll reads it every QUEUE_EVERY_MS)
    this.queueError = null; // the last queue read failed: the runs still show, the queue says why it is missing
    this.projectIdList = []; // registered project ids (see projectIds())
    this.projectIdsAt = 0;
    this.projectIdsError = null;
    this.runsNote = null; // some run list could not be read: the panel may be missing runs, and says why
    this.history = new Map(); // project id -> its runs as last read (see loadRuns())
    this.historyAt = new Map(); // project id -> ms of the last attempt to read its history, whether it worked or not
    this.historyProblems = new Map(); // project id -> why its history could not be read
    cx.timer.every(POLL_MS, (cx) => this.refresh(cx));
    this.refresh(cx);
    // Key commands from keys.json ("<mod>.<command>"): "foreman-runs.toggle-failed" flips the
    // failed filter, "foreman-runs.refresh" reloads now, "foreman-runs.focus-panel" moves the keyboard
    // here for arrow-key navigation. "foreman-runs.open-run-activity:<run id>" (what a completion notification runs when
    // clicked: Herdr delivers a mod command's name and nothing else, so the id rides in it) opens that run's detail tab
    // on Activity. Anything else is ignored.
    if (!checking()) {
      cx.spawn(async (cx) => {
        for (;;) {
          const raw = String(await nextCommand());
          const command = raw.split(/[.:]/).pop();
          const activity = parseActivityCommand(raw);
          if (activity) this.openRunActivity(activity.runId);
          else if (command === "toggle-failed") this.toggleFailedFilter(cx);
          else if (command === "refresh") this.refresh(cx, true);
          else if (command === "toggle-all") this.toggleAllProjects(cx);
          else if (command === "toggle-statuses") this.toggleAllStatuses(cx);
          else if (command === "focus-panel") this.focusPanel(cx);
          else if (command === "open-pr") this.openPr();
          else if (command === "copy-id") this.copyRunId(cx);
          else if (command === "copy-bead") this.copyBead(cx);
          else if (command === "clear-run") this.clearSelected(cx);
          else if (command === "clear-all") this.clearAll(cx);
          else if (command === "restore-cleared") this.restoreCleared(cx);
          else if (command === "reset-run") this.askResetSelected();
          else if (command === "reset-confirmed") this.confirmReset(cx);
          else if (command === "approve-next") this.askApproveNext();
          else if (command === "approve-confirmed") this.confirmApprove(cx);
          else if (command === "copy-pr") this.copyPrUrl(cx);
          else if (command === "toggle-sidebar") this.toggleSidebar();
          // A bare "focus" is the app's own message (e.g. a popup closed over this copy): keep
          // the keyboard only if the panel was already in use, never start navigating from it.
          else if (command === "focus" && (this.returnTo || this.onlyFailed || this.cursor)) this.handle.focus();
        }
      });
    }
  }

  // Project names come from `foreman project list`, asked only when a run names a project
  // not seen yet (at most once a minute). Without a name a group is headed by its project id.
  async loadProjects() {
    const unknown = [...this.runs, ...this.queue.entries].some((r) => r.project_id && !this.projectNames.has(r.project_id));
    if (!unknown || Date.now() - this.projectsTriedAt < PROJECT_RETRY_MS) return;
    this.projectsTriedAt = Date.now();
    try {
      const body = await foreman(["project", "list", "--format=json"]);
      for (const p of Array.isArray(body) ? body : (body?.projects ?? [])) {
        const id = p.project_id ?? p.id;
        if (id) this.projectNames.set(id, p.name || id);
      }
    } catch {
      // Names are decoration: the groups still show, headed by project id.
    }
  }

  // Reads the queue. Its own try/catch: a queue problem must never take the run list down with it.
  async loadQueue(force) {
    if (!force && Date.now() - this.queueAt < QUEUE_EVERY_MS) return;
    this.queueAt = Date.now();
    try {
      // One read per project: the server has no un-scoped queue. A project whose read fails (deleted
      // since the list, a hiccup) is skipped and named in the note, so the others still show.
      const body = await foreman(["project", "list", "--format=json"]);
      const projects = (Array.isArray(body) ? body : (body?.projects ?? [])).map((p) => ({ id: p.project_id ?? p.id, name: p.name })).filter((p) => p.id);
      for (const p of projects) if (p.name) this.projectNames.set(p.id, p.name);
      const queues = [];
      const failed = [];
      await Promise.all(projects.map(async (p) => {
        try {
          queues.push(await api(`/api/queue?project_id=${encodeURIComponent(p.id)}`));
        } catch (e) {
          failed.push(`${p.id}: ${String(e?.message ?? e).split("\n")[0]}`);
        }
      }));
      if (projects.length > 0 && queues.length === 0) throw new Error(failed[0]);
      // Slot order is per project; keep the projects in the order the server listed them.
      const order = new Map(projects.map((p, i) => [p.id, i]));
      queues.sort((a, b) => (order.get(a.project_id) ?? 0) - (order.get(b.project_id) ?? 0));
      const open = (await api("/api/tasks?status=open")).tasks ?? [];
      const waiting = queues.flatMap((q) => (q.waiting ?? []).map((w) => (typeof w === "string" ? w : w.run_id)));
      const resolved = new Map();
      if (waiting.length > 0) {
        // A waiting run belongs to a task that is in progress: its run_id names it.
        const want = new Set(waiting);
        for (const t of (await api("/api/tasks?status=in_progress")).tasks ?? []) {
          if (t.run_id && want.has(t.run_id)) resolved.set(t.run_id, { project_id: t.project_id, task_id: t.task_id, title: t.title, stale: false });
        }
        // The rest are looked up one by one (rare): an ended run is a stale entry, an unknown one stays unresolved.
        await Promise.all(waiting.filter((id) => !resolved.has(id)).map(async (id) => {
          try {
            const r = (await api(`/api/runs/${id}`)).run;
            resolved.set(id, { project_id: r.project_id, task_id: r.task_id, title: null, stale: TERMINAL_RUN.has(r.status) });
          } catch { /* stays unresolved: shown as stale, with its run id */ }
        }));
      }
      const sum = (key) => queues.reduce((n, q) => n + (q[key] ?? 0), 0);
      // Totals across the projects queried: total concurrency is the sum of per-project limits.
      this.queue = { capacity: queues.length > 0 ? sum("limit") : null, running: sum("running_runs"), entries: buildQueue(queues, open, resolved) };
      this.queueError = failed.length > 0 ? `${failed.length} project queue(s) unreadable (${failed[0]})` : null;
    } catch (e) {
      this.queueError = String(e?.message ?? e).split("\n")[0];
    }
  }

  // The runs to show. Every poll reads the LIMIT newest overall: whatever just happened (a run that fails, is retried or
  // finishes gets a new last event, so it is among them). A project's history, up to HISTORY_LIMIT of its runs
  // (`--project-id`), is read when it is a minute old or on a manual refresh: the older runs the overall list never
  // reaches. A busy project crowds a quiet one out of the overall list (ensemble showed 3 of its 50 runs), and a window
  // would undercount `N failed`. Each project is timed on its own, a failed read included, so one project that keeps
  // failing cannot make the others (about 1 MB) be read on every poll. For a run in both, the recent read wins. A list
  // that cannot be read is named in `runsNote`, so a partial panel is never presented as the whole picture; that
  // project keeps its previous history until a read works.
  async loadRuns(force) {
    const overall = await foreman(["run", "list", "-limit", String(LIMIT)]);
    if (!Array.isArray(overall?.runs)) throw new Error("unexpected output from foreman run list");
    const ids = await this.projectIds();
    const now = Date.now();
    await Promise.all(ids.filter((id) => force || now - (this.historyAt.get(id) ?? 0) >= HISTORY_EVERY_MS).map(async (id) => {
      this.historyAt.set(id, now);
      try {
        const body = await foreman(["run", "list", "--project-id", id, "-limit", String(HISTORY_LIMIT)]);
        if (!Array.isArray(body?.runs)) throw new Error("unexpected output from foreman run list");
        this.history.set(id, body.runs);
        this.historyProblems.delete(id);
      } catch (e) {
        this.historyProblems.set(id, `${id}: ${String(e?.message ?? e).split("\n")[0]}`);
      }
    }));
    const byId = new Map();
    for (const id of ids) for (const r of this.history.get(id) ?? []) byId.set(r.run_id, r);
    for (const r of overall.runs) byId.set(r.run_id, r);
    this.runsNote = [...this.historyProblems.values()][0] ?? (this.projectIdsError ? `project list: ${this.projectIdsError}` : null);
    return [...byId.values()];
  }

  // The registered projects' ids (it also fills the names), asked at most once a minute while it works; the last good
  // list stands when the ask fails, and the failure is kept for loadRuns to report.
  async projectIds() {
    if (this.projectIdList.length > 0 && Date.now() - this.projectIdsAt < PROJECT_RETRY_MS) return this.projectIdList;
    this.projectIdsAt = Date.now();
    try {
      const body = await foreman(["project", "list", "--format=json"]);
      const projects = (Array.isArray(body) ? body : (body?.projects ?? [])).map((p) => ({ id: p.project_id ?? p.id, name: p.name })).filter((p) => p.id);
      for (const p of projects) if (p.name) this.projectNames.set(p.id, p.name);
      this.projectIdList = projects.map((p) => p.id);
      this.projectIdsError = null;
    } catch (e) {
      this.projectIdsError = String(e?.message ?? e).split("\n")[0];
    }
    return this.projectIdList;
  }

  refresh(cx, manual = false) {
    if (this.busy || checking()) return;
    this.busy = true;
    if (manual) {
      this.refreshing = true;
      cx.notify(); // show the button as busy right away
    }
    cx.spawn(async (cx) => {
      try {
        this.setRuns(await this.loadRuns(manual));
        this.announceCompletions();
        this.error = null;
        this.updatedAt = Date.now();
        await this.loadProjects();
        await this.loadQueue(manual);
      } catch (e) {
        this.error = String(e?.message ?? e).split("\n")[0];
      } finally {
        this.busy = false;
        this.refreshing = false;
        this.loaded = true;
        cx.notify();
      }
    });
  }

  saveCollapsed() {
    try {
      localStorage.setItem("collapsed", JSON.stringify([...this.collapsed]));
      // The write goes to a background thread; flush so a quit right after a toggle keeps it.
      localStorage.flush().catch(() => {});
    } catch { /* in-memory state still toggles */ }
  }

  saveCleared() {
    try {
      localStorage.setItem("cleared", JSON.stringify(this.cleared));
      localStorage.flush().catch(() => {});
    } catch { /* the clearing still applies until the panel restarts */ }
  }

  // The runs the panel works on: the listing without the cleared ones. Counts, groups, the failed filter and the
  // keyboard cursor all read this.runs, so a cleared run is simply not there.
  setRuns(all) {
    this.allRuns = all;
    const kept = pruneCleared(this.cleared, all);
    if (Object.keys(kept).length !== Object.keys(this.cleared).length) {
      this.cleared = kept;
      this.saveCleared();
    }
    this.runs = hideCleared(all, this.cleared);
  }

  // Hides these runs (the failed, stuck or cancelled ones among them) from the panel. Nothing is deleted or changed
  // on the server; "↺ N cleared" under the list brings them back.
  clear(rs, cx) {
    const n = rs.filter(isClearable).length;
    if (n === 0) return notify({ title: "Foreman", body: "Only failed, stuck or cancelled runs can be cleared.", level: "info" });
    this.cleared = clearRuns(this.cleared, rs);
    this.saveCleared();
    this.runs = hideCleared(this.allRuns, this.cleared);
    if (this.cursor && !this.runs.some((r) => r.run_id === this.cursor)) this.cursor = null;
    notify({ title: "Foreman", body: `Cleared ${n} run${n === 1 ? "" : "s"} from the panel (nothing was deleted); ↺ under the list restores them.`, level: "success", timeout: 3000 });
    cx.notify();
  }

  // Clears the selected run and moves the selection to its neighbour, so the keyboard can clear a list in a row.
  clearSelected(cx) {
    const shown = this.visibleRuns();
    const at = shown.findIndex((x) => x.run_id === this.cursor);
    if (at < 0) return notify({ title: "Foreman", body: "Select a run first (focus the panel, then ↑/↓).", level: "info" });
    if (!isClearable(shown[at])) return this.clear([shown[at]], cx);
    this.clear([shown[at]], cx);
    const rest = this.visibleRuns();
    this.cursor = rest.length === 0 ? null : rest[Math.min(at, rest.length - 1)].run_id;
    cx.notify();
  }

  // Clears every failed, stuck or cancelled run the panel shows (with the failed filter on, the failed ones).
  clearAll(cx) {
    this.clear(this.shownRuns().filter(isClearable), cx);
  }

  restoreCleared(cx) {
    const n = countCleared(this.allRuns, this.cleared);
    if (n === 0) return notify({ title: "Foreman", body: "No cleared runs to restore.", level: "info" });
    this.cleared = {};
    this.saveCleared();
    this.runs = hideCleared(this.allRuns, this.cleared);
    notify({ title: "Foreman", body: `Restored ${n} cleared run${n === 1 ? "" : "s"}.`, level: "success", timeout: 2000 });
    cx.notify();
  }

  // Resetting changes the server (`foreman run reset`), so it asks first: Herdr's own confirm dialog (Enter confirms,
  // Esc cancels). Confirming sends "foreman-runs.reset-confirmed" back to this panel, which resets the run asked about.
  askReset(r) {
    if (!isResettable(r)) return notify({ title: "Foreman", body: `Only a failed run can be reset here; ${workflowName(r)} ${r.task_id ?? r.run_id} is ${r.status}.`, level: "info" });
    this.pendingReset = { run_id: r.run_id, at: Date.now() };
    const { title, detail } = resetPrompt(r);
    openOverlay({ mod: "confirm", kind: "dialog", modal: true, width: 460, height: 230, props: { title, detail, command: { name: "foreman-runs.reset-confirmed", args: {} } } });
  }

  askResetSelected() {
    const r = this.runs.find((x) => x.run_id === this.cursor);
    if (!r) return notify({ title: "Foreman", body: "Select a run first (focus the panel, then ↑/↓).", level: "info" });
    this.askReset(r);
  }

  async confirmReset(cx) {
    const p = this.pendingReset;
    this.pendingReset = null;
    if (!p || Date.now() - p.at > RESET_CONFIRM_MS) return notify({ title: "Foreman", body: "No reset is waiting for a confirmation.", level: "info" });
    const r = this.allRuns.find((x) => x.run_id === p.run_id);
    if (!r || !isResettable(r)) return notify({ title: "Foreman", body: `${p.run_id} is no longer a failed run: nothing was reset.`, level: "info" });
    if (this.resetBusy) return;
    this.resetBusy = true;
    const label = `${workflowName(r)} ${r.task_id ?? r.run_id}`;
    try {
      await foreman(["run", "reset", "--id", p.run_id]);
      notify({ title: "Foreman", body: `Reset ${label}: removed from the run list; the work was not restarted.`, level: "success", timeout: 5000 });
    } catch (e) {
      notify({ title: "Foreman", body: `Could not reset ${label}: ${String(e?.message ?? e).split("\n")[0]}`, level: "error" });
    } finally {
      this.resetBusy = false;
    }
    this.refresh(cx, true);
  }

  // Approving starts a run, so it asks first, like reset: Herdr's confirm dialog (Enter confirms, Esc cancels).
  // Confirming sends "foreman-runs.approve-confirmed" back to this panel, which approves the task asked about.
  askApprove(e) {
    if (!isApprovable(e)) return notify({ title: "Foreman", body: "That task is not waiting for approval.", level: "info" });
    this.pendingApprove = { task_id: e.task_id, at: Date.now() };
    const { title, detail } = approvePrompt(e);
    openOverlay({ mod: "confirm", kind: "dialog", modal: true, width: 460, height: 230, props: { title, detail, command: { name: "foreman-runs.approve-confirmed", args: {} } } });
  }

  // The keyboard way in: the task that has waited longest (the queue lists them oldest first).
  askApproveNext() {
    const e = this.queue.entries.find(isApprovable);
    if (!e) return notify({ title: "Foreman", body: "No task is waiting for approval.", level: "info" });
    this.askApprove(e);
  }

  async confirmApprove(cx) {
    const p = this.pendingApprove;
    this.pendingApprove = null;
    if (!p || Date.now() - p.at > APPROVE_CONFIRM_MS) return notify({ title: "Foreman", body: "No approval is waiting for a confirmation.", level: "info" });
    const e = findApprovable(this.queue.entries, p.task_id);
    if (!e) return notify({ title: "Foreman", body: `${p.task_id} is no longer waiting for approval: nothing was approved.`, level: "info" });
    if (this.approveBusy) return;
    this.approveBusy = true;
    const label = e.title ?? beadId(e) ?? e.task_id;
    try {
      await approveTask(p.task_id);
      notify({ title: "Foreman", body: `Approved ${label}: the server is dispatching a run for it.`, level: "success", timeout: 5000 });
    } catch (err) {
      notify({ title: "Foreman", body: `Could not approve ${label}: ${String(err?.message ?? err).split("\n")[0]}`, level: "error" });
    } finally {
      this.approveBusy = false;
    }
    this.refresh(cx, true);
  }

  toggle(id, cx) {
    if (!this.collapsed.delete(id)) this.collapsed.add(id);
    this.saveCollapsed();
    cx.notify();
  }

  // Collapses every project group, or expands them all when none is expanded. Status groups
  // inside a project keep their own state.
  toggleAllProjects(cx) {
    const ids = new Set(this.runs.map((r) => r.project_id ?? ""));
    const anyOpen = [...ids].some((id) => !this.collapsed.has(id));
    for (const id of ids) {
      if (anyOpen) this.collapsed.add(id);
      else this.collapsed.delete(id);
    }
    this.saveCollapsed();
    cx.notify();
  }

  // Collapses every status group (in every project), or expands them all when every one is
  // already collapsed. Project groups keep their own state.
  toggleAllStatuses(cx) {
    const keys = new Set(this.runs.map((r) => `${r.project_id ?? ""}::${r.status}`));
    const anyOpen = [...keys].some((k) => !this.collapsed.has(k));
    for (const k of keys) {
      if (anyOpen) this.collapsed.add(k);
      else this.collapsed.delete(k);
    }
    this.saveCollapsed();
    cx.notify();
  }

  // Opens the run-detail tab (the foreman-run mod): phases, live activity, changes, PR and anything
  // waiting on the operator. It looks the run up itself, so it only needs the id. `tab` is the view it starts on
  // (overview, activity, phases, changes or pr); without it the run's state decides.
  open(r, tab = null) {
    // The tab is named after the bead when there is one: the id is the end of the task id, which a cut-off name loses.
    const short = beadId(r) ?? String(r.task_id ?? r.run_id).slice(0, 24);
    run("tab.new", { name: `${workflowName(r)} ${short}`, mod: "foreman-run", props: tab ? { run_id: r.run_id, tab } : { run_id: r.run_id } });
  }

  // Opens a run on its Activity view: what a completion notification's click runs. The run is looked up for the tab's
  // name; one that has left the listing still opens, named by its id.
  openRunActivity(runId) {
    if (runId === null) return notify({ title: "Foreman", body: "open-run-activity needs a run id: foreman-runs.open-run-activity:<run id>", level: "info" });
    this.open(this.allRuns.find((x) => x.run_id === runId) ?? { run_id: runId }, "activity");
  }

  // A Herdr notification for each run that went from running (or queued, or paused) to completed since the poll before
  // (trackCompletions): the first poll that works only records what is there, and a run is announced once. Clicking it
  // opens the run on Activity. This panel posts it, so notifications come while the panel is loaded (the foreman
  // layout is showing), whether or not its sidebar is folded.
  announceCompletions() {
    const { state, completed } = trackCompletions(this.completions, this.allRuns);
    this.completions = state;
    for (const r of completed) notify(completionToast(r));
  }

  // Runs the panel lists: all of them, or only the failed ones while the header filter is on.
  shownRuns() {
    return this.onlyFailed ? this.runs.filter((r) => r.status === "failed") : this.runs;
  }

  // Takes the keyboard for this panel, remembering where it was so leaving can give it back.
  takeKeyboard() {
    if (!this.returnTo) {
      const f = focused();
      this.returnTo = f?.pane ? { pane: f.pane } : f?.terminal ? { terminal: f.terminal } : null;
    }
    this.handle.focus();
  }

  // Leaves the panel: drops the filter and selection and (unless a new tab took the keyboard
  // already) hands the keyboard back.
  leave(cx, restoreFocus = true) {
    this.onlyFailed = false;
    this.cursor = null;
    if (restoreFocus && this.returnTo) run("pane.focus", this.returnTo);
    this.returnTo = null;
    cx.notify();
  }

  // Turning the filter on takes the keyboard so Escape reaches this panel; turning it off
  // leaves the panel again.
  toggleFailedFilter(cx) {
    if (this.onlyFailed) return this.leave(cx);
    this.onlyFailed = true;
    this.takeKeyboard();
    cx.notify();
  }

  // Keyboard entry point: select the first visible run (or keep the current one) and listen
  // for Up/Down/Enter/Escape.
  focusPanel(cx) {
    this.takeKeyboard();
    if (!this.visibleRuns().some((r) => r.run_id === this.cursor)) this.moveCursor(1, cx);
    else cx.notify();
  }

  visibleRuns() {
    return this.items().filter((it) => it.kind === "run").map((it) => it.r);
  }

  moveCursor(delta, cx) {
    const items = this.items();
    const runs = items.filter((it) => it.kind === "run").map((it) => it.r);
    if (runs.length === 0) return cx.notify();
    const at = runs.findIndex((r) => r.run_id === this.cursor);
    const next = at < 0 ? (delta > 0 ? 0 : runs.length - 1) : Math.min(runs.length - 1, Math.max(0, at + delta));
    this.cursor = runs[next].run_id;
    this.scroll.scroll_to_item(items.findIndex((it) => it.kind === "run" && it.r.run_id === this.cursor));
    cx.notify();
  }

  openCursor(cx) {
    const r = this.runs.find((x) => x.run_id === this.cursor);
    if (!r) return;
    this.open(r);
    this.leave(cx, false); // the new tab has the keyboard now
  }

  // Opens the selected run's pull request (its `pr_url`) in the default browser. Only http(s)
  // URLs are opened; the URL is passed as an argument, never through a shell.
  async openPr() {
    const r = this.runs.find((x) => x.run_id === this.cursor);
    const name = r ? `${workflowName(r)} ${r.task_id ?? r.run_id}` : "";
    if (!r) return notify({ title: "Foreman", body: "Select a run first (focus the panel, then ↑/↓).", level: "info" });
    const url = prUrl(r);
    if (!url) return notify({ title: "Foreman", body: `${name} has no pull request.`, level: "info" });
    try {
      const res = await exec(...openUrlArgv(url), { timeout: 10000 });
      if (res.code !== 0) throw new Error(res.stderr.trim() || `exit ${res.code}`);
    } catch (e) {
      notify({ title: "Foreman", body: `Could not open ${url}: ${String(e?.message ?? e).split("\n")[0]}`, level: "error" });
    }
  }

  // Copies the selected run's id to the system clipboard.
  copyRunId(cx) {
    const r = this.runs.find((x) => x.run_id === this.cursor);
    if (!r) return notify({ title: "Foreman", body: "Select a run first (focus the panel, then ↑/↓).", level: "info" });
    cx.write_to_clipboard(r.run_id);
    notify({ title: "Foreman", body: `Copied ${r.run_id}`, level: "success", timeout: 2000 });
  }

  copyText(text, what, cx) {
    cx.write_to_clipboard(text);
    notify({ title: "Foreman", body: `Copied ${what}`, level: "success", timeout: 2000 });
  }

  // Copies the selected run's bead id (the part of its task id after "beads:<project>:").
  copyBead(cx) {
    const r = this.runs.find((x) => x.run_id === this.cursor);
    if (!r) return notify({ title: "Foreman", body: "Select a run first (focus the panel, then ↑/↓).", level: "info" });
    const b = beadId(r);
    if (!b) return notify({ title: "Foreman", body: `${workflowName(r)} ${r.task_id ?? r.run_id} is not a bead.`, level: "info" });
    this.copyText(b, `bead id ${b}`, cx);
  }

  // Copies the selected run's pull request URL to the system clipboard.
  copyPrUrl(cx) {
    const r = this.runs.find((x) => x.run_id === this.cursor);
    if (!r) return notify({ title: "Foreman", body: "Select a run first (focus the panel, then ↑/↓).", level: "info" });
    const url = prUrl(r);
    if (!url) return notify({ title: "Foreman", body: `${workflowName(r)} ${r.task_id ?? r.run_id} has no pull request.`, level: "info" });
    cx.write_to_clipboard(url);
    notify({ title: "Foreman", body: `Copied ${url}`, level: "success", timeout: 2000 });
  }

  key(e, cx) {
    // Only react while the panel is in use, so an Escape meant for something else passes on.
    if (!(this.returnTo || this.onlyFailed || this.cursor)) return;
    if (e.key === "escape") this.leave(cx);
    else if (e.key === "down") this.moveCursor(1, cx);
    else if (e.key === "up") this.moveCursor(-1, cx);
    else if (e.key === "enter") this.openCursor(cx);
    else if (e.key === "backspace" || e.key === "delete") this.clearSelected(cx);
    else return;
    cx.stop_propagation();
  }

  // The queue entries that are not already listed as runs. A run the server resumed after a pause waits
  // for a slot with its run record, so it is in GET /api/runs (shown under its status) and in the slot
  // queue at once; a queued run that was never started has no run record and is shown only here.
  queuedEntries() {
    const listed = new Set(this.runs.map((r) => r.run_id));
    return this.queue.entries.filter((e) => !(e.run_id && listed.has(e.run_id)));
  }

  groups(applyFilter = true) {
    // Counters (header and per project) always describe ALL runs; only the listed rows are
    // filtered. `all` feeds the counters, `runs` is what the project lists.
    const byProject = new Map();
    for (const r of this.runs) {
      const key = r.project_id ?? "";
      if (!byProject.has(key)) byProject.set(key, { all: [], queued: [] });
      byProject.get(key).all.push(r);
    }
    // A project with queued work but no run yet still gets a group.
    for (const e of this.queuedEntries()) {
      const key = e.project_id ?? "";
      if (!byProject.has(key)) byProject.set(key, { all: [], queued: [] });
      byProject.get(key).queued.push(e);
    }
    const latest = (rs) => (rs.length > 0 ? Math.max(...rs.map((r) => r.last_event_at_ms ?? 0)) : 0);
    const byRank = (a, b) => info(a.status).rank - info(b.status).rank || (b.last_event_at_ms ?? 0) - (a.last_event_at_ms ?? 0);
    const filtering = applyFilter && this.onlyFailed;
    return [...byProject.entries()]
      .map(([id, { all, queued }]) => ({
        id,
        name: id ? (this.projectNames.get(id) ?? id) : all.length === 0 ? "Unresolved queue entries" : "No project",
        all,
        queued,
        runs: (filtering ? all.filter((r) => r.status === "failed") : all).sort(byRank),
      }))
      // The failed filter shows failed runs only, so it hides queue-only projects too.
      .filter((g) => g.runs.length > 0 || (!filtering && g.queued.length > 0))
      .sort((a, b) => Number(b.runs.some(isActive)) - Number(a.runs.some(isActive)) || latest(b.runs) - latest(a.runs));
  }

  // What the panel shows, flat and in display order: project headers, status headers and run
  // rows (collapsed groups contribute only their header). Rendering and keyboard navigation
  // both read this, so they cannot disagree about what is visible.
  items() {
    const out = [];
    for (const g of this.groups()) {
      out.push({ kind: "project", g });
      if (this.collapsed.has(g.id)) continue;
      // The queue comes first: it is what is about to run. Hidden while the failed filter is on.
      if (g.queued.length > 0 && !this.onlyFailed) {
        out.push({ kind: "queue", g });
        if (!this.collapsed.has(`${g.id}::queued`)) for (const e of g.queued) out.push({ kind: "queued", e });
      }
      const byStatus = new Map();
      for (const r of g.runs) {
        if (!byStatus.has(r.status)) byStatus.set(r.status, []);
        byStatus.get(r.status).push(r);
      }
      for (const status of [...byStatus.keys()].sort((a, b) => info(a).rank - info(b).rank)) {
        const rs = byStatus.get(status);
        out.push({ kind: "status", g, status, rs });
        if (this.collapsed.has(`${g.id}::${status}`)) continue;
        for (const r of rs) out.push({ kind: "run", r });
      }
    }
    return out;
  }

  // Widens the sidebar back from the rail, to the width the shipped chrome remembered.
  expandSidebar() {
    setShared("sidebar.collapsed", false);
    run("layout.resize", { id: "sidebar", px: shared("sidebar.width") ?? 268 });
  }

  // Switches the sidebar between the full panel and the rail, the way the shipped chrome folds it:
  // the width it had is remembered in shared("sidebar.width") and restored on the way back.
  toggleSidebar() {
    if (narrow()) return this.expandSidebar();
    const width = findNode(layout(), "sidebar")?.size?.px;
    if (width) setShared("sidebar.width", width);
    setShared("sidebar.collapsed", true);
    run("layout.resize", { id: "sidebar", px: window()?.platform === "macos" ? 76 : 44 });
  }

  // The sidebar is a rail (44-76px): one tile per project (two-letter initial, outlined red while it
  // has failed runs, green-ish while it has active ones) with its failed count under it, under an
  // overall failed/active summary. Clicking anywhere widens the sidebar again. Keyboard handling
  // stays on so Escape and the chords still work.
  renderRail(t) {
    const failed = this.runs.filter((r) => r.status === "failed").length;
    const active = this.runs.filter(isActive).length;
    const queuedN = this.queuedEntries().filter((e) => e.kind === "slot" && !e.stale).length;
    const summary = (text, color) => div().text_size(11).text_color(color).child(text);
    const tile = (g) => {
      const f = g.all.filter((r) => r.status === "failed").length;
      const a = g.all.filter(isActive).length;
      return v_flex().id(`rail-${g.id}`).items_center().gap(2)
        .child(h_flex().size(28).rounded(6).border_1().border_color(f > 0 ? t.blocked : a > 0 ? t.working : t.border)
          .items_center().justify_center()
          .child(div().text_size(10).font_semibold().text_color(t.foreground).child(g.name.slice(0, 2).toUpperCase())))
        .when(f > 0, (el) => el.child(div().text_size(10).text_color(t.blocked).child(String(f))));
    };
    return v_flex().id("foreman-runs").size_full().bg(t.chrome).track_focus(this.handle)
      .on_key_down((e, cx) => this.key(e, cx))
      .items_center().py(10).gap(8).cursor_pointer().overflow_hidden()
      .on_click(() => this.expandSidebar())
      .when(this.error, (el) => el.child(summary("!", t.blocked)))
      .when(!this.error && failed > 0, (el) => el.child(summary(`✕${failed}`, t.blocked)))
      .when(!this.error && active > 0, (el) => el.child(summary(`▶${active}`, t.working)))
      .when(!this.error && this.loaded && failed === 0 && active === 0 && queuedN === 0, (el) => el.child(summary("✓", t.dim)))
      .when(!this.error && this.loaded && queuedN > 0, (el) => el.child(summary(`⧖${queuedN}`, t.dim)))
      .children(this.error ? [] : this.groups(false).map(tile));
  }

  render() {
    const t = theme();
    if (narrow()) return this.renderRail(t);
    const active = this.runs.filter(isActive).length;
    const failed = this.runs.filter((r) => r.status === "failed").length;

    // A run's or queued item's second line: the bead id as a label that copies itself on click (stopped there, so the click
    // does not also open the run), then `rest`. Anything that is not a bead keeps its task id as plain text.
    const idLine = (item, key, who, rest) => {
      const b = beadId(item);
      if (!b) return div().truncate().text_size(11).text_color(t.dim).child(`${who}${rest}`);
      return h_flex().items_center().overflow_hidden()
        .child(div().id(`bead-${key}`).truncate().rounded(3).text_size(11).text_color(t.dim).cursor_pointer().hover((s) => s.bg(t.hover))
          .on_click((_e, cx) => { cx.stop_propagation(); this.copyText(b, `bead id ${b}`, cx); }).child(b))
        .when(rest, (el) => el.child(div().truncate().text_size(11).text_color(t.dim).child(rest)));
    };

    // A small button that clears runs. The click is stopped here so it does not also open (or fold) what it sits in.
    const clearButton = (id, label, runs) => div().id(id).px(4).rounded(3).text_size(11).text_color(t.dim).cursor_pointer().hover((s) => s.bg(t.hover))
      .on_click((_e, cx) => { cx.stop_propagation(); this.clear(runs, cx); }).child(label);
    // The reset button of a failed row: asks first (see askReset), and its click is stopped like the clear button's.
    const resetButton = (r) => div().id(`reset-${r.run_id}`).px(4).rounded(3).text_size(10.5).text_color(t.dim).cursor_pointer().hover((s) => s.bg(t.hover))
      .on_click((_e, cx) => { cx.stop_propagation(); this.askReset(r); }).child("reset");
    // The approve button of a task awaiting approval: asks first (see askApprove).
    const approveButton = (e) => div().id(`approve-${e.task_id}`).px(4).rounded(3).text_size(10.5).text_color(t.dim).cursor_pointer().hover((s) => s.bg(t.hover))
      .on_click((_e, cx) => { cx.stop_propagation(); this.askApprove(e); }).child("approve");

    // Under the list: clear what is shown (failed, stuck, cancelled) and bring back what was cleared.
    const clearable = this.shownRuns().filter(isClearable);
    const clearedN = countCleared(this.allRuns, this.cleared);
    const bar = this.error || (clearable.length === 0 && clearedN === 0) ? null
      : h_flex().px(12).py(3).gap(10).flex_wrap().items_center().border_t(1).border_color(t.border)
        .when(clearable.length > 0, (el) => el.child(div().id("foreman-clear-all").px(4).rounded(3).cursor_pointer().text_size(10.5).text_color(t.dim)
          .hover((s) => s.bg(t.hover)).on_click((_e, cx) => this.clearAll(cx)).child(`✕ clear ${clearable.length}`)))
        .when(clearedN > 0, (el) => el.child(div().id("foreman-restore").px(4).rounded(3).cursor_pointer().text_size(10.5).text_color(t.dim)
          .hover((s) => s.bg(t.hover)).on_click((_e, cx) => this.restoreCleared(cx)).child(`↺ ${clearedN} cleared`)));

    const row = (r) => {
      return v_flex().id(`run-${r.run_id}`).pl(38).pr(12).py(4).gap(1).cursor_pointer().hover((s) => s.bg(t.hover))
        .when(r.run_id === this.cursor, (el) => el.bg(t.selected))
        .on_click(() => this.open(r))
        .child(h_flex().gap(8).items_center()
          .child(div().flex_1().truncate().text_size(12.5).text_color(t.foreground).child(runLabel(r)))
          .child(div().text_size(11).text_color(t.dim).child(ago(r.last_event_at_ms)))
          .when(isResettable(r), (el) => el.child(resetButton(r)))
          .when(isClearable(r), (el) => el.child(clearButton(`clear-${r.run_id}`, "✕", [r]))))
        .child(idLine(r, r.run_id, r.task_id ?? r.run_id, ""));
    };

    // Status subgroup header inside a project; each collapses on its own.
    const statusHead = (g, status, rs) => {
      const st = info(status);
      const key = `${g.id}::${status}`;
      const closed = this.collapsed.has(key);
      return h_flex().id(`status-head-${key}`).pl(22).pr(12).pt(4).pb(2).gap(6).items_center().cursor_pointer()
        .on_click((_e, cx) => this.toggle(key, cx))
        .child(div().w(10).text_size(10).text_color(t.dim).child(closed ? "▸" : "▾"))
        .child(div().size(7).rounded(4).bg(t[st.color] ?? t.dim))
        .child(div().flex_1().truncate().text_size(11.5).text_color(t[st.color] ?? t.dim).child(st.label))
        .when(isClearable({ status }), (el) => el.child(clearButton(`clear-${key}`, "clear", rs)))
        .child(div().text_size(11).text_color(t.dim).child(`${rs.length}`));
    };

    // The queue subgroup: waiting work, collapsible like a status group.
    const queueHead = (g) => {
      const key = `${g.id}::queued`;
      const closed = this.collapsed.has(key);
      const n = g.queued.filter((e) => e.kind === "slot" && !e.stale).length;
      const awaitingN = g.queued.filter((e) => e.kind === "open").length;
      const staleN = g.queued.filter((e) => e.stale).length;
      const counts = [
        ...(n > 0 || (awaitingN === 0 && staleN === 0) ? [`${n}`] : []),
        ...(awaitingN > 0 ? [`${awaitingN} awaiting`] : []),
        ...(staleN > 0 ? [`${staleN} stale`] : []),
      ];
      return h_flex().id(`queue-head-${key}`).pl(22).pr(12).pt(4).pb(2).gap(6).items_center().cursor_pointer()
        .on_click((_e, cx) => this.toggle(key, cx))
        .child(div().w(10).text_size(10).text_color(t.dim).child(closed ? "▸" : "▾"))
        .child(div().size(7).rounded(4).bg(t.idle ?? t.dim))
        .child(div().flex_1().truncate().text_size(11.5).text_color(t.idle ?? t.dim).child("queued"))
        .child(div().text_size(11).text_color(t.dim).child(counts.join(" · ")));
    };

    // A queued item. Display only: a queued run has no transcript or phases to open yet.
    const queuedRow = (e) => {
      const what = e.title ?? e.task_id ?? e.run_id ?? "unknown";
      const who = e.task_id ?? e.run_id ?? "?";
      const tail = e.stale ? `stale: ${e.task_id ? "its run has ended" : "the server has no such run"}`
        : e.kind === "slot" ? "waiting for a slot"
        : `awaiting approval${e.created ? ` · ${ago(e.created)}` : ""}`;
      return v_flex().id(`queued-${e.run_id ?? e.task_id}`).pl(38).pr(12).py(4).gap(1)
        .child(h_flex().gap(8).items_center()
          .child(div().flex_1().truncate().text_size(12.5).text_color(e.stale ? t.dim : t.foreground).child(what))
          .child(div().text_size(11).text_color(t.dim).child(e.kind === "slot" ? `#${e.pos}` : ""))
          .when(isApprovable(e), (el) => el.child(approveButton(e))))
        .child(idLine(e, e.run_id ?? e.task_id, who, ` · ${tail}`));
    };

    const projectHead = (g) => {
      const n = g.all.filter(isActive).length;
      const failedN = g.all.filter((r) => r.status === "failed").length;
      const closed = this.collapsed.has(g.id);
      return h_flex().id(`project-head-${g.id}`).px(12).pt(8).pb(3).gap(6).items_center().cursor_pointer()
        .on_click((_e, cx) => this.toggle(g.id, cx))
        .child(div().w(10).text_size(10).text_color(t.dim).child(closed ? "▸" : "▾"))
        .child(div().flex_1().truncate().text_size(11).font_semibold().text_color(t.muted).child(g.name))
        .when(failedN > 0, (el) => el.child(div().text_size(11).text_color(t.blocked).child(`${failedN} failed`)))
        .child(div().text_size(11).text_color(n > 0 ? t.working : t.dim).child(n > 0 ? `${n}/${g.all.length}` : `${g.all.length}`));
    };

    const note = (text, color) => div().px(12).py(8).text_size(12).text_color(color).child(text);
    // Direct children of the scroll area, flat, so scroll_to_item(index) can reveal any row.
    const items = this.items();
    const elements = !this.loaded ? [note("Loading…", t.dim)]
      : this.error ? [note(`foreman: ${this.error}`, t.blocked)]
      : items.length === 0 ? [note(this.onlyFailed ? "No failed runs" : "No runs or queued work", t.dim)]
      : [
        ...items.map((it) => it.kind === "project" ? projectHead(it.g) : it.kind === "status" ? statusHead(it.g, it.status, it.rs)
          : it.kind === "queue" ? queueHead(it.g) : it.kind === "queued" ? queuedRow(it.e) : row(it.r)),
      ];

    // Hint footer: navigation keys while the panel holds the keyboard, then the bound chords.
    const hints = [
      ...(this.cursor ? [["↑↓", "move"], ["⏎", "open"], ["Esc", "leave"]] : []),
      ...HINTS.map(([command, label]) => [chordFor(`foreman-runs.${command}`), label]).filter(([chord]) => chord),
    ];
    const footer = h_flex().px(12).py(6).gap_x(10).gap_y(2).flex_wrap().border_t(1).border_color(t.border)
      .children(hints.map(([chord, label]) => h_flex().gap(4)
        .child(div().text_size(10).text_color(t.muted).child(chord))
        .child(div().text_size(10).text_color(t.dim).child(label))));

    return v_flex().id("foreman-runs").size_full().bg(t.chrome).track_focus(this.handle)
      .on_key_down((e, cx) => this.key(e, cx))
      .child(h_flex().px(12).py(8).gap(8).items_center()
        .child(div().flex_1().truncate().text_size(11).font_semibold().text_color(t.muted).child("FOREMAN"))
        // Stays visible while the filter is on, even at zero, so the filter can be turned off.
        .when(failed > 0 || this.onlyFailed, (el) => el.child(
          div().id("foreman-failed").px(4).rounded(4).cursor_pointer().text_size(11).text_color(t.blocked)
            .hover((s) => s.bg(t.hover)).when(this.onlyFailed, (e) => e.bg(t.selected))
            .on_click((_e, cx) => this.toggleFailedFilter(cx))
            .child(`${failed} failed`)))
        .child(div().text_size(11).text_color(active > 0 ? t.working : t.dim).child(`${active} active`))
        .when(this.updatedAt > 0, (el) => el.child(
          div().text_size(11).text_color(this.error ? t.blocked : t.dim).child(clock(this.updatedAt))))
        .child(div().id("foreman-refresh").px(5).rounded(4).cursor_pointer().text_size(13)
          .text_color(this.refreshing ? t.working : t.muted).hover((s) => s.bg(t.hover))
          .on_click((_e, cx) => this.refresh(cx, true))
          .child("↻")))
      .when(!this.error && this.queueError, (el) => el.child(note(`Queue unavailable: ${this.queueError}`, t.dim)))
      .when(!this.error && this.runsNote, (el) => el.child(note(`Some runs may be missing: ${this.runsNote}`, t.dim)))
      .child(v_flex().id("foreman-runs-scroll").flex_1().min_h(0).overflow_y_scrollbar().track_scroll(this.scroll)
        .children(elements))
      .when(bar, (el) => el.child(bar))
      .when(!narrow(), (el) => el.child(footer));
  }
}
