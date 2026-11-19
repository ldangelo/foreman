// One Foreman run, live: where it is in its workflow, what the agent is doing (the run's transcript),
// what it has changed, and anything waiting on the operator. Opened from the runs panel
// (`tab.new {mod: "foreman-run", props: {run_id}}`); it polls the Foreman server itself.
import { View, div } from "gpui-kit";
import { v_flex, h_flex, ScrollHandle } from "gpui-base";
import { theme, checking, run, exec, notify, props as tabProps } from "herdr";
import { info, isActive, ago, clock, api, foremanArgv, workflowName, prUrl, openUrlArgv } from "./common.js";

const LIVE_POLL_MS = 3000; // while the run is active
const DONE_POLL_MS = 30000; // a finished run changes little; refreshing it is only a safety net
const CHANGES_EVERY_MS = 10000; // git is run at most this often for an active run
const PAGE = 200; // transcript turns per request
const MAX_TURNS = 500; // turns kept in memory; older ones are dropped from the top
const MAX_LINES = 8; // lines of one turn shown before "show more"
const MAX_CHARS = 6000; // characters of one turn ever rendered
const DIFF_LINES = 120; // lines of one file's diff shown
const RUN_ID = /^[A-Za-z0-9_.-]+$/;
const SAFE_REF = /^[A-Za-z0-9_][A-Za-z0-9_.\/-]*$/; // a base branch is passed to git: never an option

// Prints the commits, changed files (numstat) and untracked files of a run's worktree against the
// point it branched from. $1 = worktree, $2 = base branch. Output is sectioned by "##NAME" lines.
const GIT_CHANGES =
  'cd "$1" || exit 3; ' +
  'base=$(git merge-base HEAD "$2" 2>/dev/null) || base=$(git merge-base HEAD "origin/$2" 2>/dev/null) || { echo "no merge base with $2" >&2; exit 4; }; ' +
  'printf "##HEAD\\n"; git rev-parse --short HEAD; ' +
  'printf "##COMMITS\\n"; git log --no-color --format="%h%x09%s" "$base..HEAD" | head -40; ' +
  'printf "##FILES\\n"; git diff --no-color --no-ext-diff --numstat "$base" -- | head -300; ' +
  'printf "##UNTRACKED\\n"; git ls-files --others --exclude-standard | head -100; ' +
  'printf "##BASE\\n%s\\n" "$base"';
// One file's patch against that base. $1 = worktree, $2 = base commit, $3 = path.
const GIT_DIFF = 'cd "$1" && git diff --no-color --no-ext-diff "$2" -- "$3" | head -n ' + DIFF_LINES;

const compact = (n) => (n >= 1e6 ? `${(n / 1e6).toFixed(1)}M` : n >= 1e3 ? `${(n / 1e3).toFixed(1)}k` : String(n ?? 0));
function span(ms) {
  const s = Math.max(0, Math.floor(ms / 1000));
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m ${s % 60}s`;
  return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`;
}
const oneLine = (v, max = 200) => {
  const s = typeof v === "string" ? v : JSON.stringify(v);
  return s.length > max ? `${s.slice(0, max - 1)}…` : s;
};

// The phase strip: the phases the server has started, with the status each one reports
// (GET /api/runs/:id/phases), then the workflow's remaining phases (from the run's snapshot) as
// "pending" while the run can still reach them or "skipped" once it is over.
const PHASE_STATE = { in_progress: "running", completed: "done", failed: "failed", skipped: "skipped", cancelled: "cancelled" };
function phaseStrip(r, started) {
  const over = ["completed", "failed", "cancelled"].includes(r?.status);
  const seen = new Set(started.map((p) => p.name));
  const rest = (r?.workflow_snapshot?.phases ?? []).filter((p) => !seen.has(p.name ?? p.phase_id));
  return [
    ...started.map((p) => {
      let state = PHASE_STATE[p.status] ?? "pending";
      if (state === "running" && r?.status === "paused") state = "paused";
      // A cancelled or failed run does not close the phase it stopped in: show the run's outcome.
      if (state === "running" && over) state = r.status === "completed" ? "done" : r.status;
      return { name: p.name, state, attempt: p.attempt, reason: p.failure_reason };
    }),
    ...rest.map((p) => ({ name: p.name ?? p.phase_id, state: over ? "skipped" : "pending" })),
  ];
}
const PHASE_GLYPH = { done: ["✓", "done"], running: ["▶", "working"], paused: ["Ⅱ", "idle"], failed: ["✕", "blocked"], cancelled: ["–", "dim"], pending: ["○", "dim"], skipped: ["–", "dim"] };

// A transcript turn: how it is labelled and coloured. kind is text | status | steer | verdict.
function turnStyle(t) {
  if (t.kind === "steer") return { tag: "you", color: "accent" };
  if (t.kind === "status") return { tag: "run", color: "muted" };
  if (t.kind === "verdict") return { tag: "review", color: "accent" };
  return t.source === "stderr" ? { tag: "err", color: "dim" } : { tag: "agent", color: "foreground" };
}

export default class ForemanRun extends View {
  init(_props, cx) {
    // tab.new's props arrive through herdr's props(), not init's argument (that is for nested views).
    this.runId = String(tabProps()?.run_id ?? "");
    this.run = null;
    this.thread = null; // GET /api/threads/run:<id>: title, branch, repo_path
    this.phases = []; // GET /api/runs/:id/phases: the phases started so far, each with its status
    this.turns = [];
    this.cursor = -1; // seq of the newest turn held
    this.omitted = 0; // the transcript's omitted_entries when the cursor was taken
    this.dropped = 0; // turns trimmed from the top of this.turns
    this.approvals = [];
    this.questions = [];
    this.waitWarn = null; // approvals/questions could not be read
    this.phasesWarn = null; // the phases endpoint failed (an older server has none)
    this.changes = null; // see loadChanges()
    this.changesAt = 0;
    this.diffs = new Map(); // path -> {lines} | {error} | "loading"
    this.openDiffs = new Set();
    this.expanded = new Set(); // seqs of turns shown in full
    this.tab = tabProps()?.tab === "changes" ? "changes" : "activity"; // props.tab: where the tab opens
    this.follow = true; // keep the newest turn in view
    this.pendingScroll = false;
    this.scroll = ScrollHandle.new();
    this.error = null;
    this.loaded = false;
    this.busy = false;
    this.refreshing = false;
    this.updatedAt = 0;
    this.lastLoadAt = 0;
    if (!RUN_ID.test(this.runId)) {
      this.error = "No run was given to this tab.";
      this.loaded = true;
      return;
    }
    cx.timer.every(LIVE_POLL_MS, (cx) => {
      if (!this.run || isActive(this.run) || this.run.status === "paused" || Date.now() - this.lastLoadAt >= DONE_POLL_MS) this.refresh(cx);
    });
    this.refresh(cx);
  }

  refresh(cx, manual = false) {
    if (this.busy || checking() || !RUN_ID.test(this.runId)) return;
    this.busy = true;
    if (manual) {
      this.refreshing = true;
      cx.notify();
    }
    cx.spawn(async (cx) => {
      try {
        await this.load(manual);
        this.error = null;
        this.updatedAt = Date.now();
      } catch (e) {
        this.error = String(e?.message ?? e).split("\n")[0];
      } finally {
        this.busy = false;
        this.refreshing = false;
        this.loaded = true;
        this.lastLoadAt = Date.now();
        cx.notify();
      }
    });
  }

  async load(force) {
    const id = this.runId;
    const body = await api(`/api/runs/${id}`);
    if (!body?.run) throw new Error(`run ${id} not found`);
    this.run = body.run;
    // The thread (title, branch, repo) never changes: ask once. A queued run has none yet.
    if (!this.thread) {
      try { this.thread = (await api(`/api/threads/run:${id}`)).thread ?? null; } catch { /* retried next poll */ }
    }
    // A failure here must not take the feed, changes and approvals down with it: the strip then
    // shows the workflow's phases without status, and says why.
    try {
      this.phases = (await api(`/api/runs/${id}/phases`)).phases ?? [];
      this.phasesWarn = null;
    } catch (e) {
      this.phases = [];
      this.phasesWarn = String(e?.message ?? e).split("\n")[0];
    }
    await this.loadTranscript();
    await this.loadWaiting();
    const active = isActive(this.run) || this.run.status === "paused";
    if (force || !this.changes || (active && Date.now() - this.changesAt >= CHANGES_EVERY_MS)) await this.loadChanges();
  }

  // Pulls the transcript turns newer than the cursor. When the server's bounded log window has
  // dropped entries since the cursor was taken, cursors are no longer stable: start over.
  async loadTranscript() {
    for (let pass = 0; pass < 8; pass++) {
      const page = await api(`/api/threads/run:${this.runId}/transcript?after=${this.cursor}&limit=${PAGE}`);
      const omitted = page.omitted_entries ?? 0;
      if (omitted !== this.omitted) {
        this.omitted = omitted;
        this.turns = [];
        this.cursor = -1;
        this.dropped = 0;
        this.expanded.clear();
        continue;
      }
      const fresh = (page.turns ?? []).filter((t) => t.seq > this.cursor);
      if (fresh.length > 0) {
        this.turns.push(...fresh);
        this.cursor = fresh[fresh.length - 1].seq;
        if (this.turns.length > MAX_TURNS) {
          this.dropped += this.turns.length - MAX_TURNS;
          this.turns.splice(0, this.turns.length - MAX_TURNS);
        }
        if (this.follow && this.tab === "activity") this.pendingScroll = true;
      }
      if (fresh.length < PAGE) return;
    }
  }

  // What is waiting on the operator: pending tool approvals (per run) and open questions (per
  // project, narrowed to this run). A failure here is shown, never read as "nothing waiting".
  async loadWaiting() {
    if (!(isActive(this.run) || this.run.status === "paused")) {
      this.approvals = [];
      this.questions = [];
      this.waitWarn = null;
      return;
    }
    try {
      this.approvals = (await api(`/api/runs/${this.runId}/approvals`)).approvals ?? [];
      const pid = this.run.project_id;
      this.questions = pid && RUN_ID.test(pid)
        ? ((await api(`/api/projects/${pid}/questions`)).questions ?? []).filter((q) => q.run_id === this.runId)
        : [];
      this.waitWarn = null;
    } catch (e) {
      this.waitWarn = String(e?.message ?? e).split("\n")[0];
    }
  }

  // The run's worktree is found through its repository's `git worktree list`, by the run id in its
  // path. A run that has finished and been cleaned up has none: the pull request's file list
  // stands in for it. Result: {state: "ok"|"none"|"error", source, files, commits, untracked, ...}.
  async loadChanges() {
    this.changesAt = Date.now();
    const r = this.run;
    const base = r.base_branch;
    try {
      const wt = await this.findWorktree();
      if (wt && SAFE_REF.test(base ?? "")) {
        const res = await exec("sh", ["-c", GIT_CHANGES, "sh", wt, base], { timeout: 20000 });
        if (res.code !== 0) throw new Error(res.stderr.trim().split("\n")[0] || `git exited ${res.code}`);
        this.changes = { state: "ok", source: "worktree", worktree: wt, ...parseChanges(res.stdout) };
        return;
      }
      const url = prUrl(r);
      if (url) {
        const res = await exec("gh", ["pr", "view", url, "--json", "files,additions,deletions"], { timeout: 20000 });
        if (res.code !== 0) throw new Error(res.stderr.trim().split("\n")[0] || `gh exited ${res.code}`);
        const pr = JSON.parse(res.stdout);
        const files = (pr.files ?? []).map((f) => ({ path: f.path, add: f.additions, del: f.deletions }));
        this.changes = { state: "ok", source: "pull request", files, commits: [], untracked: [], head: null, base: null };
        return;
      }
      this.changes = { state: "none", reason: wt ? "no base branch recorded" : "the worktree is gone and there is no pull request" };
    } catch (e) {
      this.changes = { state: "error", reason: String(e?.message ?? e).split("\n")[0] };
    }
  }

  async findWorktree() {
    const repo = this.thread?.repo_path;
    if (typeof repo !== "string" || !repo.startsWith("/")) return null;
    const res = await exec("git", ["-C", repo, "worktree", "list", "--porcelain"], { timeout: 15000 });
    if (res.code !== 0) return null;
    for (const block of res.stdout.split("\n\n")) {
      const path = /^worktree (.+)$/m.exec(block)?.[1];
      if (path?.startsWith("/") && path.includes(`/${this.runId}/`)) return path;
    }
    return null;
  }

  toggleDiff(path, cx) {
    if (this.openDiffs.delete(path)) return cx.notify();
    this.openDiffs.add(path);
    cx.notify();
    const c = this.changes;
    if (this.diffs.has(path) || c?.source !== "worktree" || !c.base) return;
    this.diffs.set(path, "loading");
    cx.spawn(async (cx) => {
      try {
        const res = await exec("sh", ["-c", GIT_DIFF, "sh", c.worktree, c.base, path], { timeout: 20000 });
        if (res.code !== 0) throw new Error(res.stderr.trim().split("\n")[0] || `git exited ${res.code}`);
        this.diffs.set(path, { lines: res.stdout.split("\n") });
      } catch (e) {
        this.diffs.set(path, { error: String(e?.message ?? e).split("\n")[0] });
      }
      cx.notify();
    });
  }

  openPr() {
    const url = this.run && prUrl(this.run);
    if (!url) return notify({ title: "Foreman", body: "This run has no pull request.", level: "info" });
    exec(...openUrlArgv(url), { timeout: 10000 }).catch((e) =>
      notify({ title: "Foreman", body: `Could not open ${url}: ${String(e?.message ?? e).split("\n")[0]}`, level: "error" }));
  }

  openRaw() {
    run("tab.new", { name: `raw ${this.runId.slice(0, 20)}`, argv: foremanArgv(["run", "get", this.runId]) });
  }

  setFollow(on, cx) {
    this.follow = on;
    if (on) this.pendingScroll = true;
    cx.notify();
  }

  setTab(tab, cx) {
    this.tab = tab;
    if (tab === "activity" && this.follow) this.pendingScroll = true;
    cx.notify();
  }

  // ------------------------------------------------------------------------------- rendering

  renderTurn(t, th) {
    const st = turnStyle(t);
    const text = String(t.text ?? "").trim().slice(0, MAX_CHARS);
    const lines = text.split("\n");
    const open = this.expanded.has(t.seq);
    const long = lines.length > MAX_LINES;
    const shown = long && !open ? `${lines.slice(0, MAX_LINES).join("\n")}` : text;
    const at = t.at ? clock(Date.parse(t.at)) : "";
    return v_flex().id(`turn-${t.seq}`).px(12).py(4).gap(1)
      .when(t.kind === "steer", (el) => el.bg(th.surface))
      .child(h_flex().gap(8).items_center()
        .child(div().w(54).text_size(10.5).text_color(th.dim).child(at))
        .child(div().w(40).text_size(10.5).font_semibold().text_color(th[st.color] ?? th.dim).child(st.tag)))
      .child(div().pl(102).text_size(12).text_color(t.source === "stderr" ? th.dim : th.foreground).child(shown))
      .when(long, (el) => el.child(
        div().id(`turn-more-${t.seq}`).pl(102).text_size(11).text_color(th.accent).cursor_pointer()
          .on_click((_e, cx) => { if (!this.expanded.delete(t.seq)) this.expanded.add(t.seq); cx.notify(); })
          .child(open ? "show less" : `… ${lines.length - MAX_LINES} more lines`)));
  }

  renderFile(f, th) {
    const c = this.changes;
    const canDiff = c.source === "worktree" && c.base && !f.untracked;
    const open = this.openDiffs.has(f.path);
    const d = this.diffs.get(f.path);
    return v_flex().id(`file-${f.path}`)
      .child(h_flex().px(12).py(3).gap(8).items_center().hover((s) => s.bg(th.hover))
        .when(canDiff, (el) => el.cursor_pointer().on_click((_e, cx) => this.toggleDiff(f.path, cx)))
        .child(div().w(10).text_size(10).text_color(th.dim).child(canDiff ? (open ? "▾" : "▸") : ""))
        .child(div().w(46).text_size(11).text_color(f.untracked ? th.accent : th.done).child(f.untracked ? "new" : `+${f.add}`))
        .child(div().w(46).text_size(11).text_color(th.blocked).child(f.untracked ? "" : `−${f.del}`))
        .child(div().flex_1().truncate().text_size(12).text_color(th.foreground).child(f.path)))
      .when(open, (el) => el.child(
        v_flex().px(34).py(4).gap(0).bg(th.surface).children(
          d === "loading" || d === undefined ? [div().text_size(11).text_color(th.dim).child("Loading…")]
            : d.error ? [div().text_size(11).text_color(th.blocked).child(d.error)]
            : d.lines.map((l) => div().text_size(11).text_color(l.startsWith("+") && !l.startsWith("+++") ? th.done : l.startsWith("-") && !l.startsWith("---") ? th.blocked : l.startsWith("@@") ? th.accent : th.muted).child(l || " ")))));
  }

  render() {
    const th = theme();
    const r = this.run;
    const st = info(r?.status);
    const pill = (id, label, on, handler) => div().id(id).px(6).py(2).rounded(4).cursor_pointer().text_size(11)
      .text_color(on ? th.foreground : th.muted).hover((s) => s.bg(th.hover)).when(on, (e) => e.bg(th.selected)).on_click(handler).child(label);
    const note = (text, color) => div().px(12).py(8).text_size(12).text_color(color).child(text);
    const banner = (text, color) => div().px(12).py(4).text_size(12).text_color(color).child(text);

    // ---- header
    const waiting = this.approvals.length + this.questions.length;
    const usage = r?.usage;
    const elapsed = r?.started_at_ms ? span((isActive(r) || r.status === "paused" ? Date.now() : (r.last_event_at_ms ?? Date.now())) - r.started_at_ms) : null;
    const metrics = [
      elapsed && `elapsed ${elapsed}`,
      r?.last_event_at_ms && `last event ${ago(r.last_event_at_ms)} ago`,
      usage && `${compact(usage.input_tokens)} in · ${compact(usage.output_tokens)} out${usage.cache_read_tokens ? ` · ${compact(usage.cache_read_tokens)} cached` : ""}`,
      usage && usage.cost_usd > 0 && `$${usage.cost_usd.toFixed(2)}`,
    ].filter(Boolean).join("   ·   ");
    const where = [this.runId, r?.project_id, this.thread?.branch, r?.base_branch && `base ${r.base_branch}`].filter(Boolean).join("  ·  ");

    const head = v_flex().gap(2).px(12).pt(10).pb(6)
      .child(h_flex().gap(8).items_center()
        .child(div().size(8).rounded(4).bg(th[st.color] ?? th.dim))
        .child(div().text_size(13).font_semibold().text_color(th[st.color] ?? th.dim).child(st.label))
        .child(div().text_size(13).font_semibold().text_color(th.foreground).child(r ? workflowName(r) : "run"))
        .child(div().flex_1().truncate().text_size(12).text_color(th.muted).child(this.thread?.title ?? r?.task_id ?? ""))
        .when(r && prUrl(r), (el) => el.child(pill("pr", "PR ↗", false, () => this.openPr())))
        .child(pill("raw", "raw", false, () => this.openRaw()))
        .when(this.updatedAt > 0, (el) => el.child(div().text_size(11).text_color(this.error ? th.blocked : th.dim).child(clock(this.updatedAt))))
        .child(div().id("refresh").px(5).rounded(4).cursor_pointer().text_size(13).text_color(this.refreshing ? th.working : th.muted)
          .hover((s) => s.bg(th.hover)).on_click((_e, cx) => this.refresh(cx, true)).child("↻")))
      .child(div().id("copy-id").truncate().text_size(11).text_color(th.dim).cursor_pointer()
        .on_click((_e, cx) => { cx.write_to_clipboard(this.runId); notify({ title: "Foreman", body: `Copied ${this.runId}`, level: "success", timeout: 2000 }); })
        .child(where))
      .when(metrics, (el) => el.child(div().text_size(11).text_color(th.muted).child(metrics)));

    const phases = r ? phaseStrip(r, this.phases) : [];
    const phaseRow = phases.length === 0 ? null
      : h_flex().px(12).py(4).gap_x(14).gap_y(2).flex_wrap().items_center()
        .children(phases.map((p, i) => {
          const [glyph, color] = PHASE_GLYPH[p.state];
          return h_flex().gap(4).items_center()
            .child(div().text_size(12).text_color(th[color] ?? th.dim).child(glyph))
            .child(div().text_size(12).font_semibold().text_color(p.state === "running" ? th.foreground : th.muted).child(p.name))
            .when(p.attempt > 1, (el) => el.child(div().text_size(11).text_color(th.idle).child(`×${p.attempt}`)))
            .when(i < phases.length - 1, (el) => el.child(div().text_size(11).text_color(th.dim).child("›")));
        }));

    const alerts = [
      r?.status === "failed" && r.failure_reason && banner(`Failed: ${oneLine(r.failure_reason)}`, th.blocked),
      r?.latest_stall && banner(`Stalled: ${oneLine(r.latest_stall)}`, th.blocked),
      ...this.approvals.map((a) => banner(`Waiting for your approval: ${a.tool_name}${a.input_summary ? ` — ${oneLine(a.input_summary, 140)}` : ""}`, th.idle)),
      ...this.questions.map((q) => banner(`Asks: ${oneLine(q.text ?? "(no text)", 200)}`, th.idle)),
      this.waitWarn && banner(`Could not read approvals/questions: ${this.waitWarn}`, th.blocked),
      this.phasesWarn && banner(`Phase status unavailable: ${this.phasesWarn}`, th.dim),
    ].filter(Boolean);

    const files = this.changes?.state === "ok"
      ? [...this.changes.files, ...this.changes.untracked.map((path) => ({ path, untracked: true }))] : [];
    // The agent's stream is chunked and many chunks are only newlines; a row that says "agent" and
    // nothing else tells the reader nothing. They stay in this.turns (the cursor counts them), they
    // are just not drawn.
    const visible = this.turns.filter((t) => String(t.text ?? "").trim() !== "");
    const tabs = h_flex().px(8).py(3).gap(4).items_center().border_t(1).border_b(1).border_color(th.border)
      .child(pill("tab-activity", `Activity${visible.length ? ` (${visible.length})` : ""}`, this.tab === "activity", (_e, cx) => this.setTab("activity", cx)))
      .child(pill("tab-changes", `Changes${this.changes?.state === "ok" ? ` (${files.length})` : ""}`, this.tab === "changes", (_e, cx) => this.setTab("changes", cx)))
      .child(div().flex_1())
      .when(this.tab === "activity", (el) => el.child(pill("follow", this.follow ? "following" : "follow", this.follow, (_e, cx) => this.setFollow(!this.follow, cx))));

    // ---- body (direct children of the scroll area, flat, so scroll_to_item can reach any row)
    let rows;
    if (!this.loaded) rows = [note("Loading…", th.dim)];
    else if (!r) rows = [note(this.error ?? "Run not found", th.blocked)];
    else if (this.tab === "activity") {
      rows = visible.length === 0
        ? [note(isActive(r) ? "No output yet. The agent has not written anything." : "This run produced no output.", th.dim)]
        : visible.map((t) => this.renderTurn(t, th));
      if (this.dropped > 0) rows.unshift(note(`${this.dropped} earlier turns are not shown.`, th.dim));
    } else {
      const c = this.changes;
      if (!c) rows = [note("Looking for changes…", th.dim)];
      else if (c.state === "error") rows = [note(`Could not read the changes: ${c.reason}`, th.blocked)];
      else if (c.state === "none") rows = [note(`No changes to show: ${c.reason}.`, th.dim)];
      else {
        const add = c.files.reduce((n, f) => n + (f.add || 0), 0);
        const del = c.files.reduce((n, f) => n + (f.del || 0), 0);
        rows = [
          note(`${files.length} file${files.length === 1 ? "" : "s"}  ·  +${add} −${del}  ·  from the ${c.source}${c.head ? `  ·  HEAD ${c.head}` : ""}${c.source === "worktree" ? "  ·  includes uncommitted work" : ""}`, th.muted),
          ...c.commits.map((m) => h_flex().id(`commit-${m.sha}`).px(12).py(2).gap(8)
            .child(div().w(10))
            .child(div().w(60).text_size(11).text_color(th.accent).child(m.sha))
            .child(div().flex_1().truncate().text_size(12).text_color(th.foreground).child(m.subject))),
          ...(c.commits.length > 0 && files.length > 0 ? [div().h(1).mx(12).my(4).bg(th.border)] : []),
          ...files.map((f) => this.renderFile(f, th)),
          ...(files.length === 0 ? [note("Nothing has changed yet.", th.dim)] : []),
        ];
      }
    }
    if (this.pendingScroll && this.tab === "activity" && rows.length > 0) {
      this.pendingScroll = false;
      this.scroll.scroll_to_item(rows.length - 1);
    }

    return v_flex().id("foreman-run").size_full().bg(th.chrome)
      .child(head)
      .when(phaseRow, (el) => el.child(phaseRow))
      .children(alerts)
      .child(tabs)
      // The wheel handler sits on a wrapper, never on the scroll area: gpui-kit documents
      // on_scroll_wheel as the gesture for something other than scrolling, and putting it on the
      // scroll container itself can take the wheel away from it. Reading back through the output
      // (an upward wheel) stops the auto-follow; "follow" turns it on again.
      .child(v_flex().id("foreman-run-wheel").flex_1().min_h(0)
        .on_scroll_wheel((e, cx) => { if (this.follow && this.tab === "activity" && e.delta?.y > 0) { this.follow = false; cx.notify(); } })
        .child(v_flex().id("foreman-run-scroll").size_full().overflow_y_scrollbar().track_scroll(this.scroll)
          .children(rows)))
      .when(this.error && r, (el) => el.child(div().px(12).py(4).text_size(11).text_color(th.blocked).border_t(1).border_color(th.border).child(`foreman: ${this.error}`)));
  }
}

// "##SECTION" blocks from GIT_CHANGES: commits are "sha<TAB>subject"; files are numstat lines
// ("add<TAB>del<TAB>path", "-" counts for binaries).
function parseChanges(out) {
  const sec = { HEAD: [], COMMITS: [], FILES: [], UNTRACKED: [], BASE: [] };
  let cur = null;
  for (const line of out.split("\n")) {
    const m = /^##([A-Z]+)$/.exec(line);
    if (m) { cur = sec[m[1]] ?? null; continue; }
    if (cur && line !== "") cur.push(line);
  }
  return {
    head: sec.HEAD[0] ?? null,
    base: sec.BASE[0] ?? null,
    commits: sec.COMMITS.map((l) => { const [sha, ...rest] = l.split("\t"); return { sha, subject: rest.join("\t") }; }),
    files: sec.FILES.map((l) => {
      const [add, del, ...path] = l.split("\t");
      return { path: path.join("\t"), add: add === "-" ? 0 : Number(add), del: del === "-" ? 0 : Number(del) };
    }),
    untracked: sec.UNTRACKED,
  };
}
