// The run-detail tab's logic without any drawing: duration math, phase rows, transcript clean-up and
// grouping, phase-report markdown, PR evidence reduction, the "now" and outcome summaries. main.js draws
// what these return. No imports and no clock reads (callers pass `now`), so every function runs on plain
// data under bun/node. install.sh copies this file next to main.js (a mod can only import from its own
// folder).

// ------------------------------------------------------------------------------------------ run state

// Projection statuses that end a run. `terminal?` is the projection's own flag; it wins when present.
export const FINISHED = new Set(["completed", "failed", "cancelled", "blocked", "stuck"]);
export const isFinished = (r) => r?.["terminal?"] === true || FINISHED.has(r?.status);
// Anything that is not over keeps being polled (a status this file does not know included).
export const isLive = (r) => !!r && !isFinished(r);

const finite = (n) => typeof n === "number" && Number.isFinite(n);
const firstLine = (s) => String(s ?? "").split("\n")[0];

// ------------------------------------------------------------------------------------------ formatting

export const compact = (n) => (n >= 1e6 || (n >= 1e3 && (n / 1e3).toFixed(1) === "1000.0") ? `${(n / 1e6).toFixed(1)}M` : n >= 1e3 ? `${(n / 1e3).toFixed(1)}k` : String(n ?? 0));

export function span(ms) {
  const s = Math.max(0, Math.floor(ms / 1000));
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m ${s % 60}s`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`;
  return `${Math.floor(s / 86400)}d ${Math.floor((s % 86400) / 3600)}h`;
}

export function bytesText(n) {
  if (!finite(n)) return "?";
  if (n < 1024) return `${n} B`;
  if (n < 1048576 && (n / 1024).toFixed(1) !== "1024.0") return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / 1048576).toFixed(1)} MB`;
}

export const oneLine = (v, max = 200) => {
  const s = (typeof v === "string" ? v : JSON.stringify(v) ?? String(v)).replace(/\s+/g, " ").trim();
  return s.length > max ? `${s.slice(0, max - 1)}…` : s;
};

export const truncate = (s, max) => (s.length > max ? `${s.slice(0, max - 1)}…` : s);

export const prNumber = (url) => {
  const m = /\/pull\/(\d+)/.exec(String(url ?? ""));
  return m ? Number(m[1]) : null;
};

// ------------------------------------------------------------------------------------------ fetch errors

// api() (common.js) throws an Error with `.status` (HTTP status) and, when the body was a JSON
// {error: code}, `.code`. A 404 without a code is the server not knowing the route at all (it answers
// with its own HTML/plain 404 page): an older Foreman (`missing_route`). A 404 with a code is a real
// answer; `thread_not_found` says the run has no thread record, which is the case of a run that failed
// before its thread existed: `absent`, not a failure. Anything else is `failed`.
export function classifyFetchError(e, route) {
  const text = firstLine(e?.message ?? e);
  if (e?.status === 404 && !e?.code) return { kind: "missing_route", text: `this server has no ${route} route (HTTP 404): it predates it` };
  if (e?.status === 404 && e?.code === "thread_not_found") return { kind: "absent", text: "the server has no thread for this run (so no transcript, title or branch)" };
  return { kind: "failed", text };
}

// ------------------------------------------------------------------------------------------ turn text

// Terminal control sequences and control characters that survive in agent output. Plain text only: this
// is the only transformation a turn's text goes through before it is drawn.
const ANSI = /\u001b\[[0-9;?]*[ -\/]*[@-~]|\u001b[@-Z\\-_]/g;
const CONTROL = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g;
export const cleanText = (s) => String(s ?? "").replace(ANSI, "").replace(/\r\n?/g, "\n").replace(CONTROL, "");

// A turn with nothing to read: only whitespace, control characters, or control characters the server
// stored escaped as text (a terminal bell arrives as the six characters \u0007, not as a BEL).
const ESCAPED_CONTROL = /\\u(?:00[01][0-9a-fA-F]|007[fF])/g;
export const isBlankTurn = (t) => String(t.text ?? "").replace(ESCAPED_CONTROL, "").replace(/[\p{C}\s]/gu, "") === "";

// The server joins one stream's consecutive log entries into a turn with "\n", and an entry is a chunk,
// not a line: a streamed message is many small delta chunks followed by ONE final chunk that holds the
// whole message again (docs: ForemanServer.Threads.Transcript, "Chunks"). Read as text that is
// "d1\nd2\n…\ndn\nFINAL" with FINAL == d1+d2+…+dn: hard-wrapped mid-word, then the same message again.
// This finds each such FINAL by that exact property (the text before it, minus the joining newlines,
// IS it) and keeps only the FINAL, which loses nothing. A message the log window cut at its start is
// found by the same property read from the end. Whatever does not fit stays exactly as the server sent
// it: the trailing deltas of a message whose final has not arrived are never guessed at.
// A shorter "repeat" is more likely two real identical lines (`  end` twice in a code block).
const MIN_FINAL = 12;
const MIN_FINAL_CUT = 24; // looking for the first segment in the middle of a stream is stricter still
const MIN_CUT = 8;
const MAX_REASSEMBLE_CHARS = 400000;
const MAX_REASSEMBLE_OPS = 3000000;

export function reassemble(text) {
  const T = String(text ?? "");
  const n = T.length;
  if (n === 0 || n > MAX_REASSEMBLE_CHARS || T.indexOf("\n") < 0) return { text: T, merged: 0, fragments: false };
  let ops = 0;

  // The segment that starts at `a`: deltas T[a..s-2] joined by "\n", the join, then the final T[s..s+j).
  const completeAt = (a, minFinal) => {
    for (let s = a + 1; s < n; s++) {
      if (T.charCodeAt(s - 1) !== 10) continue;
      const end = s - 1;
      let i = a;
      let j = 0;
      let ok = true;
      while (i < end) {
        if (++ops > MAX_REASSEMBLE_OPS) return null;
        const c = T.charCodeAt(i);
        if (s + j < n && c === T.charCodeAt(s + j)) { i++; j++; }
        else if (c === 10) i++;
        else { ok = false; break; }
      }
      if (!ok || j < minFinal) continue;
      const after = s + j;
      if (after === n || T.charCodeAt(after) === 10) return { s, j };
    }
    return null;
  };

  // T[0..end) is the retained tail deltas, a join, then the whole final (which ends at `end`).
  const cutPrefix = (end, minFinal) => {
    for (let s = 1; s <= end - minFinal; s++) {
      if (T.charCodeAt(s - 1) !== 10) continue;
      let j = end - 1;
      let i = s - 2;
      let matched = 0;
      let ok = true;
      while (i >= 0) {
        if (++ops > MAX_REASSEMBLE_OPS) return -1;
        const c = T.charCodeAt(i);
        if (j >= s && c === T.charCodeAt(j)) { i--; j--; matched++; }
        else if (c === 10) i--;
        else { ok = false; break; }
      }
      if (ok && matched >= MIN_CUT) return s;
    }
    return -1;
  };

  const out = [];
  let a = 0;
  let seg = completeAt(0, MIN_FINAL);
  if (!seg) {
    for (let p = 1; p < n && ops <= MAX_REASSEMBLE_OPS; p++) {
      if (T.charCodeAt(p - 1) !== 10) continue;
      seg = completeAt(p, MIN_FINAL_CUT);
      if (seg) { a = p; break; }
    }
    if (!seg) {
      // Nothing complete follows: the whole text may be a cut group's tail deltas and its final (blank chunks after it dropped).
      const end = T.trimEnd().length;
      const s0 = cutPrefix(end, MIN_FINAL_CUT);
      return s0 >= 0 ? { text: T.slice(s0, end).trim(), merged: 1, fragments: false } : { text: T, merged: 0, fragments: false };
    }
    const s = a - 1 > 0 ? cutPrefix(a - 1, MIN_FINAL) : -1;
    const prefix = s >= 0 ? T.slice(s, a - 1) : T.slice(0, a - 1);
    out.push({ text: prefix, final: s >= 0 });
  }
  let merged = 0;
  while (a < n && seg) {
    out.push({ text: T.slice(seg.s, seg.s + seg.j), final: true });
    merged++;
    a = seg.s + seg.j + 1;
    seg = a < n ? completeAt(a, MIN_FINAL) : null;
  }
  const rest = a < n ? T.slice(a) : "";
  const restText = rest.trim();
  const fragments = restText !== "" && restText.includes("\n");
  const parts = out.map((o) => o.text.trim()).filter((s) => s !== "");
  if (restText !== "") parts.push(restText);
  return { text: parts.join("\n\n"), merged, fragments };
}

// Models that think out loud wrap it in <think>…</think> (or <thinking>). The answer and the thinking
// are drawn differently; the tags themselves are not shown. An opening tag that was cut off leaves a
// bare closing tag, an unfinished block runs to the end.
export function splitThink(text) {
  const s = String(text ?? "");
  const segs = [];
  const push = (think, t) => { const v = t.trim(); if (v !== "") segs.push({ think, text: v }); };
  let from = 0;
  const open = /<(think|thinking)>/.exec(s);
  const close = /<\/(?:think|thinking)>/.exec(s);
  if (close && (!open || close.index < open.index)) {
    push(true, s.slice(0, close.index));
    from = close.index + close[0].length;
  }
  const re = /<(think|thinking)>([\s\S]*?)(?:<\/\1>|$)/g;
  re.lastIndex = from;
  let m;
  while ((m = re.exec(s)) !== null) {
    push(false, s.slice(from, m.index));
    push(true, m[2]);
    from = m.index + m[0].length;
    if (m[0].length === 0) re.lastIndex++;
  }
  push(false, s.slice(from));
  return segs;
}

const STYLE = {
  steer: { tag: "you", color: "accent" },
  status: { tag: "run", color: "muted" },
  verdict: { tag: "review", color: "accent" },
  stderr: { tag: "err", color: "dim" },
  agent: { tag: "agent", color: "foreground" },
};
const FAILURE_STATUS = /^(?:Run (?:failed|cancelled|blocked)|Steer NOT delivered)/;

// A transcript turn ready to draw: cleaned, the chunking of a streamed message undone (only for an
// agent's own stdout: `agent` says the phase it belongs to is one), thinking told from answer.
// `key` is stable when the server's log window slides and renumbers `seq`.
export function prepareTurn(raw, agent) {
  const kind = raw.kind;
  const source = raw.source;
  const at = typeof raw.at === "string" ? Date.parse(raw.at) : NaN;
  let text = cleanText(raw.text);
  let merged = 0;
  let fragments = false;
  if (kind === "text" && source === "stdout" && agent) {
    const r = reassemble(text);
    text = r.text;
    merged = r.merged;
    fragments = r.fragments;
  }
  text = text.trim();
  const style = kind === "steer" ? STYLE.steer : kind === "status" ? STYLE.status : kind === "verdict" ? STYLE.verdict : source === "stderr" ? STYLE.stderr : STYLE.agent;
  const segs = kind === "text" ? splitThink(text) : text === "" ? [] : [{ think: false, text }];
  let verdict = null;
  if (kind === "verdict") {
    const m = /^([A-Za-z_]+):\s*([\s\S]*)$/.exec(text);
    verdict = m ? { word: m[1], summary: m[2] } : { word: text, summary: "" };
  }
  return {
    key: `${raw.at ?? "-"}|${source}|${kind}`,
    seq: raw.seq,
    atMs: Number.isFinite(at) ? at : null,
    kind,
    source,
    tag: style.tag,
    color: style.color,
    text: segs.map((g) => g.text).join("\n"),
    segs,
    merged,
    fragments,
    verdict,
    failure: kind === "status" && FAILURE_STATUS.test(text),
    count: 1,
  };
}

// Folds consecutive tiny turns of one stream into one row ("×N"), so a burst of one-word chunks does
// not become a column of rows that each say "agent" and nothing else.
export function compressTurns(turns, maxChars = 80, maxGapMs = 30000) {
  const tiny = (t) => t.kind === "text" && t.text.length <= maxChars && !t.fragments;
  const out = [];
  for (const t of turns) {
    const prev = out[out.length - 1];
    if (prev && tiny(prev) && tiny(t) && prev.source === t.source && t.atMs !== null && prev.lastAtMs !== null && t.atMs - prev.lastAtMs <= maxGapMs) {
      out[out.length - 1] = { ...prev, text: `${prev.text}\n${t.text}`, segs: [...prev.segs, ...t.segs], count: prev.count + t.count, lastAtMs: t.atMs };
    } else {
      out.push({ ...t, lastAtMs: t.atMs });
    }
  }
  return out;
}

// The last line worth showing from a turn, for the one-line live tail: the newest answer line, or the
// newest thinking line when there is no answer yet.
export function lastLine(t) {
  for (let i = t.segs.length - 1; i >= 0; i--) {
    if (t.segs[i].think) continue;
    const lines = t.segs[i].text.split("\n").map((l) => l.trim()).filter(Boolean);
    if (lines.length) return { text: lines[lines.length - 1], thinking: false };
  }
  for (let i = t.segs.length - 1; i >= 0; i--) {
    const lines = t.segs[i].text.split("\n").map((l) => l.trim()).filter(Boolean);
    if (lines.length) return { text: lines[lines.length - 1], thinking: true };
  }
  return null;
}

// The newest turn that has something to say: what the run did last.
export function liveTail(turns) {
  for (let i = turns.length - 1; i >= 0; i--) {
    const line = lastLine(turns[i]);
    if (line) return { tag: turns[i].tag, color: turns[i].color, text: line.text, thinking: line.thinking, atMs: turns[i].atMs, verdict: turns[i].verdict?.word ?? null };
  }
  return null;
}

// The first `maxLines` lines (at most `maxChars` characters) of a turn's segments, how many lines were
// left out, and how many lines the turn has in all.
export function foldSegments(segs, maxLines, maxChars) {
  const out = [];
  let left = maxLines;
  let chars = maxChars;
  let hidden = 0;
  let total = 0;
  for (const g of segs) {
    const lines = g.text.split("\n");
    total += lines.length;
    if (left <= 0 || chars <= 0) { hidden += lines.length; continue; }
    const take = Math.min(lines.length, left);
    let text = lines.slice(0, take).join("\n");
    const cut = text.length > chars;
    if (cut) text = `${text.slice(0, chars)}…`;
    out.push({ think: g.think, text });
    left -= take;
    chars -= text.length;
    hidden += lines.length - take;
  }
  return { segs: out, hidden, total };
}

// ------------------------------------------------------------------------------------------ filters

export const FILTERS = [
  { id: "all", label: "All" },
  { id: "agent", label: "Agent" },
  { id: "events", label: "Steers & status" },
  { id: "errors", label: "Errors" },
];

export function matchesFilter(t, filter) {
  if (filter === "agent") return t.kind === "text" && t.source !== "stderr";
  if (filter === "events") return t.kind === "steer" || t.kind === "status" || t.kind === "verdict";
  if (filter === "errors") return t.source === "stderr" || t.failure === true;
  return true;
}

export function filterCounts(turns) {
  const counts = {};
  for (const f of FILTERS) counts[f.id] = turns.filter((t) => matchesFilter(t, f.id)).length;
  return counts;
}

// ------------------------------------------------------------------------------------------ phases

const PHASE_STATE = { in_progress: "running", completed: "done", failed: "failed", skipped: "skipped", cancelled: "cancelled" };
export const PHASE_GLYPH = {
  done: ["✓", "done"], running: ["▶", "working"], paused: ["Ⅱ", "idle"], failed: ["✕", "blocked"],
  cancelled: ["–", "dim"], pending: ["○", "dim"], skipped: ["–", "dim"], other: ["?", "idle"],
};

const artifactName = (snap) => {
  const t = snap?.artifact ?? snap?.artifact_template;
  return typeof t === "string" && t !== "" ? t.split("/").pop() : null;
};

// One row per phase of the workflow, in order: the phases the server has started (GET /api/runs/:id/phases,
// each with its status), then the workflow's remaining phases (the run's snapshot) as "pending" while the
// run can still reach them and "skipped" once it is over. `artifacts` is a Map phase_id -> listing entry,
// or null when the listing could not be read ("unknown", never "none").
export function buildPhaseRows(run, started, snapshot, artifacts, now) {
  const over = isFinished(run);
  const snaps = Array.isArray(snapshot) ? snapshot : [];
  const snapOf = (p) => snaps.find((s) => s.phase_id && s.phase_id === p.phase_id) ?? snaps.find((s) => s.name === p.name) ?? null;
  const rows = started.map((p) => {
    let state = PHASE_STATE[p.status] ?? "other";
    let label = state === "other" ? String(p.status ?? "unknown") : state;
    if (state === "running" && run?.status === "paused") { state = "paused"; label = "paused"; }
    // A run that stopped does not close the phase it stopped in: show the run's outcome there.
    if (state === "running" && over) {
      state = run.status === "completed" ? "done" : run.status === "cancelled" ? "cancelled" : "failed";
      label = run.status === "completed" ? "done" : run.status;
    }
    const startedAt = finite(p.started_at_ms) ? p.started_at_ms : null;
    const last = finite(p.last_event_at_ms) ? p.last_event_at_ms : null;
    const stopped = state === "running" || state === "paused" ? null : p.status === "in_progress" ? (finite(run?.last_event_at_ms) ? run.last_event_at_ms : null) : last;
    const endedAt = startedAt !== null && stopped !== null && stopped >= startedAt ? stopped : null;
    const durationMs = startedAt === null ? null : endedAt !== null ? endedAt - startedAt : state === "running" || state === "paused" ? Math.max(0, now - startedAt) : null;
    const snap = snapOf(p);
    const entry = artifacts ? artifacts.get(p.phase_id) ?? null : null;
    return {
      key: p.phase_id ?? `phase-${p.index}`, phaseId: p.phase_id ?? null, index: p.index, name: p.name, state, label,
      attempt: finite(p.attempt) ? p.attempt : 1, reason: typeof p.failure_reason === "string" ? p.failure_reason : null,
      stall: p.latest_stall ?? null, started: true, startedAt, endedAt, durationMs,
      provider: snap?.provider ?? null, model: snap?.models?.default ?? null, action: snap?.action ?? null, command: snap?.command ?? null,
      reportName: artifactName(snap),
      artifact: entry, artifactState: artifacts === null ? "unknown" : entry ? "present" : "none",
    };
  });
  const seen = new Set(started.map((p) => p.name));
  snaps.filter((s) => !seen.has(s.name ?? s.phase_id)).forEach((s, i) => {
    rows.push({
      key: `pending:${s.name ?? s.phase_id}`, phaseId: null, index: s.index ?? started.length + i + 1, name: s.name ?? s.phase_id,
      state: over ? "skipped" : "pending", label: over ? "not run" : "pending", attempt: 1, reason: null, stall: null, started: false,
      startedAt: null, endedAt: null, durationMs: null, provider: s.provider ?? null, model: s.models?.default ?? null, action: s.action ?? null,
      command: s.command ?? null, reportName: artifactName(s), artifact: null, artifactState: "none",
    });
  });
  return rows;
}

// Which turns belong to which phase. Phase boundaries are not turns: a turn belongs to the latest phase
// that had started when it began, and a turn without a timestamp follows the one before it. The first
// group is the run itself (turns before any phase started).
export function groupTurns(turns, rows) {
  const started = rows.filter((r) => r.startedAt !== null);
  const groups = [{ key: "run", row: null, turns: [] }, ...started.map((r) => ({ key: r.key, row: r, turns: [] }))];
  const order = started.map((r, i) => ({ at: r.startedAt, i })).sort((x, y) => x.at - y.at || x.i - y.i);
  let cur = 0;
  for (const t of turns) {
    if (t.atMs !== null) {
      cur = 0;
      for (const o of order) { if (o.at <= t.atMs) cur = o.i + 1; else break; }
    }
    groups[cur].turns.push(t);
  }
  return groups;
}

// ------------------------------------------------------------------------------------------ run summaries

export function runElapsed(run, now) {
  if (!finite(run?.started_at_ms)) return null;
  const end = isFinished(run) ? run.last_event_at_ms : now;
  return finite(end) ? Math.max(0, end - run.started_at_ms) : null;
}

export const STALE_WARN_MS = 120000; // quiet this long: worth a look
export const STALE_BAD_MS = 600000;

// A stall report (RunStallReported): {reason, stall_kind, idle_ms, detected_at_ms, phase_name, ...}.
export function stallText(s) {
  if (s === null || s === undefined) return null;
  if (typeof s !== "object") return oneLine(s, 240);
  const bits = [s.reason ?? s.stall_kind ?? "stalled", finite(s.idle_ms) ? `idle ${span(s.idle_ms)}` : null, s.phase_name ? `in ${s.phase_name}` : null];
  return bits.filter(Boolean).join(" · ");
}

// What a live run is doing right now. `rows` from buildPhaseRows, `turns` prepared.
export function nowSummary(run, rows, turns, now) {
  const running = rows.filter((r) => r.state === "running" || r.state === "paused");
  const phase = running.length ? running[running.length - 1] : null;
  const last = finite(run?.last_event_at_ms) ? run.last_event_at_ms : null;
  const quiet = last === null ? null : Math.max(0, now - last);
  const stall = run?.latest_stall ?? phase?.stall ?? null;
  return {
    paused: run?.status === "paused",
    starting: run?.status === "awaiting_worker" || (rows.every((r) => !r.started) && rows.length > 0),
    phase,
    phaseNumber: phase ? rows.findIndex((r) => r === phase) + 1 : 0,
    phaseCount: rows.length,
    inPhaseMs: phase?.durationMs ?? null,
    quietMs: quiet,
    tone: stall ? "bad" : quiet === null ? "dim" : quiet >= STALE_BAD_MS ? "bad" : quiet >= STALE_WARN_MS ? "warn" : "ok",
    stall,
    tail: liveTail(turns),
  };
}

// What a finished run ended as. The reason is the projection's failure_reason; a cancelled run has none
// there, its reason is in the transcript's "Run cancelled: …" status turn.
export function outcomeOf(run, rows, turns, now) {
  if (!isFinished(run)) return null;
  const status = run.status;
  const failing = rows.find((r) => r.state === "failed") ?? rows.filter((r) => r.started).pop() ?? null;
  let reason = typeof run.failure_reason === "string" && run.failure_reason !== "" ? run.failure_reason : null;
  let reasonFrom = reason ? "run" : null;
  if (!reason && status !== "completed") {
    const m = [...turns].reverse().find((t) => t.kind === "status" && /^Run (failed|cancelled|blocked)\b/.test(t.text));
    const tail = m ? m.text.replace(/^Run (?:failed|cancelled|blocked):?\s*/, "") : "";
    if (tail) { reason = tail; reasonFrom = "transcript"; }
  }
  const tone = status === "completed" ? "ok" : status === "cancelled" ? "dim" : "bad";
  return {
    status, tone, glyph: status === "completed" ? "✓" : status === "cancelled" ? "–" : "✕",
    elapsedMs: runElapsed(run, now), phase: status === "completed" ? null : failing, reason, reasonFrom,
    stall: run.latest_stall ?? null,
    done: rows.filter((r) => r.state === "done").length, total: rows.length,
  };
}

// Phase transitions, steers, verdicts, run status changes, stalls and the newest stderr lines, newest first.
export function notableEvents(run, rows, turns, now, limit = 10) {
  const ev = [];
  for (const r of rows) {
    if (!r.started || r.startedAt === null) continue;
    ev.push({ at: r.startedAt, kind: "phase", tone: "working", glyph: "▶", text: `${r.name} started${r.attempt > 1 ? ` (attempt ${r.attempt})` : ""}` });
    if (r.endedAt !== null && (r.state === "done" || r.state === "failed" || r.state === "cancelled")) {
      const g = PHASE_GLYPH[r.state];
      ev.push({ at: r.endedAt, kind: "phase", tone: g[1], glyph: g[0], text: `${r.name} ${r.label}${r.durationMs !== null ? ` after ${span(r.durationMs)}` : ""}${r.state === "failed" && r.reason ? `: ${oneLine(r.reason, 140)}` : ""}` });
    }
  }
  const stall = run?.latest_stall;
  if (stall && typeof stall === "object" && finite(stall.detected_at_ms)) ev.push({ at: stall.detected_at_ms, kind: "stall", tone: "blocked", glyph: "!", text: `stalled: ${stallText(stall)}` });
  let errs = 0;
  for (const t of [...turns].reverse()) {
    if (t.atMs === null) continue;
    const line = lastLine(t)?.text;
    if (t.kind === "steer") ev.push({ at: t.atMs, kind: "steer", tone: "accent", glyph: "›", text: `you: ${oneLine(t.text, 160)}` });
    else if (t.kind === "verdict") ev.push({ at: t.atMs, kind: "verdict", tone: verdictTone(t.verdict?.word), glyph: "◆", text: `review: ${oneLine(t.text, 160)}` });
    else if (t.kind === "status") ev.push({ at: t.atMs, kind: "status", tone: t.failure ? "blocked" : "muted", glyph: "·", text: oneLine(t.text, 160) });
    else if (t.source === "stderr" && line && errs < 2) { errs++; ev.push({ at: t.atMs, kind: "stderr", tone: "dim", glyph: "!", text: `stderr: ${oneLine(line, 140)}` }); }
  }
  return ev.sort((a, b) => b.at - a.at).slice(0, limit);
}

// met / partially_met / not_met / undetermined (a recorded review's verdict).
export function verdictTone(word) {
  const w = String(word ?? "").toLowerCase();
  if (w === "met" || w === "approved" || w === "pass" || w === "passed") return "done";
  if (w === "not_met" || w === "failed" || w === "rejected" || w === "fail") return "blocked";
  if (w === "partially_met" || w === "undetermined") return "idle";
  return "accent";
}

// ------------------------------------------------------------------------------------------ markdown

// A phase report's markdown as flat rows main.js can draw one element each. Plain text only: nothing in
// the report is interpreted beyond what is stripped here (emphasis markers, link and image syntax, HTML
// comments and a few inline tags); URLs stay visible, links are never made clickable.
function inline(s) {
  return s.split(/(`[^`]*`)/).map((seg, i) => {
    if (i % 2 === 1) return seg.slice(1, -1);
    return seg
      .replace(/!\[([^\]]*)\]\([^)]*\)/g, (_m, alt) => `[image${alt ? `: ${alt}` : ""}]`)
      .replace(/\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g, (_m, t, u) => (t === u ? t : `${t} (${u})`))
      .replace(/(\*\*|__)(?=\S)([\s\S]*?\S)\1/g, "$2")
      .replace(/<\/?(?:br|p|div|span|details|summary|b|i|em|strong|code|pre|ul|ol|li|h[1-6])\b[^>]*>/gi, "");
  }).join("");
}

// `**Label**: rest` -> a label (drawn bold) and the rest; a line that is only `**Label**` is a bold heading.
function labelled(kind, raw, extra) {
  const m = /^\*\*([^*]+?)\*\*(:?)\s*([\s\S]*)$/.exec(raw);
  if (!m) return { kind, text: inline(raw), ...extra };
  const rest = inline(m[3]);
  if (rest === "") return kind === "li" ? { kind, label: inline(m[1]) + m[2], text: "", ...extra } : { kind: "bold", text: inline(m[1]) + m[2] };
  return { kind, label: inline(m[1]) + m[2], text: rest, ...extra };
}

const TABLE_ROW = /^\s*\|.*\|\s*$/;
const TABLE_RULE = /^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/;
export const MAX_REPORT_ROWS = 20000;

export function markdownRows(src) {
  const lines = String(src ?? "").replace(/\r\n?/g, "\n").replace(/<!--[\s\S]*?-->/g, "").split("\n");
  const rows = [];
  let fence = null;
  for (let i = 0; i < lines.length; i++) {
    if (rows.length >= MAX_REPORT_ROWS) { rows.push({ kind: "note", text: "The report has more lines than this tab draws." }); break; }
    const line = lines[i].replace(/\s+$/, "");
    const f = /^\s*(`{3,}|~{3,})\s*([^\s`]*)\s*$/.exec(line);
    if (fence) {
      if (f && f[1][0] === fence.ch && f[1].length >= fence.len && f[2] === "") fence = null;
      else rows.push({ kind: "code", text: cleanText(line) });
      continue;
    }
    if (f) { fence = { ch: f[1][0], len: f[1].length }; rows.push({ kind: "fence", text: f[2] }); continue; }
    if (line.trim() === "") { if (rows.length && rows[rows.length - 1].kind !== "blank") rows.push({ kind: "blank" }); continue; }
    let m = /^(#{1,6})\s+(.*?)\s*#*$/.exec(line);
    if (m) { rows.push({ kind: "h", level: Math.min(m[1].length, 3), text: inline(m[2]) }); continue; }
    if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(line)) { rows.push({ kind: "rule" }); continue; }
    m = /^\s*>\s?(.*)$/.exec(line);
    if (m) { rows.push({ kind: "quote", text: inline(m[1]) }); continue; }
    m = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/.exec(line);
    if (m) { rows.push(labelled("li", m[3], { depth: Math.min(Math.floor(m[1].length / 2), 4), bullet: /\d/.test(m[2]) ? `${parseInt(m[2], 10)}.` : "•" })); continue; }
    if (TABLE_ROW.test(line)) {
      if (TABLE_RULE.test(line)) continue;
      const cells = line.trim().replace(/^\|/, "").replace(/\|$/, "").split("|").map((c) => inline(c.trim()));
      rows.push({ kind: "table", cells, header: i + 1 < lines.length && TABLE_RULE.test(lines[i + 1]) });
      continue;
    }
    rows.push(labelled("p", line.trim(), {}));
  }
  while (rows.length && rows[rows.length - 1].kind === "blank") rows.pop();
  return rows;
}

// ------------------------------------------------------------------------------------------ PR evidence

const bad = (what) => new Error(`unexpected PR evidence: ${what}`);
const objOrNull = (v, name) => {
  if (v === null || v === undefined) return null;
  if (typeof v !== "object" || Array.isArray(v)) throw bad(`${name} is not an object`);
  return v;
};
const listOf = (v, name) => {
  if (v === null || v === undefined) return [];
  if (!Array.isArray(v)) throw bad(`${name} is not a list`);
  return v;
};
const sum = (v, name) => {
  if (v === null || v === undefined) return 0;
  if (typeof v === "number") return v;
  if (typeof v === "object" && !Array.isArray(v)) return Object.values(v).reduce((n, x) => n + (typeof x === "number" ? x : 0), 0);
  throw bad(`${name} is neither a count nor a map of counts`);
};

const CHECK_TONE = { passing: "ok", failing: "bad", pending: "pending" };

// GET /api/runs/:id/prs -> [summary]. Throws when the answer is not the documented shape: a PR whose
// evidence cannot be read must show as unreadable, never as clean.
export function summarizePrs(body) {
  if (!body || !Array.isArray(body.prs)) throw bad("no prs list");
  return body.prs.map(summarizePr);
}

export function summarizePr(d) {
  if (!d || typeof d !== "object" || typeof d.pr_url !== "string") throw bad("a record has no pr_url");
  const checks = objOrNull(d.checks, "checks");
  const counts = { pass: 0, fail: 0, pending: 0, unknown: 0 };
  const items = listOf(checks?.items, "checks.items").map((it) => {
    const tone = CHECK_TONE[it?.state] ?? "unknown";
    counts[tone === "ok" ? "pass" : tone === "bad" ? "fail" : tone === "pending" ? "pending" : "unknown"]++;
    return { name: it?.name ?? "(unnamed check)", kind: it?.kind ?? null, workflow: it?.workflow ?? null, state: it?.state ?? "unknown", conclusion: it?.conclusion ?? null, tone };
  });
  const elig = objOrNull(d.eligibility, "eligibility");
  const fixes = objOrNull(d.fixes, "fixes");
  const findings = objOrNull(d.findings, "findings");
  const risk = objOrNull(d.risk, "risk");
  const waiver = objOrNull(d.waiver, "waiver");
  const report = objOrNull(d.report, "report");
  const review = objOrNull(d.agent_review, "agent_review");
  const issue = objOrNull(d.delivery_issue, "delivery_issue");
  const reason = (x) => ({ code: x?.code ?? "?", subject: x?.subject ?? null, detail: x?.detail ?? null });
  const out = {
    url: d.pr_url, number: prNumber(d.pr_url), status: d.status ?? null, watching: d.watching === true, stopReason: d.stop_reason ?? null,
    headSha: d.head_sha ?? null, base: d.base_branch ?? null, branch: d.branch_name ?? null, gate: d.merge_gate ?? null,
    repoId: d.repo_id ?? null, // null: the run's primary repository
    checks: {
      observed: checks !== null, state: d.checks_state ?? null, items, ...counts, total: items.length,
      old: checks?.old === true, stale: checks?.stale === true, truncated: checks?.truncated === true, failing: listOf(d.failing, "failing"),
    },
    review: { decision: d.review_decision ?? null, comments: typeof d.comment_count === "number" ? d.comment_count : 0 },
    fixes: {
      attempts: fixes?.attempts ?? {}, inFlight: fixes?.in_flight ?? null, lastOutcome: fixes?.last_outcome ?? {}, exhausted: fixes?.exhausted ?? {},
    },
    eligibility: elig
      ? { status: elig.status ?? "unknown", reasons: listOf(elig.reasons, "eligibility.reasons").map(reason), waived: listOf(elig.waived, "eligibility.waived").map(reason) }
      : { status: "unknown", reasons: [{ code: "evidence_missing", subject: null, detail: "the server sent no eligibility" }], waived: [] },
    findings: findings
      ? {
        observed: true, status: findings.status ?? null, defect: findings.defect ?? null, defectDetail: findings.defect_detail ?? null,
        total: typeof findings.total === "number" ? findings.total : 0, unresolved: sum(findings.unresolved, "findings.unresolved"),
        unresolvedBy: typeof findings.unresolved === "object" && findings.unresolved ? findings.unresolved : {},
        items: listOf(findings.items, "findings.items").map((f) => ({ severity: f?.severity ?? null, disposition: f?.disposition ?? null, description: f?.description ?? null, path: f?.path ?? null, line: f?.line ?? null, source: f?.source ?? null })),
        listedTruncated: findings.listed_truncated === true, judgement: objOrNull(findings.judgement, "findings.judgement"), stale: findings.stale === true,
      }
      : { observed: false },
    risk: risk
      ? { level: risk.level ?? null, stale: risk.stale === true, rationale: listOf(risk.rationale, "risk.rationale").map((x) => ({ rule: x?.rule ?? null, level: x?.level ?? null, basis: x?.basis ?? null, detail: x?.detail ?? null })), instructions: listOf(risk.instructions, "risk.instructions").map(String) }
      : null,
    waiver: waiver ? { codes: listOf(waiver.codes, "waiver.codes"), reason: waiver.reason ?? null, by: waiver.waived_by ?? null, applies: waiver.applies ?? null, ignoredBecause: waiver.ignored_because ?? null, current: waiver.current === true } : null,
    report: report ? { status: report.status ?? null, reason: report.reason ?? null, commentUrl: report.comment_url ?? null, stale: report.stale === true } : null,
    agentReview: review ? { verdict: review.verdict ?? null, gapBeads: listOf(review.gap_bead_ids, "agent_review.gap_bead_ids"), at: review.at ?? null } : null,
    deliveryIssue: issue ? { stage: issue.stage ?? null, reason: issue.reason ?? null } : null,
    nextActions: listOf(d.next_actions, "next_actions").map((a) => ({ action: a?.action ?? "?", command: a?.command ?? null, codes: listOf(a?.codes, "next_actions.codes") })),
  };
  out.overall = prOverall(out);
  return out;
}

// One word for the whole PR: red when something is failing or the gate would refuse, yellow while it
// waits or cannot be judged, green only when the evidence says so.
export function prOverall(p) {
  if (p.checks.fail > 0 || p.eligibility.status === "ineligible" || p.status === "closed" && !p.watching && p.stopReason !== "merged") return { tone: "bad", text: p.checks.fail > 0 ? `${p.checks.fail} failing` : "ineligible" };
  if (p.status === "conflicted") return { tone: "bad", text: "conflicted" };
  if (p.eligibility.status === "unknown") return { tone: "warn", text: "unknown" };
  if (p.checks.pending > 0) return { tone: "warn", text: `${p.checks.pending} pending` };
  if (p.status === "merged") return { tone: "ok", text: "merged" };
  if (p.eligibility.status === "eligible" || p.eligibility.status === "waived") return { tone: "ok", text: p.eligibility.status };
  return { tone: "dim", text: p.eligibility.status === "off" ? "gate off" : p.status ?? "open" };
}

// ---------------------------------------------------------------------- reports recovered from git
// Foreman commits a phase's work with the subject "Foreman run <run_id> phase <n>" (Lowering.commit_message/2),
// and a phase that commits takes its report file into that commit. So when the server cannot serve a report
// (it has no /artifacts route, or the file is gone with the run's worktree) the run's own history still has it.

const escapeRe = (s) => String(s).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

// Output of `git log --all --format=%H<TAB>%s` -> Map phase number -> the newest commit whose subject is exactly
// "Foreman run <runId> phase <n>" (a substring match would also take "phase 10" for "phase 1"). git lists the
// newest commit first, so a phase that was retried and committed again keeps its last commit.
export function parsePhaseCommits(out, runId) {
  const subject = new RegExp(`^Foreman run ${escapeRe(runId)} phase (\\d+)$`);
  const commits = new Map();
  for (const line of String(out ?? "").split("\n")) {
    const [sha, ...rest] = line.split("\t");
    const m = subject.exec(rest.join("\t"));
    if (m && /^[0-9a-f]{40}$/.test(sha) && !commits.has(Number(m[1]))) commits.set(Number(m[1]), sha);
  }
  return commits;
}

// The report files among the paths one phase commit touched (`git diff-tree --name-only` lines): the files named
// like the workflow's report (its `artifact:`), else the text documents under docs/reports/. `strict` takes only
// the named files: used on a commit that is not the phase's own (a phase that declares `commit: false` has its
// work committed with a later phase, and that commit also holds the later phase's own reports). A path git quoted
// (control characters, quotes) or that could pass for an option is left out.
export function pickReportFiles(names, reportName, strict = false) {
  const paths = String(names ?? "").split("\n").map((s) => s.trim()).filter((p) => p !== "" && !p.startsWith('"') && !p.startsWith("-"));
  const named = reportName ? paths.filter((p) => p.split("/").pop() === reportName) : [];
  if (named.length > 0 || strict) return named;
  return paths.filter((p) => /(^|\/)docs\/reports\//.test(p) && /\.(?:md|markdown|txt)$/i.test(p));
}

// The local files a phase's report may be read from, in the order they are tried. The server's archived copy is keyed
// by run and phase number whatever the phase's template, so it is a candidate for every phase; the default
// `phase-<n>.md` is where only a phase with no `artifact:` template wrote its report (a template phase has no file there).
export function reportCandidates(homeDir, runId, index, reportName) {
  const dir = `${homeDir}/.foreman/runs/${runId}`;
  const out = [{ source: "archive", path: `${dir}/archive/phase-${index}.md` }];
  if (reportName === null || reportName === undefined) out.push({ source: "disk", path: `${dir}/phase-${index}.md` });
  return out;
}

// Which git commit holds a phase's report. `commits` maps phase number to the sha of the commit Foreman made for it;
// `namesOf(sha)` resolves that commit's changed file names (async, asked lazily and in phase order). The phase's own
// commit wins (with the docs/reports/ fallback); only when it holds nothing and the workflow names a report is a later
// phase's commit searched, strictly by name: a phase that declares `commit: false` has its work committed with a later
// phase. Result: {sha, via, paths}; sha is null when the phase has no commit, via the later phase's number or null.
export async function pickReportCommit(commits, index, reportName, namesOf) {
  const own = commits.get(index) ?? null;
  const paths = own ? pickReportFiles(await namesOf(own), reportName) : [];
  if (paths.length > 0 || !reportName) return { sha: own, via: null, paths };
  for (const n of [...commits.keys()].filter((k) => k > index).sort((a, b) => a - b)) {
    const found = pickReportFiles(await namesOf(commits.get(n)), reportName, true);
    if (found.length > 0) return { sha: commits.get(n), via: n, paths: found };
  }
  return { sha: own, via: null, paths: [] };
}

// Output of `git cat-file -s` then `git show` of one blob: the size on the first line, the (capped) text after it.
export function parseBlob(out, cap) {
  const s = String(out ?? "");
  const nl = s.indexOf("\n");
  const bytes = Number(s.slice(0, nl));
  if (nl < 0 || !Number.isInteger(bytes) || bytes < 0) return null;
  return { bytes, text: s.slice(nl + 1), truncated: bytes > cap };
}

// The size in bytes of a string as UTF-8 (Herdr's mod runtime has no TextEncoder).
export function utf8Bytes(s) {
  let n = 0;
  for (const ch of String(s ?? "")) {
    const c = ch.codePointAt(0);
    n += c < 0x80 ? 1 : c < 0x800 ? 2 : c < 0x10000 ? 3 : 4;
  }
  return n;
}
