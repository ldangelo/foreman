// One Foreman run, live: what it is doing right now (or how it ended), its phases and their reports, the
// agent's output, what it has changed, its pull request's evidence and anything waiting on the operator.
// Opened from the runs panel (`tab.new {mod: "foreman-run", props: {run_id, tab?}}`); it polls the Foreman
// server itself and only ever reads from it. The logic that is not drawing lives in ./model.js.
import { View, div } from "gpui-kit";
import { v_flex, h_flex, ScrollHandle } from "gpui-base";
import { theme, checking, run, exec, home, notify, readTextFile, settings, props as tabProps } from "herdr";
import { info, clock, api, foreman, foremanArgv, prUrl, beadId, workflowName, openUrlArgv } from "./common.js";
import * as M from "./model.js";

const LIVE_POLL_MS = 3000; // while the run is active
const DONE_POLL_MS = 30000; // a finished run changes little; refreshing it is only a safety net
const CHANGES_EVERY_MS = 10000; // git is run at most this often for an active run
const SIDE_EVERY_MS = 10000; // PR evidence and the report list are read at most this often while the run is active
const PAGE = 200; // transcript turns per request
const MAX_TURNS = 500; // turns kept in memory; older ones are dropped from the top
const MAX_LINES = 8; // lines of one turn shown before "show more"
const MAX_CHARS = 6000; // characters of one turn ever rendered
const REASON_LINES = 6; // lines of a failure reason shown before "show more"
const REASON_CHARS = 2000;
const DIFF_LINES = 120; // lines of one file's diff shown
const REPORT_ROWS = 120; // rows of a phase report drawn before "show more"
const REPORT_PAGE = 300;
const TAIL_CHARS = 180;
const RUN_ID = /^[A-Za-z0-9_.-]+$/;
const PHASE_ID = /^[A-Za-z0-9_.:-]+$/;
const SAFE_REF = /^[A-Za-z0-9_][A-Za-z0-9_.\/-]*$/; // a base branch is passed to git: never an option
const OPENABLE = /\.(?:md|markdown|txt|json|log|ya?ml)$/i; // a report is opened in the default app only if it is a document
const REPORT_CAP = 262144; // bytes of a report read from git (the server's own route caps at the same size)
// One file of a commit: its size on the first line, then its text (capped). $1 = repository, $2 = commit, $3 = path.
const GIT_BLOB = `git -C "$1" cat-file -s "$2:$3" || exit 3; git -C "$1" show "$2:$3" | head -c ${REPORT_CAP}`;
const firstLine = (s) => String(s ?? "").trim().split("\n")[0];

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

const TABS = [["overview", "Overview"], ["activity", "Activity"], ["phases", "Phases"], ["changes", "Changes"], ["pr", "PR"]];
// The projection has statuses common.js does not style (a run the stall detector flagged is "stuck").
const STATUS_EXTRA = { blocked: { color: "blocked", label: "blocked" }, stuck: { color: "blocked", label: "stuck" } };
const statusInfo = (s) => STATUS_EXTRA[s] ?? info(s);
const errLine = (e) => String(e?.message ?? e).split("\n")[0];

// ------------------------------------------------------------------------------------ small elements

const col = (th, name) => th[name] ?? th.dim;
const note = (th, s, color = "dim") => div().px(12).py(8).text_size(12).text_color(col(th, color)).child(String(s));
const banner = (th, s, color) => div().px(12).py(4).text_size(12).text_color(col(th, color)).child(String(s));
const heading = (th, s) => div().px(12).pt(12).pb(3).text_size(11).font_semibold().text_color(th.muted).child(String(s).toUpperCase());
const kv = (th, label, value, color = "foreground") => h_flex().px(12).py(1).gap(8).items_start()
  .child(div().w(104).flex_none().text_size(11).text_color(th.dim).child(label))
  .child(div().flex_1().min_w(0).text_size(12).text_color(col(th, color)).child(String(value)));
const chip = (th, id, label, on, handler) => div().id(id).px(6).py(2).rounded(4).cursor_pointer().text_size(11)
  .text_color(on ? th.foreground : th.muted).hover((s) => s.bg(th.hover)).when(on, (e) => e.bg(th.selected)).on_click(handler).child(label);

export default class ForemanRun extends View {
  init(_props, cx) {
    // tab.new's props arrive through herdr's props(), not init's argument (that is for nested views).
    this.runId = String(tabProps()?.run_id ?? "");
    this.run = null;
    this.thread = null; // GET /api/threads/run:<id>: title, branch, repo_path
    this.phases = []; // GET /api/runs/:id/phases: the phases started so far, each with its status
    this.turns = []; // prepared turns (model.prepareTurn), oldest first
    this.blank = 0; // transcript turns left out because they hold nothing to read
    this.cursor = -1; // seq of the newest turn held
    this.omitted = 0; // the transcript's omitted_entries when the cursor was taken
    this.dropped = 0; // turns trimmed from the top of this.turns
    this.approvals = [];
    this.questions = [];
    this.warn = {}; // source name -> {kind, text} of its latest failed read; absent while it works
    this.prSum = null; // GET /api/runs/:id/prs, reduced (model.summarizePrs)
    this.prsAt = 0;
    this.prsOkAt = 0;
    this.artifacts = null; // GET /api/runs/:id/artifacts: the listing entries
    this.artifactMap = null; // phase_id -> entry; null until the listing has been read
    this.artifactsAt = 0;
    this.repoPath = null; // the run's repository: its thread's repo_path, else its project's registered path
    this.gitIdx = null; // {at, repo, commits: Map phase number -> sha} | {at, error}: the run's phase commits
    this.gitReports = new Map(); // phase key -> {status: "loading"|"done"|"failed", repo, sha, files, reason, warn}
    this.reports = new Map(); // phase_id -> {sha, status: "loading"|"done"|"failed", body, rows, warn}: fetched on expand
    this.reportShown = new Map(); // phase_id -> rows of its report drawn
    this.changes = null; // see loadChanges()
    this.changesAt = 0;
    this.diffs = new Map(); // path -> {lines} | {error} | "loading"
    this.openDiffs = new Set();
    this.expanded = new Set(); // keys of turns (and "outcome") shown in full
    this.openPhases = new Set(); // phases expanded in the Phases tab
    this.openSlices = new Set(); // phases whose agent output is shown in the Phases tab
    this.hiddenGroups = new Set(); // phases collapsed in the Activity feed
    const want = tabProps()?.tab; // props.tab: where the tab opens; without it the run's state decides
    this.tab = TABS.some(([id]) => id === want) ? want : null;
    const wantPhase = tabProps()?.phase; // props.phase: a phase (its name or number) to open in the Phases tab
    this.wantPhase = wantPhase === undefined || wantPhase === null || wantPhase === "" ? null : String(wantPhase);
    if (this.wantPhase !== null && this.tab === null) this.tab = "phases";
    this.filter = "all";
    this.follow = true; // keep the newest turn in view
    this.pendingScroll = false;
    this.pendingTop = false;
    this.jumpTo = null; // a phase key the Phases tab should scroll to
    this.scroll = ScrollHandle.new();
    const font = settings()?.font_family;
    this.mono = typeof font === "string" && font !== "" ? font : null;
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
      if (!this.run || !M.isFinished(this.run) || Date.now() - this.lastLoadAt >= DONE_POLL_MS) this.refresh(cx);
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
        this.error = errLine(e);
      } finally {
        this.busy = false;
        this.refreshing = false;
        this.loaded = true;
        this.lastLoadAt = Date.now();
        cx.notify();
      }
    });
  }

  // Every source is read on its own: one failing never takes the others down, and its failure is kept
  // (this.warn) to be shown, never read as "nothing there".
  async load(force) {
    const id = this.runId;
    const body = await api(`/api/runs/${id}`);
    if (!body?.run) throw new Error(`run ${id} not found`);
    this.run = body.run;
    if (this.tab === null) {
      this.tab = M.isFinished(this.run) ? "overview" : "activity";
      this.pendingScroll = this.tab === "activity";
    }
    await Promise.all([this.loadThread(), this.loadPhases()]);
    if (this.wantPhase !== null) {
      const row = this.phaseRows().find((r) => r.started && (r.name === this.wantPhase || String(r.index) === this.wantPhase));
      this.wantPhase = null;
      if (row) { this.openPhases.add(row.key); this.jumpTo = row.key; }
    }
    await this.loadTranscript();
    const live = M.isLive(this.run);
    const due = (at) => force || at === 0 || Date.now() - at >= (live ? SIDE_EVERY_MS : DONE_POLL_MS);
    await Promise.all([
      this.loadWaiting(),
      due(this.prsAt) ? this.loadPrs() : null,
      due(this.artifactsAt) ? this.loadArtifacts() : null,
      force || !this.changes || ((live || this.run.status === "paused") && Date.now() - this.changesAt >= CHANGES_EVERY_MS) ? this.loadChanges() : null,
    ]);
    await this.refreshOpenReports(force);
    await this.prefetchGitReports(force);
  }

  // The thread (title, branch, repo) never changes: ask until it has answered. A queued run has none yet.
  async loadThread() {
    if (this.thread) return;
    try {
      this.thread = (await api(`/api/threads/run:${this.runId}`)).thread ?? null;
      delete this.warn.thread;
    } catch (e) {
      this.warn.thread = M.classifyFetchError(e, "/api/threads/:id");
    }
  }

  async loadPhases() {
    try {
      const body = await api(`/api/runs/${this.runId}/phases`);
      if (!Array.isArray(body?.phases)) throw new Error("unexpected phases answer: no phases list");
      this.phases = body.phases;
      delete this.warn.phases;
    } catch (e) {
      this.phases = [];
      this.warn.phases = M.classifyFetchError(e, "/api/runs/:id/phases");
    }
  }

  // Whether the agent streams its own words (a harness phase), so a turn of its stdout is chunks to put
  // back together; the stdout of a `command:` phase is the command's own output, which is never touched.
  agentAt(raw) {
    const snaps = this.run?.workflow_snapshot?.phases ?? [];
    const agent = (s) => !!s && !!s.provider && !s.command && (s.action == null || s.action === "prompt");
    const at = typeof raw.at === "string" ? Date.parse(raw.at) : NaN;
    let cur = null;
    if (Number.isFinite(at)) {
      for (const p of this.phases) {
        if (Number.isFinite(p.started_at_ms) && p.started_at_ms <= at && (!cur || p.started_at_ms >= cur.started_at_ms)) cur = p;
      }
    }
    if (cur) return agent(snaps.find((s) => s.phase_id === cur.phase_id) ?? snaps.find((s) => s.name === cur.name));
    return !snaps.some((s) => s.command);
  }

  // Pulls the transcript turns newer than the cursor. When the server's bounded log window has
  // dropped entries since the cursor was taken, cursors are no longer stable: start over.
  async loadTranscript() {
    try {
      for (let pass = 0; pass < 8; pass++) {
        const page = await api(`/api/threads/run:${this.runId}/transcript?after=${this.cursor}&limit=${PAGE}`);
        const omitted = page.omitted_entries ?? 0;
        if (omitted !== this.omitted) {
          this.omitted = omitted;
          this.turns = [];
          this.cursor = -1;
          this.dropped = 0;
          this.blank = 0;
          continue;
        }
        const fresh = (page.turns ?? []).filter((t) => t.seq > this.cursor);
        if (fresh.length > 0) {
          // The agent's stream is chunked and many chunks are only newlines or a terminal bell; a row
          // that says "agent" or "err" and nothing else tells the reader nothing, and they would crowd
          // real turns out of the buffer. They are not kept, but the cursor still moves past them (it is
          // the raw page's).
          const kept = fresh.filter((t) => !M.isBlankTurn(t)).map((t) => M.prepareTurn(t, this.agentAt(t))).filter((t) => t.text !== "");
          this.blank += fresh.length - kept.length;
          this.turns.push(...kept);
          this.cursor = fresh[fresh.length - 1].seq;
          if (this.turns.length > MAX_TURNS) {
            this.dropped += this.turns.length - MAX_TURNS;
            this.turns.splice(0, this.turns.length - MAX_TURNS);
          }
          if (this.follow && this.tab === "activity") this.pendingScroll = true;
        }
        if (fresh.length < PAGE) break;
      }
      delete this.warn.transcript;
    } catch (e) {
      this.warn.transcript = M.classifyFetchError(e, "/api/threads/:id/transcript");
    }
  }

  // What is waiting on the operator: pending tool approvals (per run) and open questions (per
  // project, narrowed to this run). A failure here is shown, never read as "nothing waiting".
  async loadWaiting() {
    if (M.isFinished(this.run)) {
      this.approvals = [];
      this.questions = [];
      delete this.warn.waiting;
      return;
    }
    try {
      this.approvals = (await api(`/api/runs/${this.runId}/approvals`)).approvals ?? [];
      const pid = this.run.project_id;
      this.questions = pid && RUN_ID.test(pid)
        ? ((await api(`/api/projects/${pid}/questions`)).questions ?? []).filter((q) => q.run_id === this.runId)
        : [];
      delete this.warn.waiting;
    } catch (e) {
      this.warn.waiting = M.classifyFetchError(e, "/api/runs/:id/approvals");
    }
  }

  // The PR evidence the server judges the run's pull request by (GET /api/runs/:id/prs). On a failed
  // refresh the last good answer stays on screen, marked as old, next to the reason.
  async loadPrs() {
    this.prsAt = Date.now();
    try {
      this.prSum = M.summarizePrs(await api(`/api/runs/${this.runId}/prs`));
      this.prsOkAt = Date.now();
      delete this.warn.prs;
    } catch (e) {
      this.warn.prs = M.classifyFetchError(e, "/api/runs/:id/prs");
    }
  }

  // Which phases recorded a report (GET /api/runs/:id/artifacts): names, sizes and digests, no content.
  async loadArtifacts() {
    this.artifactsAt = Date.now();
    try {
      const body = await api(`/api/runs/${this.runId}/artifacts`);
      if (!Array.isArray(body?.artifacts) || body.artifacts.some((a) => typeof a?.phase_id !== "string" || typeof a?.sha256 !== "string")) {
        throw new Error("unexpected artifacts answer: no list of {phase_id, sha256, …}");
      }
      this.artifacts = body.artifacts;
      this.artifactMap = new Map(body.artifacts.map((a) => [a.phase_id, a]));
      delete this.warn.artifacts;
    } catch (e) {
      this.artifacts = null;
      this.artifactMap = null;
      this.warn.artifacts = M.classifyFetchError(e, "/api/runs/:id/artifacts");
    }
  }

  // A report is fetched when its phase is expanded, once per digest: a phase that wrote a new report
  // (another sha256 in the listing) is read again, an unchanged one never is (↻ reads it again). A read
  // that failed is retried at most as often as the other side reads.
  async loadReport(entry, force = false) {
    const id = entry.phase_id;
    const cur = this.reports.get(id);
    const same = cur && cur.sha === entry.sha256;
    if (!force && same && (cur.status === "loading" || cur.status === "done" || Date.now() - cur.at < SIDE_EVERY_MS)) return;
    this.reports.set(id, { sha: entry.sha256, status: "loading", at: Date.now() });
    try {
      if (!PHASE_ID.test(id)) throw new Error(`refusing odd phase id: ${id}`);
      const body = await api(`/api/runs/${this.runId}/artifacts/${id}`);
      const okState = body?.state === "ok" || body?.state === "missing" || body?.state === "unreadable";
      if (!okState || (body.state === "ok" && typeof body.content !== "string")) throw new Error("unexpected artifact answer: no state/content");
      this.reports.set(id, { sha: entry.sha256, status: "done", at: Date.now(), body, rows: body.state === "ok" ? M.markdownRows(body.content) : [] });
    } catch (e) {
      this.reports.set(id, { sha: entry.sha256, status: "failed", at: Date.now(), warn: M.classifyFetchError(e, "/api/runs/:id/artifacts/:phase_id") });
    }
  }

  // The phase rows as the view builds them, for the loaders that need to know what each phase is.
  phaseRows() {
    const r = this.run;
    return r ? M.buildPhaseRows(r, this.phases, r.workflow_snapshot?.phases, this.artifactMap, Date.now()) : [];
  }

  // Whether the server cannot give this finished phase's report, so the run's own commits are asked instead:
  // it cannot list reports at all (no route), or it listed this one and then could not read it (the file is gone).
  needsGit(row) {
    if (!row.started || row.state !== "done") return false;
    if (!this.artifactMap) return true;
    const entry = this.artifactMap.get(row.phaseId);
    if (!entry) return false;
    const c = this.reports.get(row.phaseId);
    return c?.status === "failed" || (c?.status === "done" && c.body.state !== "ok");
  }

  async ensureReport(row, force = false) {
    const entry = this.artifactMap?.get(row.phaseId);
    if (entry) await this.loadReport(entry, force);
    if (this.needsGit(row)) await this.loadGitReport(row, force);
  }

  async refreshOpenReports(force) {
    for (const row of this.phaseRows()) if (this.openPhases.has(row.key)) await this.ensureReport(row, force);
  }

  // A server that cannot list reports gets every finished phase looked up in git up front, so the phase list
  // can say what each report is without opening it.
  async prefetchGitReports(force) {
    if (this.artifactMap) return;
    for (const row of this.phaseRows()) if (this.needsGit(row)) await this.loadGitReport(row, force);
  }

  // The run's repository: the thread's repo_path, else the path its project is registered with.
  async findRepo() {
    if (this.repoPath) return this.repoPath;
    const fromThread = this.thread?.repo_path;
    if (typeof fromThread === "string" && fromThread.startsWith("/")) return (this.repoPath = fromThread);
    const pid = this.run?.project_id;
    if (typeof pid !== "string" || pid === "") return null;
    const projects = await foreman(["project", "list", "--include-archived", "--format=json"]);
    const path = Array.isArray(projects) ? projects.find((x) => x?.project_id === pid)?.path : null;
    if (typeof path === "string" && path.startsWith("/")) this.repoPath = path;
    return this.repoPath;
  }

  // One `git log` for the run's phase commits ("Foreman run <id> phase <n>"): phase number -> commit.
  async loadGitIndex(force = false) {
    const cur = this.gitIdx;
    if (cur && !force && (Date.now() - cur.at < SIDE_EVERY_MS || (!cur.error && !M.isLive(this.run)))) return cur;
    const at = Date.now();
    try {
      if (!RUN_ID.test(this.runId)) throw new Error(`refusing odd run id: ${this.runId}`);
      const repo = await this.findRepo();
      if (!repo) throw new Error("the run's repository is unknown: it has no thread and no project path");
      const res = await exec("git", ["-C", repo, "log", "--all", "--no-color", "--format=%H%x09%s", `--grep=Foreman run ${this.runId} phase`], { timeout: 20000 });
      if (res.code !== 0) throw new Error(firstLine(res.stderr) || `git exited ${res.code}`);
      this.gitIdx = { at, repo, commits: M.parsePhaseCommits(res.stdout, this.runId) };
    } catch (e) {
      this.gitIdx = { at, error: firstLine(e?.message ?? e) };
    }
    return this.gitIdx;
  }

  // A phase's report read from where the server cannot be asked for it: how a report is shown when the server cannot
  // serve it (no /artifacts route, or its file is gone with the worktree). In order: a phase with no `artifact:`
  // template wrote it to ~/.foreman/runs/<run id>/phase-<n>.md (never reclaimed), the server's archive copy of it, then
  // the commit Foreman made for the phase (or, for a phase that declared `commit: false`, the later phase's commit that
  // carried its work). Only ever reads; the text is shown as plain text.
  async loadGitReport(row, force = false) {
    const cur = this.gitReports.get(row.key);
    if (cur && !force && (cur.status === "loading" || cur.status === "done" || Date.now() - cur.at < SIDE_EVERY_MS)) return;
    this.gitReports.set(row.key, { status: "loading", at: Date.now() });
    let diskNote = "";
    try {
      if (RUN_ID.test(this.runId) && Number.isInteger(row.index)) {
        for (const { source, path } of M.reportCandidates(home(), this.runId, row.index, row.reportName)) {
          let text = null;
          try { text = await readTextFile(path); } catch (e) { diskNote = ` (could not read ${path}: ${firstLine(e?.message ?? e)})`; }
          if (text === null) continue;
          const shown = text.length > REPORT_CAP ? text.slice(0, REPORT_CAP) : text;
          const file = { path, bytes: M.utf8Bytes(text), text: shown, truncated: text.length > REPORT_CAP, rows: M.markdownRows(shown) };
          this.gitReports.set(row.key, { status: "done", at: Date.now(), source, sha: null, via: null, repo: null, files: [file], reason: null });
          return;
        }
      }
      const idx = await this.loadGitIndex(force);
      if (idx.error) throw new Error(idx.error);
      const names = async (commit) => {
        const res = await exec("git", ["-c", "core.quotepath=off", "-C", idx.repo, "diff-tree", "--no-commit-id", "--name-only", "-r", "--root", commit], { timeout: 15000 });
        if (res.code !== 0) throw new Error(firstLine(res.stderr) || `git diff-tree exited ${res.code}`);
        return res.stdout;
      };
      const own = idx.commits.get(row.index) ?? null;
      const { sha, via, paths } = await M.pickReportCommit(idx.commits, row.index, row.reportName, names);
      const done = (reason, files = []) => this.gitReports.set(row.key, { status: "done", at: Date.now(), source: "git", repo: idx.repo, sha, via, files, reason });
      if (paths.length === 0) {
        return done(own === null
          ? `Not in git: no commit "Foreman run ${this.runId} phase ${row.index}" in ${idx.repo}${row.reportName ? `, and no later phase's commit holds ${row.reportName}` : ""}. A report that was never committed is a file under ~/.foreman/runs/${this.runId}/ that only a server with the /artifacts route can serve${diskNote}.`
          : `Not in git: the phase's commit ${own.slice(0, 10)} holds no report file${row.reportName ? ` (the workflow names it ${row.reportName}), and no later phase's commit holds it` : ""}${diskNote}.`);
      }
      const files = [];
      for (const path of paths.slice(0, 3)) {
        const res = await exec("sh", ["-c", GIT_BLOB, "sh", idx.repo, sha, path], { timeout: 20000 });
        if (res.code !== 0) throw new Error(firstLine(res.stderr) || `git exited ${res.code} reading ${path}`);
        const blob = M.parseBlob(res.stdout, REPORT_CAP);
        if (!blob) throw new Error(`unexpected git output reading ${path}`);
        files.push({ path, ...blob, rows: M.markdownRows(blob.text) });
      }
      return done(null, files);
    } catch (e) {
      this.gitReports.set(row.key, { status: "failed", at: Date.now(), warn: firstLine(e?.message ?? e) });
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
      this.changes = { state: "error", reason: errLine(e) };
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

  // ------------------------------------------------------------------------------------ actions

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
        this.diffs.set(path, { error: errLine(e) });
      }
      cx.notify();
    });
  }

  openUrl(url) {
    if (!/^https?:\/\//.test(url ?? "")) return notify({ title: "Foreman", body: "That is not a web address.", level: "info" });
    exec(...openUrlArgv(url), { timeout: 10000 }).catch((e) =>
      notify({ title: "Foreman", body: `Could not open ${url}: ${errLine(e)}`, level: "error" }));
  }

  openPr() {
    const url = this.run && prUrl(this.run);
    if (!url) return notify({ title: "Foreman", body: "This run has no pull request.", level: "info" });
    this.openUrl(url);
  }

  openRaw() {
    run("tab.new", { name: `raw ${this.runId.slice(0, 20)}`, argv: foremanArgv(["run", "get", this.runId]) });
  }

  // A report is opened in the default app only when it is an absolute path to a document.
  openFile(path) {
    if (typeof path !== "string" || !path.startsWith("/") || !OPENABLE.test(path)) {
      return notify({ title: "Foreman", body: "Only a document's absolute path is opened; the path was copied instead.", level: "info" });
    }
    const [cmd, args] = openUrlArgv(path);
    exec(cmd, args, { timeout: 10000 }).catch((e) => notify({ title: "Foreman", body: `Could not open ${path}: ${errLine(e)}`, level: "error" }));
  }

  copy(text, what, cx) {
    cx.write_to_clipboard(text);
    notify({ title: "Foreman", body: `Copied ${what}`, level: "success", timeout: 2000 });
  }

  setFollow(on, cx) {
    this.follow = on;
    if (on) this.pendingScroll = true;
    cx.notify();
  }

  setTab(tab, cx) {
    this.tab = tab;
    if (tab === "activity" && this.follow) this.pendingScroll = true;
    else this.pendingTop = true;
    cx.notify();
  }

  setFilter(id, cx) {
    this.filter = id;
    if (this.follow) this.pendingScroll = true;
    cx.notify();
  }

  // Opens a phase in the Phases tab and scrolls to it (a click on a phase anywhere else).
  gotoPhase(row, cx) {
    if (!row.started) return;
    this.openPhases.add(row.key);
    this.tab = "phases";
    this.jumpTo = row.key;
    cx.spawn(async (cx) => { await this.ensureReport(row, this.reports.get(row.phaseId)?.status === "failed"); cx.notify(); });
    cx.notify();
  }

  togglePhase(row, cx) {
    if (this.openPhases.delete(row.key)) return cx.notify();
    this.openPhases.add(row.key);
    cx.notify();
    cx.spawn(async (cx) => { await this.ensureReport(row, this.reports.get(row.phaseId)?.status === "failed"); cx.notify(); });
  }

  toggle(set, key, cx) {
    if (!set.delete(key)) set.add(key);
    cx.notify();
  }

  // Why the feed is empty: nothing was written, or only blank chunks were (the log can be full of them).
  noOutput(finished) {
    if (this.blank > 0) return `No readable output: the log holds only ${this.blank} blank chunk${this.blank === 1 ? "" : "s"}${finished ? "" : " so far"}.`;
    return finished ? "This run produced no output." : "No output yet. The agent has not written anything.";
  }

  // ------------------------------------------------------------------------------------ rendering

  render() {
    const th = theme();
    const now = Date.now();
    const r = this.run;
    const rows = r ? M.buildPhaseRows(r, this.phases, r.workflow_snapshot?.phases, this.artifactMap, now) : [];
    const finished = !!r && M.isFinished(r);
    const vm = {
      th, now, r, rows, finished, anchors: {},
      outcome: r ? M.outcomeOf(r, rows, this.turns, now) : null,
      status: r ? M.nowSummary(r, rows, this.turns, now) : null,
    };
    const tab = this.tab ?? "overview";

    // ---- body (direct children of the scroll area, flat, so scroll_to_item can reach any row)
    let body;
    if (!this.loaded) body = [note(th, "Loading…")];
    else if (!r) body = [note(th, this.error ?? "Run not found", "blocked")];
    else if (tab === "overview") body = this.overviewRows(vm);
    else if (tab === "activity") body = this.activityRows(vm);
    else if (tab === "phases") body = this.phasesRows(vm);
    else if (tab === "pr") body = this.prRows(vm);
    else body = this.changesRows(vm);
    if (this.jumpTo !== null && vm.anchors[this.jumpTo] !== undefined) {
      this.scroll.scroll_to_item(vm.anchors[this.jumpTo]);
      this.jumpTo = null;
    } else if (this.pendingScroll && tab === "activity" && body.length > 0) {
      this.pendingScroll = false;
      this.scroll.scroll_to_item(body.length - 1);
    } else if (this.pendingTop && body.length > 0) {
      this.pendingTop = false;
      this.scroll.scroll_to_item(0);
    }

    return v_flex().id("foreman-run").size_full().bg(th.chrome)
      .child(this.headerRows(vm))
      .child(this.tabBar(vm, tab))
      // The wheel handler sits on a wrapper, never on the scroll area: gpui-kit documents
      // on_scroll_wheel as the gesture for something other than scrolling, and putting it on the
      // scroll container itself can take the wheel away from it. Reading back through the output
      // (an upward wheel) stops the auto-follow; "follow" turns it on again.
      .child(v_flex().id("foreman-run-wheel").flex_1().min_h(0)
        .on_scroll_wheel((e, cx) => { if (this.follow && tab === "activity" && e.delta?.y > 0) { this.follow = false; cx.notify(); } })
        .child(v_flex().id("foreman-run-scroll").size_full().overflow_y_scrollbar().track_scroll(this.scroll)
          .children(body)))
      .when(this.error && r, (el) => el.child(div().px(12).py(4).text_size(11).text_color(th.blocked).border_t(1).border_color(th.border).child(`foreman: ${this.error}`)));
  }

  // ---- the header: always visible. Title, where it is, how it is doing right now (or how it ended),
  // the phase strip and whatever needs attention.
  headerRows(vm) {
    const { th, now, r, rows } = vm;
    const st = statusInfo(r?.status);
    const pill = (id, label, handler) => chip(th, id, label, false, handler);
    const usage = r?.usage;
    const elapsed = r ? M.runElapsed(r, now) : null;
    const metrics = [
      elapsed !== null && `elapsed ${M.span(elapsed)}`,
      r?.base_branch && `base ${r.base_branch}`,
      usage && `${M.compact(usage.input_tokens)} in · ${M.compact(usage.output_tokens)} out${usage.cache_read_tokens ? ` · ${M.compact(usage.cache_read_tokens)} cached` : ""}`,
      usage && usage.cost_usd > 0 && `$${usage.cost_usd.toFixed(2)}`,
      !vm.finished && r?.provider_sessions?.length && r.provider_sessions[r.provider_sessions.length - 1].model,
    ].filter(Boolean).join("   ·   ");
    const where = [this.runId, r?.project_id, this.thread?.branch].filter(Boolean).join("  ·  ");
    const bead = r ? beadId(r) : null;

    const top = v_flex().gap(2).px(12).pt(10).pb(4)
      .child(h_flex().gap(8).items_center()
        .child(div().size(8).rounded(4).bg(col(th, st.color)))
        .child(div().text_size(13).font_semibold().text_color(col(th, st.color)).child(st.label))
        .child(div().text_size(13).font_semibold().text_color(th.foreground).child(r ? workflowName(r) : "run"))
        .when(bead, (el) => el.child(pill("bead", bead, (_e, cx) => this.copy(bead, `bead id ${bead}`, cx))))
        .child(div().flex_1().truncate().text_size(12).text_color(th.muted).child(this.thread?.title ?? r?.task_id ?? ""))
        .when(r && prUrl(r), (el) => el.child(pill("pr", "PR ↗", () => this.openPr())))
        .child(pill("raw", "raw", () => this.openRaw()))
        .when(this.updatedAt > 0, (el) => el.child(div().text_size(11).text_color(this.error ? th.blocked : th.dim).child(clock(this.updatedAt))))
        .child(div().id("refresh").px(5).rounded(4).cursor_pointer().text_size(13).text_color(this.refreshing ? th.working : th.muted)
          .hover((s) => s.bg(th.hover)).on_click((_e, cx) => this.refresh(cx, true)).child("↻")))
      .child(div().id("copy-id").truncate().text_size(11).text_color(th.dim).cursor_pointer()
        .on_click((_e, cx) => this.copy(this.runId, this.runId, cx)).child(where))
      .when(r, (el) => el.child(this.nowLine(vm)))
      .when(metrics, (el) => el.child(div().text_size(11).text_color(th.muted).child(metrics)));

    const strip = rows.length === 0 ? null
      : h_flex().px(12).py(3).gap_x(14).gap_y(2).flex_wrap().items_center()
        .children(rows.map((p, i) => {
          const [glyph, color] = M.PHASE_GLYPH[p.state];
          return h_flex().id(`strip-${p.key}`).gap(4).items_center()
            .when(p.started, (el) => el.cursor_pointer().on_click((_e, cx) => this.gotoPhase(p, cx)))
            .child(div().text_size(12).text_color(col(th, color)).child(glyph))
            .child(div().text_size(12).font_semibold().text_color(p.state === "running" ? th.foreground : th.muted).child(p.name))
            .when(p.attempt > 1, (el) => el.child(div().text_size(11).text_color(th.idle).child(`×${p.attempt}`)))
            .when(i < rows.length - 1, (el) => el.child(div().text_size(11).text_color(th.dim).child("›")));
        }));

    const w = this.warn;
    const warnBanner = (what, x) => x && banner(th, `${what}: ${x.text}`, x.kind === "failed" ? "blocked" : "dim");
    const alerts = [
      r?.status === "failed" && r.failure_reason && banner(th, `Failed: ${M.oneLine(r.failure_reason)}`, "blocked"),
      r?.latest_stall && banner(th, `Stalled: ${M.stallText(r.latest_stall)}`, "blocked"),
      ...this.approvals.map((a) => banner(th, `Waiting for your approval: ${a.tool_name}${a.input_summary ? ` — ${M.oneLine(a.input_summary, 140)}` : ""}`, "idle")),
      ...this.questions.map((q) => banner(th, `Asks: ${M.oneLine(q.text ?? "(no text)", 200)}`, "idle")),
      warnBanner("Could not read approvals/questions", w.waiting),
      warnBanner("Could not read the transcript", w.thread?.kind === "absent" && w.transcript?.kind === "absent" ? null : w.transcript),
      warnBanner("Phase status unavailable", w.phases),
      warnBanner("Thread (title, branch) unavailable", w.thread),
    ].filter(Boolean);

    return v_flex().child(top).when(strip, (el) => el.child(strip)).children(alerts);
  }

  // The always-visible status line: the phase it is in and for how long, how long it has been quiet and
  // the newest thing the agent said; for a finished run, the outcome in its place.
  nowLine(vm) {
    const { th, now, r } = vm;
    const row = (kids) => h_flex().gap(8).items_center().flex_wrap().children(kids.filter(Boolean));
    const t = (s, color, semi = false) => div().text_size(12).when(semi, (el) => el.font_semibold()).text_color(col(th, color)).child(String(s));
    if (vm.finished) {
      const o = vm.outcome;
      const pr = this.prSum?.[0] ?? null;
      return row([
        t(`${o.glyph} ${r.status}`, TONE[o.tone], true),
        o.elapsedMs !== null && t(`in ${M.span(o.elapsedMs)}`, "muted"),
        o.phase && r.status !== "completed" && t(`at ${o.phase.name}${o.phase.attempt > 1 ? ` (attempt ${o.phase.attempt})` : ""}`, "muted"),
        o.total > 0 && t(`${o.done}/${o.total} phases done`, "muted"),
        pr && t(`PR #${pr.number ?? "?"} ${pr.status ?? ""}${pr.gate ? ` · gate ${pr.gate}` : ""}`.trim(), TONE[pr.overall.tone]),
        !pr && this.warn.prs && t("PR status unavailable", "blocked"),
      ]);
    }
    const s = vm.status;
    const phase = s.phase;
    const head = phase
      ? [
        t(`${s.paused ? "Ⅱ paused in" : "▶"} ${phase.name}`, s.paused ? "idle" : "working", true),
        phase.attempt > 1 && t(`attempt ${phase.attempt}`, "idle"),
        s.inPhaseMs !== null && t(`in phase ${M.span(s.inPhaseMs)}`, "muted"),
        s.phaseCount > 0 && t(`phase ${s.phaseNumber} of ${s.phaseCount}`, "dim"),
      ]
      : [t(s.paused ? "Ⅱ paused" : s.starting ? "○ starting: no phase has started yet" : "▶ running: no phase is running right now", s.paused ? "idle" : "working", true)];
    const quiet = s.quietMs === null ? null
      : t(`last event ${M.span(s.quietMs)} ago${s.quietMs >= M.STALE_WARN_MS ? " (quiet)" : ""}`, s.tone === "bad" ? "blocked" : s.tone === "warn" ? "idle" : "muted");
    const tail = s.tail;
    const tailRow = h_flex().gap(6).items_center()
      .when(!tail, (el) => el.child(div().text_size(12).text_color(th.dim).child(this.noOutput(false))))
      .when(!!tail, (el) => el
        .child(div().text_size(11).font_semibold().text_color(col(th, tail.color)).child(tail.tag))
        .child(div().flex_1().min_w(0).truncate().text_size(12).text_color(tail.thinking ? th.dim : th.foreground).child(M.truncate(tail.text, TAIL_CHARS)))
        .when(tail.atMs !== null, (e) => e.child(div().text_size(11).text_color(th.dim).child(`${M.span(now - tail.atMs)} ago`))));
    return v_flex().gap(1)
      .child(row([...head, div().flex_1(), quiet]))
      .child(tailRow);
  }

  tabBar(vm, tab) {
    const { th, rows } = vm;
    const done = rows.filter((p) => p.state === "done").length;
    const files = this.changes?.state === "ok" ? this.changes.files.length + this.changes.untracked.length : null;
    const prs = this.prSum;
    const labels = {
      overview: "Overview",
      activity: `Activity${this.turns.length ? ` (${this.turns.length + this.dropped})` : ""}`,
      phases: `Phases${rows.length ? ` (${done}/${rows.length})` : ""}`,
      changes: `Changes${files !== null ? ` (${files})` : ""}`,
      pr: `PR${prs ? ` (${prs.length})` : ""}${prs?.some((p) => p.overall.tone === "bad") ? " ✕" : ""}`,
    };
    const tabs = h_flex().px(8).py(3).gap(4).items_center().border_t(1).border_b(1).border_color(th.border)
      .children(TABS.map(([id]) => chip(th, `tab-${id}`, labels[id], tab === id, (_e, cx) => this.setTab(id, cx))));
    if (tab !== "activity") return tabs;
    const counts = M.filterCounts(this.turns);
    const filters = h_flex().px(8).py(3).gap(4).items_center().border_b(1).border_color(th.border)
      .children(M.FILTERS.map((f) => chip(th, `filter-${f.id}`, `${f.label}${counts[f.id] ? ` ${counts[f.id]}` : ""}`, this.filter === f.id, (_e, cx) => this.setFilter(f.id, cx))))
      .child(div().flex_1())
      .child(chip(th, "follow", this.follow ? "following" : "jump to latest", this.follow, (_e, cx) => this.setFollow(!this.follow, cx)));
    return v_flex().child(tabs).child(filters);
  }

  // ---- Overview: how it ended (or what it is doing), what waits on you, the phases, the PR, recent events.
  overviewRows(vm) {
    const { th, now, r, rows } = vm;
    const out = [this.outcomeCard(vm)];
    const needs = [
      ...this.approvals.map((a, i) => v_flex().id(`need-a-${i}`).px(12).py(3).gap(1)
        .child(div().text_size(12).font_semibold().text_color(th.idle).child(`! Approval: ${a.tool_name}`))
        .when(a.input_summary, (el) => el.child(div().text_size(12).text_color(th.muted).child(M.oneLine(a.input_summary, 300))))
        .child(div().text_size(11).text_color(th.dim).child(`${Number.isFinite(Date.parse(a.requested_at)) ? `waiting ${M.span(now - Date.parse(a.requested_at))} · ` : ""}foreman approvals approve|deny --run ${this.runId} --call ${a.tool_call_id}`))),
      ...this.questions.map((q, i) => v_flex().id(`need-q-${i}`).px(12).py(3).gap(1)
        .child(div().text_size(12).font_semibold().text_color(th.idle).child("? The agent asks"))
        .child(div().text_size(12).text_color(th.muted).child(M.truncate(String(q.text ?? "(no text)"), 600)))
        .child(div().text_size(11).text_color(th.dim).child(`foreman questions answer --run ${this.runId} --question ${q.question_id ?? "<id>"} --text "…"`))),
    ];
    if (this.warn.waiting) needs.push(note(th, `Could not read approvals/questions: ${this.warn.waiting.text}`, "blocked"));
    if (needs.length) out.push(heading(th, "Needs you"), ...needs);

    out.push(heading(th, "Phases"));
    if (rows.length === 0) out.push(note(th, this.warn.phases ? "The phase list could not be read (see above)." : "No phases yet."));
    for (const p of rows) out.push(this.phaseTableRow(p, vm));

    out.push(heading(th, "Pull request"), ...this.prOverviewRows(vm));

    out.push(heading(th, "Recent events"));
    const events = M.notableEvents(r, rows, this.turns, now);
    if (events.length === 0) out.push(note(th, "Nothing has happened yet."));
    events.forEach((e, i) => out.push(h_flex().id(`ev-${i}`).px(12).py(1).gap(8).items_start()
      .child(div().w(54).flex_none().text_size(10.5).text_color(th.dim).child(clock(e.at)))
      .child(div().w(12).flex_none().text_size(12).text_color(col(th, e.tone)).child(e.glyph))
      .child(div().flex_1().min_w(0).text_size(12).text_color(col(th, e.tone === "dim" || e.tone === "muted" ? e.tone : "foreground")).child(e.text))));
    return out;
  }

  outcomeCard(vm) {
    const { th, now, r } = vm;
    const kids = [];
    const line = (s, color = "muted", size = 12) => div().text_size(size).text_color(col(th, color)).child(String(s));
    if (vm.finished) {
      const o = vm.outcome;
      const title = { completed: "Completed", failed: "Failed", cancelled: "Cancelled", blocked: "Blocked", stuck: "Stuck" }[r.status] ?? r.status;
      kids.push(h_flex().gap(8).items_center().flex_wrap()
        .child(div().text_size(14).font_semibold().text_color(col(th, TONE[o.tone])).child(`${o.glyph} ${title}`))
        .when(o.elapsedMs !== null, (el) => el.child(line(`in ${M.span(o.elapsedMs)}`)))
        .when(!!o.phase && r.status !== "completed", (el) => el.child(line(`at phase ${o.phase.name}${o.phase.attempt > 1 ? ` (attempt ${o.phase.attempt})` : ""}`))));
      if (o.reason) {
        const open = this.expanded.has("outcome");
        const full = o.reason.slice(0, REASON_CHARS);
        const shown = open ? full : full.split("\n").slice(0, REASON_LINES).join("\n").slice(0, 600);
        const long = shown.length < o.reason.length;
        kids.push(div().text_size(12).text_color(o.tone === "bad" ? th.blocked : th.muted).child(shown + (long && !open ? " …" : "")));
        kids.push(h_flex().gap(6)
          .when(long, (el) => el.child(chip(th, "outcome-more", open ? "show less" : "show more", false, (_e, cx) => this.toggle(this.expanded, "outcome", cx))))
          .child(chip(th, "outcome-copy", "copy", false, (_e, cx) => this.copy(o.reason, "the reason", cx)))
          .when(o.reasonFrom === "transcript", (el) => el.child(div().py(2).text_size(11).text_color(th.dim).child("from the run's status turn"))));
      } else if (r.status !== "completed") {
        kids.push(line("The server recorded no reason.", "dim"));
      }
      if (o.stall) kids.push(line(`stall: ${M.stallText(o.stall)}`, "blocked"));
      const failed = vm.rows.filter((p) => p.state === "failed").length;
      const notRun = vm.rows.filter((p) => p.state === "skipped" || p.state === "pending").length;
      kids.push(line(`${r.started_at_ms ? `started ${clock(r.started_at_ms)}` : ""}${r.last_event_at_ms ? `  ·  last event ${clock(r.last_event_at_ms)}` : ""}  ·  ${o.done} done${failed ? ` · ${failed} failed` : ""}${notRun ? ` · ${notRun} not run` : ""}`, "dim", 11));
      const pr = this.prSum?.[0];
      if (pr) {
        kids.push(h_flex().gap(6).items_center()
          .child(line(`PR #${pr.number ?? "?"}  ${pr.status ?? "?"}${pr.gate ? `  ·  merge gate ${pr.gate}` : ""}  ·  eligibility ${pr.eligibility.status}  ·  ${pr.overall.text}`, TONE[pr.overall.tone === "dim" ? "muted" : pr.overall.tone]))
          .child(chip(th, "outcome-pr", "details", false, (_e, cx) => this.setTab("pr", cx))));
      } else if (this.warn.prs) kids.push(line(`PR status unavailable: ${this.warn.prs.text}`, this.warn.prs.kind === "missing_route" ? "dim" : "blocked"));
      else if (prUrl(r)) kids.push(line("PR evidence has not been read yet.", "dim", 11));
      else if (r.status === "completed") kids.push(line("No pull request.", "dim", 11));
    } else {
      const s = vm.status;
      kids.push(line(s.phase ? `${s.paused ? "Ⅱ Paused in" : "▶ Running"} ${s.phase.name}${s.inPhaseMs !== null ? ` for ${M.span(s.inPhaseMs)}` : ""}` : s.paused ? "Ⅱ Paused" : "○ Waiting to start", s.paused ? "idle" : "working", 14));
      kids.push(line(s.quietMs === null ? "No event has been recorded yet." : `Last event ${M.span(s.quietMs)} ago.${s.quietMs >= M.STALE_WARN_MS ? " The run has been quiet for a while." : ""}`, s.tone === "bad" ? "blocked" : s.tone === "warn" ? "idle" : "muted"));
      if (s.stall) kids.push(line(`stall: ${M.stallText(s.stall)}`, "blocked"));
      const newest = this.turns[this.turns.length - 1];
      if (newest) {
        const fold = M.foldSegments(newest.segs, REASON_LINES, 900);
        kids.push(line(`Newest output (${newest.tag}${newest.atMs !== null ? `, ${M.span(now - newest.atMs)} ago` : ""}):`, "dim", 11));
        kids.push(...segDivs(th, fold.segs, 0, newest.color));
        if (fold.hidden > 0) kids.push(div().text_size(11).text_color(th.dim).child(`… ${fold.hidden} more lines in Activity`));
      } else kids.push(line(this.noOutput(false), "dim"));
    }
    return v_flex().id("outcome").mx(12).mt(10).px(12).py(8).gap(3).rounded(6).bg(th.surface).children(kids);
  }

  phaseTableRow(p, vm) {
    const { th } = vm;
    const [glyph, color] = M.PHASE_GLYPH[p.state];
    const report = p.artifactState === "present" ? M.bytesText(p.artifact.bytes) : p.artifactState === "unknown" ? "?" : "—";
    return h_flex().id(`ov-${p.key}`).px(12).py(3).gap(8).items_center().hover((s) => s.bg(th.hover))
      .when(p.started, (el) => el.cursor_pointer().on_click((_e, cx) => this.gotoPhase(p, cx)))
      .child(div().w(14).flex_none().text_size(12).text_color(col(th, color)).child(glyph))
      .child(div().w(168).flex_none().truncate().text_size(12).font_semibold().text_color(p.state === "running" ? th.foreground : th.muted).child(p.name))
      .child(div().w(30).flex_none().text_size(11).text_color(th.idle).child(p.attempt > 1 ? `×${p.attempt}` : ""))
      .child(div().w(62).flex_none().text_size(11).text_color(th.muted).child(p.durationMs !== null ? M.span(p.durationMs) : ""))
      .child(div().w(62).flex_none().text_size(11).text_color(th.dim).child(report))
      .child(div().flex_1().min_w(0).truncate().text_size(11).text_color(p.state === "failed" ? th.blocked : th.dim)
        .child(p.reason ? M.oneLine(p.reason, 200) : p.state === "failed" || p.state === "other" ? p.label : ""));
  }

  // ---- the PR evidence, in one block per PR on the Overview and in full on the PR tab.
  prOverviewRows(vm) {
    const { th, r } = vm;
    const out = [];
    const w = this.warn.prs;
    if (w) out.push(note(th, `PR evidence unavailable: ${w.text}`, w.kind === "missing_route" ? "dim" : "blocked"));
    if (!this.prSum) {
      if (!w) out.push(note(th, "Loading…"));
      return out;
    }
    if (this.prSum.length === 0) {
      out.push(note(th, prUrl(r) ? "The server has not observed this run's pull request yet (no PR watch record)." : "This run has no pull request."));
      return out;
    }
    this.prSum.forEach((p, i) => {
      const lines = [
        h_flex().gap(8).items_center()
          .child(div().text_size(12).font_semibold().text_color(th.foreground).child(`#${p.number ?? "?"}`))
          .child(div().text_size(12).text_color(th.muted).child(`${p.status ?? "?"}${p.gate ? ` · merge gate ${p.gate}` : ""}`))
          .child(div().text_size(12).font_semibold().text_color(col(th, TONE[p.overall.tone])).child(p.overall.text)),
        div().text_size(12).text_color(th.muted).child(`checks: ${checksText(p)}   ·   review: ${p.review.decision ?? "none"}${p.review.comments ? ` · ${p.review.comments} comments` : ""}`),
        div().text_size(12).text_color(p.eligibility.status === "ineligible" ? th.blocked : th.muted)
          .child(`eligibility: ${p.eligibility.status}${p.eligibility.reasons.length ? ` — ${p.eligibility.reasons.map(reasonText).join("; ")}` : ""}`),
        div().text_size(12).text_color(th.muted).child(`findings: ${findingsText(p)}   ·   risk: ${p.risk?.level ?? "not recorded"}`),
        p.nextActions.length > 0 && div().text_size(12).text_color(th.idle).child(`next: ${p.nextActions.map((a) => `${a.action}${a.command ? ` (${a.command})` : ""}`).join(", ")}`),
      ].filter(Boolean);
      out.push(v_flex().id(`ovpr-${i}`).px(12).py(4).gap(1).cursor_pointer().hover((s) => s.bg(th.hover))
        .on_click((_e, cx) => this.setTab("pr", cx)).children(lines));
    });
    return out;
  }

  prRows(vm) {
    const { th, r } = vm;
    const out = [];
    const w = this.warn.prs;
    if (w) out.push(note(th, `Could not read the PR evidence: ${w.text}`, w.kind === "missing_route" ? "idle" : "blocked"));
    if (w && this.prSum) out.push(note(th, `Showing what the server answered at ${clock(this.prsOkAt)}; it may be old.`, "dim"));
    if (!this.prSum) {
      if (!w) out.push(note(th, "Loading…"));
      else if (prUrl(r)) out.push(h_flex().px(12).py(4).child(chip(th, "pr-open", "Open PR ↗", false, () => this.openPr())));
      return out;
    }
    if (this.prSum.length === 0) {
      out.push(note(th, prUrl(r) ? "The server has not observed this run's pull request yet: there is no PR watch record, so there are no checks, findings or risk to show." : "This run has no pull request."));
      if (prUrl(r)) out.push(h_flex().px(12).py(4).child(chip(th, "pr-open", "Open PR ↗", false, () => this.openPr())));
      return out;
    }
    this.prSum.forEach((p, i) => out.push(...this.prDetail(p, i, vm)));
    return out;
  }

  prDetail(p, i, vm) {
    const { th } = vm;
    const out = [];
    const dim = (s) => div().px(12).py(1).text_size(11).text_color(th.dim).child(String(s));
    const item = (s, color = "foreground", pad = 24) => div().pl(pad).pr(12).py(1).text_size(12).text_color(col(th, color)).child(String(s));
    out.push(h_flex().id(`pr-head-${i}`).px(12).pt(10).pb(2).gap(8).items_center().flex_wrap()
      .child(div().text_size(14).font_semibold().text_color(th.foreground).child(`PR #${p.number ?? "?"}`))
      .child(div().text_size(12).text_color(th.muted).child(p.status ?? "status unknown"))
      .child(div().text_size(12).font_semibold().text_color(col(th, TONE[p.overall.tone])).child(p.overall.text))
      .child(div().flex_1())
      .child(chip(th, `pr-open-${i}`, "Open PR ↗", false, () => this.openUrl(p.url)))
      .child(chip(th, `pr-copy-${i}`, "copy URL", false, (_e, cx) => this.copy(p.url, "the PR URL", cx))));
    out.push(dim(`${p.url}${p.base ? `  ·  base ${p.base}` : ""}${p.branch ? `  ·  ${p.branch}` : ""}${p.headSha ? `  ·  head ${p.headSha.slice(0, 8)}` : ""}${p.watching ? "  ·  watching" : p.stopReason ? `  ·  watch stopped: ${p.stopReason}` : ""}`));

    out.push(heading(th, "Checks"));
    if (!p.checks.observed) out.push(note(th, `No checks have been observed for this head${p.checks.state ? ` (the watch says ${p.checks.state})` : ""}. That is not the same as passing.`, "idle"));
    else {
      out.push(div().px(12).py(1).text_size(12).text_color(th.muted).child(checksText(p) + [p.checks.old ? "  ·  the observation is older than 15 minutes" : "", p.checks.stale ? "  ·  for another head" : "", p.checks.truncated ? "  ·  list truncated" : ""].join("")));
      p.checks.items.forEach((c, k) => out.push(h_flex().id(`pr-check-${i}-${k}`).pl(24).pr(12).py(1).gap(8).items_start()
        .child(div().w(12).flex_none().text_size(12).text_color(col(th, TONE[c.tone])).child(c.tone === "ok" ? "✓" : c.tone === "bad" ? "✕" : c.tone === "pending" ? "◌" : "?"))
        .child(div().flex_1().min_w(0).text_size(12).text_color(c.tone === "bad" ? th.blocked : th.foreground).child(c.name))
        .child(div().flex_none().text_size(11).text_color(th.dim).child([c.state, c.conclusion].filter(Boolean).join(" · ")))));
      const listed = new Set(p.checks.items.map((c) => c.name));
      const extra = p.checks.failing.filter((n) => !listed.has(n));
      if (extra.length) out.push(item(`failing: ${extra.join(", ")}`, "blocked"));
    }

    out.push(heading(th, "Review and fixes"));
    out.push(kv(th, "review", `${p.review.decision ?? "no decision"}${p.review.comments ? ` · ${p.review.comments} comments` : ""}`));
    const att = p.fixes.attempts;
    out.push(kv(th, "fix attempts", Object.keys(att).length ? Object.keys(att).map((k) => `${k} ${att[k]}`).join(" · ") : "none"));
    if (p.fixes.inFlight) out.push(kv(th, "fix in flight", `${p.fixes.inFlight.kind ?? "?"} attempt ${p.fixes.inFlight.attempt ?? "?"} (${p.fixes.inFlight.state})`, "working"));
    for (const k of Object.keys(p.fixes.lastOutcome)) out.push(kv(th, `last ${k} fix`, String(p.fixes.lastOutcome[k])));
    for (const k of Object.keys(p.fixes.exhausted)) out.push(kv(th, `${k} fixes`, `gave up (${String(p.fixes.exhausted[k])})`, "blocked"));

    out.push(heading(th, "Merge gate and eligibility"));
    out.push(kv(th, "merge gate", p.gate ?? "not this run's gated PR"));
    out.push(kv(th, "eligibility", p.eligibility.status, p.eligibility.status === "ineligible" ? "blocked" : p.eligibility.status === "unknown" ? "idle" : "foreground"));
    p.eligibility.reasons.forEach((x) => out.push(item(`• ${reasonText(x)}`, p.eligibility.status === "ineligible" ? "blocked" : "muted")));
    p.eligibility.waived.forEach((x) => out.push(item(`waived: ${reasonText(x)}`, "idle")));
    if (p.waiver) out.push(kv(th, "waiver", `${p.waiver.codes.join(", ") || "no codes"}${p.waiver.by ? ` by ${p.waiver.by}` : ""}${p.waiver.reason ? ` — ${M.oneLine(p.waiver.reason, 200)}` : ""}${p.waiver.applies === false ? ` (does not apply: ${p.waiver.ignoredBecause ?? "?"})` : ""}`, "idle"));

    out.push(heading(th, "Findings"));
    if (!p.findings.observed) out.push(note(th, "No review findings block has been recorded for this PR.", "idle"));
    else {
      const f = p.findings;
      out.push(kv(th, "status", `${f.status ?? "?"}${f.stale ? " (for another head)" : ""}${f.defect ? ` · defect ${f.defect}` : ""}`, f.defect ? "blocked" : "foreground"));
      if (f.defectDetail) out.push(item(f.defectDetail, "blocked", 24));
      out.push(kv(th, "findings", findingsText(p)));
      if (f.judgement) out.push(kv(th, "judgement", `${f.judgement.status ?? "?"}${f.judgement.level ? ` · ${f.judgement.level}` : ""}${f.judgement.defect ? ` · ${f.judgement.defect}` : ""}`));
      f.items.forEach((x, k) => out.push(v_flex().id(`pr-finding-${i}-${k}`).pl(24).pr(12).py(2).gap(0)
        .child(div().text_size(12).text_color(col(th, SEVERITY[x.severity] ?? "muted")).child(`${x.severity ?? "?"}${x.disposition ? ` · ${x.disposition}` : ""}${x.source ? ` · ${x.source}` : ""}`))
        .child(div().text_size(12).text_color(th.foreground).child(x.description ?? "(no description)"))
        .when(x.path, (el) => el.child(div().text_size(11).text_color(th.dim).child(`${x.path}${x.line ? `:${x.line}` : ""}`)))));
      if (f.listedTruncated) out.push(dim(`Only the first ${f.items.length} of ${f.total} findings are listed.`));
    }

    out.push(heading(th, "Risk"));
    if (!p.risk) out.push(note(th, "No risk assessment has been recorded for this PR.", "idle"));
    else {
      out.push(kv(th, "level", `${p.risk.level ?? "?"}${p.risk.stale ? " (for another head)" : ""}`, p.risk.level === "HIGH" ? "blocked" : p.risk.level === "MEDIUM" ? "idle" : p.risk.level === "LOW" ? "done" : "foreground"));
      p.risk.rationale.forEach((x) => out.push(item(`${x.level ?? "?"}  ${x.rule ?? "?"} — ${x.detail ?? ""}${x.basis ? ` (${x.basis})` : ""}`, x.level === "HIGH" ? "blocked" : x.level === "MEDIUM" ? "idle" : "muted")));
      p.risk.instructions.forEach((x) => out.push(item(`→ ${x}`, "muted")));
    }

    out.push(heading(th, "Agent review and report"));
    out.push(kv(th, "agent review", p.agentReview ? `${p.agentReview.verdict ?? "?"}${p.agentReview.gapBeads.length ? ` · ${p.agentReview.gapBeads.length} gaps (${p.agentReview.gapBeads.slice(0, 6).join(", ")}${p.agentReview.gapBeads.length > 6 ? ", …" : ""})` : ""}` : "none recorded", p.agentReview ? M.verdictTone(p.agentReview.verdict) : "dim"));
    out.push(kv(th, "report", p.report ? `${p.report.status ?? "?"}${p.report.stale ? " (stale)" : ""}${p.report.reason ? ` — ${p.report.reason}` : ""}` : "none recorded"));
    if (p.report?.commentUrl) out.push(item(p.report.commentUrl, "dim", 24));
    if (p.deliveryIssue) out.push(kv(th, "delivery issue", `${p.deliveryIssue.stage ?? "?"}: ${p.deliveryIssue.reason ?? "no reason"}`, "blocked"));

    out.push(heading(th, "Next actions"));
    if (p.nextActions.length === 0) out.push(dim("None offered."));
    p.nextActions.forEach((a) => out.push(item(`${a.action}${a.command ? ` → ${a.command}` : " (no command re-runs it)"}${a.codes.length ? `  [${a.codes.join(", ")}]` : ""}`, "foreground")));
    return out;
  }

  // ---- Activity: the live feed, filtered, grouped by phase.
  activityRows(vm) {
    const { th, rows } = vm;
    const out = [];
    if (this.dropped > 0) out.push(note(th, `${this.dropped} earlier turns are not shown.`));
    if (this.omitted > 0) out.push(note(th, `The server keeps only the newest part of a run's log: ${this.omitted} earlier log entries are not available.`));
    const turns = M.compressTurns(this.turns);
    let shown = 0;
    for (const g of M.groupTurns(turns, rows)) {
      const visible = g.turns.filter((t) => M.matchesFilter(t, this.filter));
      if (!g.row && visible.length === 0) continue;
      out.push(this.groupHeader(g, visible.length, vm));
      if (this.hiddenGroups.has(g.key)) continue;
      for (const t of visible) { out.push(this.renderTurn(t, th)); shown++; }
    }
    if (this.turns.length === 0) out.push(note(th, this.warn.transcript ? `No transcript: ${this.warn.transcript.text}.` : this.noOutput(vm.finished)));
    else if (shown === 0 && this.filter !== "all") out.push(note(th, "No turn matches this filter."));
    return out;
  }

  groupHeader(g, n, vm) {
    const { th, r } = vm;
    const p = g.row;
    const [glyph, color] = p ? M.PHASE_GLYPH[p.state] : ["·", "dim"];
    const open = !this.hiddenGroups.has(g.key);
    const when = p && p.durationMs !== null ? (p.state === "running" || p.state === "paused" ? `${p.label} ${M.span(p.durationMs)}` : `${p.label} · ${M.span(p.durationMs)}`) : p ? p.label : "before the first phase";
    return v_flex().id(`grp-${g.key}`).mx(12).mt(8).pt(4).border_t(1).border_color(th.border).pb(2)
      .child(h_flex().id(`grp-head-${g.key}`).gap(8).items_center().cursor_pointer()
        .on_click((_e, cx) => this.toggle(this.hiddenGroups, g.key, cx))
        .child(div().w(10).text_size(10).text_color(th.dim).child(open ? "▾" : "▸"))
        .child(div().text_size(12).text_color(col(th, color)).child(glyph))
        .child(div().text_size(12).font_semibold().text_color(th.foreground).child(p ? p.name : r ? "run" : ""))
        .when(!!p && p.attempt > 1, (el) => el.child(div().text_size(11).text_color(th.idle).child(`attempt ${p.attempt}`)))
        .child(div().text_size(11).text_color(th.dim).child(when))
        .child(div().flex_1())
        .child(div().text_size(11).text_color(th.dim).child(`${n} turn${n === 1 ? "" : "s"}`)))
      .when(!!p && !!p.reason && p.state === "failed", (el) => el.child(div().pl(28).text_size(11).text_color(th.blocked).child(M.oneLine(p.reason))));
  }

  renderTurn(t, th) {
    const open = this.expanded.has(t.key);
    const fold = M.foldSegments(t.segs, open ? Infinity : MAX_LINES, MAX_CHARS);
    const long = fold.total > MAX_LINES || t.text.length > MAX_CHARS;
    const at = t.atMs !== null ? clock(t.atMs) : "";
    if (t.kind === "verdict") return this.renderVerdict(t, th, open, at);
    return v_flex().id(`turn-${t.key}`).px(12).py(4).gap(1)
      .when(t.kind === "steer", (el) => el.bg(th.surface))
      .child(h_flex().gap(8).items_center()
        .child(div().w(54).text_size(10.5).text_color(th.dim).child(at))
        .child(div().w(40).text_size(10.5).font_semibold().text_color(col(th, t.color)).child(t.tag))
        .when(t.count > 1, (el) => el.child(div().text_size(10.5).text_color(th.dim).child(`×${t.count}`)))
        .when(t.fragments, (el) => el.child(div().text_size(10.5).text_color(th.idle).child("unmerged chunks"))))
      .children(segDivs(th, fold.segs, 102, t.color))
      .when(long, (el) => el.child(
        div().id(`turn-more-${t.key}`).pl(102).text_size(11).text_color(th.accent).cursor_pointer()
          .on_click((_e, cx) => this.toggle(this.expanded, t.key, cx))
          .child(open ? "show less" : fold.hidden > 0 ? `… ${fold.hidden} more lines` : "… show more")));
  }

  // A recorded review's verdict, prominent: a card with the verdict word in its colour.
  renderVerdict(t, th, open, at) {
    const tone = M.verdictTone(t.verdict.word);
    const lines = t.verdict.summary.split("\n");
    const long = lines.length > 10 || t.verdict.summary.length > 900;
    const shown = open ? t.verdict.summary.slice(0, MAX_CHARS) : lines.slice(0, 10).join("\n").slice(0, 900);
    return v_flex().id(`turn-${t.key}`).mx(12).my(4).px(10).py(6).gap(2).rounded(4).bg(th.surface).border_l(3).border_color(col(th, tone))
      .child(h_flex().gap(8).items_center()
        .child(div().text_size(10.5).text_color(th.dim).child(at))
        .child(div().text_size(12).font_semibold().text_color(col(th, tone)).child(`Review verdict: ${t.verdict.word.replace(/_/g, " ")}`)))
      .when(shown !== "", (el) => el.child(div().text_size(12).text_color(th.foreground).child(shown)))
      .when(long, (el) => el.child(
        div().id(`turn-more-${t.key}`).text_size(11).text_color(th.accent).cursor_pointer()
          .on_click((_e, cx) => this.toggle(this.expanded, t.key, cx)).child(open ? "show less" : "show more")));
  }

  // ---- Phases: one expandable section per phase, with its report from the server.
  phasesRows(vm) {
    const { th, rows } = vm;
    const out = [];
    const w = this.warn.artifacts;
    if (w) out.push(note(th, w.kind === "missing_route"
      ? "This server has no /api/runs/:id/artifacts route (HTTP 404), so each report is read from this machine instead (the run's files under ~/.foreman/runs, else the commit Foreman made for the phase): not checked against a recorded digest. Update the Foreman server for the recorded copies."
      : `Phase reports are unavailable: ${w.text}`, w.kind === "missing_route" ? "idle" : "blocked"));
    if (rows.length === 0) out.push(note(th, this.warn.phases ? "The phase list could not be read (see above)." : "No phases yet."));
    const groups = new Map(M.groupTurns(M.compressTurns(this.turns), rows).map((g) => [g.key, g]));
    for (const p of rows) {
      vm.anchors[p.key] = out.length;
      out.push(this.phaseHeader(p, vm));
      if (this.openPhases.has(p.key)) out.push(...this.phaseBody(p, groups.get(p.key), vm));
    }
    return out;
  }

  phaseHeader(p, vm) {
    const { th } = vm;
    const [glyph, color] = M.PHASE_GLYPH[p.state];
    const open = this.openPhases.has(p.key);
    const g = this.gitReports.get(p.key);
    const fromGit = g?.status === "done" ? (g.files.length > 0 ? `report ${M.bytesText(g.files[0].bytes)} · ${g.source}` : "not found") : g?.status === "loading" ? "report …" : "report ?";
    const report = p.artifactState === "present" ? `report ${M.bytesText(p.artifact.bytes)}` : p.artifactState === "unknown" ? fromGit : p.started && p.state === "done" ? "no report" : "";
    return h_flex().id(`ph-${p.key}`).px(12).py(5).mt(2).gap(8).items_center().hover((s) => s.bg(th.hover))
      .when(p.started, (el) => el.cursor_pointer().on_click((_e, cx) => this.togglePhase(p, cx)))
      .child(div().w(10).flex_none().text_size(10).text_color(th.dim).child(p.started ? (open ? "▾" : "▸") : ""))
      .child(div().w(14).flex_none().text_size(12).text_color(col(th, color)).child(glyph))
      .child(div().text_size(13).font_semibold().text_color(p.state === "pending" || p.state === "skipped" ? th.muted : th.foreground).child(p.name))
      .when(p.attempt > 1, (el) => el.child(div().text_size(11).text_color(th.idle).child(`×${p.attempt}`)))
      .child(div().text_size(11).text_color(th.muted).child(p.label))
      .when(p.durationMs !== null, (el) => el.child(div().text_size(11).text_color(th.muted).child(M.span(p.durationMs))))
      .child(div().flex_1().min_w(0).truncate().text_size(11).text_color(th.blocked).child(p.reason ? M.oneLine(p.reason, 160) : ""))
      .child(div().flex_none().text_size(11).text_color(p.artifactState === "unknown" ? th.idle : th.dim).child(report));
  }

  phaseBody(p, group, vm) {
    const { th } = vm;
    const out = [];
    const fact = (label, value, color = "foreground") => h_flex().pl(34).pr(12).py(1).gap(8).items_start()
      .child(div().w(70).flex_none().text_size(11).text_color(th.dim).child(label))
      .child(div().flex_1().min_w(0).text_size(12).text_color(col(th, color)).child(String(value)));
    const when = [p.startedAt !== null && `started ${clock(p.startedAt)}`, p.endedAt !== null && `ended ${clock(p.endedAt)}`, p.durationMs !== null && (p.endedAt !== null ? `took ${M.span(p.durationMs)}` : `running ${M.span(p.durationMs)}`)].filter(Boolean).join("  ·  ");
    if (when) out.push(fact("time", when));
    if (p.provider || p.model) out.push(fact("agent", [p.provider, p.model].filter(Boolean).join(" · ")));
    if (p.attempt > 1) out.push(fact("attempts", `${p.attempt} (the phase was retried; times and the report are of the whole phase)`, "idle"));
    if (p.reason) out.push(fact("failure", p.reason.slice(0, 800), "blocked"));
    if (p.stall) out.push(fact("stall", M.stallText(p.stall), "blocked"));
    out.push(...this.reportRows(p, vm));
    const turns = group ? group.turns : [];
    const sliceOpen = this.openSlices.has(p.key);
    out.push(div().id(`slice-${p.key}`).pl(34).pr(12).py(4).mt(4).text_size(12).text_color(th.accent).cursor_pointer()
      .on_click((_e, cx) => this.toggle(this.openSlices, p.key, cx))
      .child(`${sliceOpen ? "▾" : "▸"} Agent output (${turns.length} turn${turns.length === 1 ? "" : "s"}${this.dropped > 0 || this.omitted > 0 ? ", of the part of the log the server still has" : ""})`));
    if (sliceOpen) {
      if (turns.length === 0) out.push(note(th, "No output from this phase in the log the server still has."));
      for (const t of turns) out.push(this.renderTurn(t, th));
    }
    return out;
  }

  reportRows(p, vm) {
    const { th } = vm;
    const out = [];
    const pad = (s, color = "dim", size = 11) => div().pl(34).pr(12).py(2).text_size(size).text_color(col(th, color)).child(String(s));
    const title = (extra) => h_flex().pl(34).pr(12).pt(6).pb(2).gap(8).items_center().flex_wrap()
      .child(div().text_size(11).font_semibold().text_color(th.muted).child("PHASE REPORT"))
      .children(extra.filter(Boolean));
    const w = this.warn.artifacts;
    const entry = p.artifact;
    if (!this.artifactMap) {
      const g = this.gitRows(p, vm, title, pad);
      if (g) return g;
      out.push(title([]), pad(w ? `The report list could not be read, so this phase's report cannot be shown (${w.text}).` : "Reading the report list…", w ? (w.kind === "missing_route" ? "idle" : "blocked") : "dim", 12));
      return out;
    }
    if (!entry) {
      const why = p.state === "running" || p.state === "paused" ? "The report is recorded when the phase completes."
        : p.state === "done" ? `This phase recorded no report${p.reportName ? ` (the workflow names it ${p.reportName})` : ""}.`
        : "This phase ended without recording a report.";
      out.push(title([]), pad(why, "dim", 12));
      return out;
    }
    const name = entry.path.split("/").pop();
    const served = this.reports.get(entry.phase_id)?.body; // what the server answered for it, once it has
    const pathIsDead = served !== undefined && (served.state !== "ok" || served.source === "archive"); // `open` would open nothing
    const pills = [
      chip(th, `copy-path-${p.key}`, "copy path", false, (_e, cx) => this.copy(entry.path, "the report path", cx)),
      OPENABLE.test(entry.path) && entry.path.startsWith("/") && !pathIsDead ? chip(th, `open-file-${p.key}`, "open", false, () => this.openFile(entry.path)) : null,
    ];
    out.push(title([div().text_size(11).text_color(th.dim).child(`${name} · ${M.bytesText(entry.bytes)}`), ...pills]));
    const c = this.reports.get(entry.phase_id);
    if (!c || c.status === "loading") { out.push(pad("Loading the report…", "dim", 12)); return out; }
    if (c.status === "failed") {
      out.push(pad(`Could not read the report: ${c.warn.text}`, c.warn.kind === "missing_route" ? "idle" : "blocked", 12));
      out.push(...(this.gitRows(p, vm, title, pad, true) ?? []));
      return out;
    }
    const b = c.body;
    out.push(pad(entry.path, "dim", 10.5));
    if (b.state !== "ok") {
      const g = this.gitReports.get(p.key);
      const recovered = g?.status === "done" && g.files.length > 0;
      out.push(pad(`${b.state === "missing" ? "The report file is missing" : "The report file could not be read"}${b.error ? `: ${b.error}` : "."}`, recovered ? "dim" : "blocked", 12));
      if (b.state === "missing" && !recovered) out.push(pad(b.source === undefined ? "The run's worktree or report directory may have been cleaned up." : "The run's worktree or report directory was cleaned up and the server holds no archived copy (reports are archived when a phase completes; runs that finished before that was in place have none).", "dim"));
      out.push(...(this.gitRows(p, vm, title, pad, true) ?? []));
      return out;
    }
    const sha = b.sha_matches === true ? ["✓ sha256 matches what the phase recorded", "done"] : b.sha_matches === false ? ["✕ sha256 differs from what the phase recorded: the file changed after the phase wrote it", "blocked"] : ["sha256 was not checked", "dim"];
    out.push(pad(sha[0], sha[1]));
    if (b.source === "archive") out.push(pad("Showing the server's archived copy: the file at the path above is gone or has changed since the phase wrote it.", "idle"));
    if (b.truncated) out.push(pad(`Showing the first ${M.bytesText(b.content_bytes)} of ${M.bytesText(b.bytes)}: the server returns at most that much. Open the file for the rest.`, "idle"));
    out.push(...this.reportBodyRows(p.key, c.rows, th, pad));
    return out;
  }

  // The text of a report, from its rows: the first REPORT_ROWS, then "show more".
  reportBodyRows(key, rows, th, pad) {
    const out = [];
    if (rows.length === 0) out.push(pad("The report is empty.", "dim", 12));
    const limit = this.reportShown.get(key) ?? REPORT_ROWS;
    rows.slice(0, limit).forEach((m, k) => { const el = this.mdRow(m, th, `${key}-${k}`); if (el) out.push(el); });
    if (rows.length > limit) {
      out.push(h_flex().pl(34).pr(12).py(3).gap(6)
        .child(chip(th, `more-${key}`, `show ${Math.min(REPORT_PAGE, rows.length - limit)} more rows`, false, (_e, cx) => { this.reportShown.set(key, limit + REPORT_PAGE); cx.notify(); }))
        .child(chip(th, `all-${key}`, `show all ${rows.length}`, false, (_e, cx) => { this.reportShown.set(key, rows.length); cx.notify(); })));
    }
    return out;
  }

  // The phase's report as read from the run's commits (loadGitReport); null when that was never tried.
  gitRows(p, vm, title, pad, titled = false) {
    const { th } = vm;
    const g = this.gitReports.get(p.key);
    if (!g) return null;
    const out = titled ? [] : [title([])];
    if (g.status === "loading") return [...out, pad("Looking for the report in the run's commits…", "dim", 12)];
    if (g.status === "failed") return [...out, pad(`Could not read the report from the run's commits: ${g.warn}`, "blocked", 12)];
    if (g.files.length === 0) return [...out, pad(g.reason, "dim", 12)];
    g.files.forEach((f, i) => {
      const head = h_flex().pl(34).pr(12).pt(4).pb(2).gap(8).items_center().flex_wrap()
        .child(div().text_size(11).text_color(th.foreground).child(`${f.path.split("/").pop()} · ${M.bytesText(f.bytes)}`))
        .child(chip(th, `copy-text-${p.key}-${i}`, "copy text", false, (_e, cx) => this.copy(f.text, "the report", cx)))
        .when(g.source === "git", (el) => el.child(chip(th, `copy-commit-${p.key}-${i}`, "copy commit", false, (_e, cx) => this.copy(g.sha, "the commit id", cx))))
        .when(g.source !== "git" && OPENABLE.test(f.path), (el) => el.child(chip(th, `open-local-${p.key}-${i}`, "open", false, () => this.openFile(f.path))));
      out.push(head);
      out.push(pad(f.path, "dim", 10.5));
      out.push(pad(g.source === "git"
        ? `Read from commit ${g.sha.slice(0, 10)} ${g.via === null ? `("Foreman run … phase ${p.index}")` : `("Foreman run … phase ${g.via}": this phase deferred its commit to it)`} in ${g.repo}, not from the server: the report as committed, not checked against a recorded digest.`
        : `Read from ${f.path} on this machine${g.source === "archive" ? " (the server's archived copy)" : ""}, not through the server: not checked against a recorded digest.`, "idle"));
      if (f.truncated) out.push(pad(g.source === "git" ? `Showing the first ${M.bytesText(REPORT_CAP)} of ${M.bytesText(f.bytes)}; git show ${g.sha.slice(0, 10)}:${f.path} has the rest.` : `Showing the first ${M.bytesText(REPORT_CAP)} of ${M.bytesText(f.bytes)}; open the file for the rest.`, "idle"));
      out.push(...this.reportBodyRows(`${p.key}~${i}`, f.rows, th, pad));
    });
    return out;
  }

  // One row of a phase report. Plain text throughout: only the shape the markdown asked for is drawn.
  mdRow(m, th, id) {
    const mono = (el) => (this.mono ? el.font_family(this.mono) : el);
    switch (m.kind) {
      case "h": return div().pl(34).pr(12).pt(m.level === 1 ? 10 : 6).pb(1).text_size(m.level === 1 ? 14 : m.level === 2 ? 13 : 12).font_semibold().text_color(m.level === 3 ? th.muted : th.foreground).child(m.text);
      case "bold": return div().pl(34).pr(12).pt(3).text_size(12).font_semibold().text_color(th.foreground).child(m.text);
      case "p": return this.labelled(th, 34, null, m);
      case "li": return this.labelled(th, 34 + (m.depth ?? 0) * 14, m.bullet, m);
      case "code": return mono(div().ml(34).mr(12).px(8).bg(th.surface).text_size(11).text_color(th.muted).child(m.text === "" ? " " : m.text));
      case "fence": return m.text ? div().pl(34).pr(12).pt(3).text_size(10).text_color(th.dim).child(m.text) : null;
      case "quote": return div().ml(34).pl(8).pr(12).border_l(2).border_color(th.border).text_size(12).text_color(th.muted).child(m.text);
      case "rule": return div().h(1).ml(34).mr(12).my(4).bg(th.border);
      case "table": return h_flex().id(`md-${id}`).pl(34).pr(12).py(1).gap(8)
        .children(m.cells.map((c) => div().flex_1().min_w(0).text_size(11).when(m.header, (el) => el.font_semibold()).text_color(m.header ? th.foreground : th.muted).child(c)));
      case "blank": return div().h(6);
      case "note": return div().pl(34).pr(12).py(2).text_size(11).text_color(th.dim).child(m.text);
      default: return null;
    }
  }

  // A paragraph or list item; a `**Label**:` prefix is drawn bold in a column of its own.
  labelled(th, pl, bullet, m) {
    return h_flex().pl(pl).pr(12).py(1).gap(5).items_start()
      .when(!!bullet, (el) => el.child(div().w(14).flex_none().text_size(12).text_color(th.dim).child(bullet)))
      .when(!!m.label, (el) => el.child(div().flex_none().text_size(12).font_semibold().text_color(th.foreground).child(m.label)))
      .child(div().flex_1().min_w(0).text_size(12).text_color(th.foreground).child(m.text === "" ? " " : m.text));
  }

  // ---- Changes: the worktree's (or the pull request's) files, a click shows a patch.
  changesRows(vm) {
    const { th } = vm;
    const c = this.changes;
    if (!c) return [note(th, "Looking for changes…")];
    if (c.state === "error") return [note(th, `Could not read the changes: ${c.reason}`, "blocked")];
    if (c.state === "none") return [note(th, `No changes to show: ${c.reason}.`)];
    const files = [...c.files, ...c.untracked.map((path) => ({ path, untracked: true }))];
    const add = c.files.reduce((n, f) => n + (f.add || 0), 0);
    const del = c.files.reduce((n, f) => n + (f.del || 0), 0);
    return [
      note(th, `${files.length} file${files.length === 1 ? "" : "s"}  ·  +${add} −${del}  ·  from the ${c.source}${c.head ? `  ·  HEAD ${c.head}` : ""}${c.source === "worktree" ? "  ·  includes uncommitted work" : ""}`, "muted"),
      ...c.commits.map((m) => h_flex().id(`commit-${m.sha}`).px(12).py(2).gap(8)
        .child(div().w(10))
        .child(div().w(60).text_size(11).text_color(th.accent).child(m.sha))
        .child(div().flex_1().truncate().text_size(12).text_color(th.foreground).child(m.subject))),
      ...(c.commits.length > 0 && files.length > 0 ? [div().h(1).mx(12).my(4).bg(th.border)] : []),
      ...files.map((f) => this.renderFile(f, th)),
      ...(files.length === 0 ? [note(th, "Nothing has changed yet.")] : []),
    ];
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
}

// Theme colour names for the tones model.js speaks in.
const TONE = { ok: "done", bad: "blocked", warn: "idle", pending: "working", unknown: "idle", dim: "dim", muted: "muted", accent: "accent" };
const SEVERITY = { critical: "blocked", major: "blocked", minor: "idle", nitpick: "muted" };

const checksText = (p) => (p.checks.observed
  ? `${p.checks.pass} passing · ${p.checks.fail} failing · ${p.checks.pending} pending${p.checks.unknown ? ` · ${p.checks.unknown} unknown` : ""}${p.checks.total === 0 && p.checks.state ? ` (watch: ${p.checks.state})` : ""}`
  : `none observed${p.checks.state ? ` (watch: ${p.checks.state})` : ""}`);
const reasonText = (x) => `${x.code}${x.subject ? ` (${x.subject})` : ""}${x.detail ? `: ${x.detail}` : ""}`;
const findingsText = (p) => (p.findings.observed
  ? `${p.findings.unresolved} unresolved of ${p.findings.total}${Object.keys(p.findings.unresolvedBy).length ? ` (${["critical", "major", "minor", "nitpick"].filter((k) => p.findings.unresolvedBy[k]).map((k) => `${p.findings.unresolvedBy[k]} ${k}`).join(", ") || "none open"})` : ""}${p.findings.status ? ` · ${p.findings.status}` : ""}`
  : "none recorded");

// The visible lines of a turn's segments: the answer in the text colour, thinking dimmed and italic.
const segDivs = (th, segs, pl, base) => segs.map((g) => div().pl(pl).pr(12).text_size(12)
  .text_color(g.think ? th.dim : col(th, base)).when(g.think, (el) => el.italic()).child(g.text));

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
