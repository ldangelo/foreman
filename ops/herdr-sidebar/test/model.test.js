// Regression tests for mods/foreman-run/model.js (pure logic, plain-data fixtures, fixed clock).
// Run: bun test ops/herdr-sidebar/test   (bun is not a devbox package and CI does not run this suite)
import { test, expect } from "bun:test";
import {
  bytesText, buildPhaseRows, classifyFetchError, cleanText, compact, compressTurns, filterCounts, groupTurns, isBlankTurn,
  liveTail, markdownRows, matchesFilter, MAX_REPORT_ROWS, notableEvents, nowSummary, outcomeOf, parseBlob, parsePhaseCommits,
  pickReportFiles, prepareTurn, prOverall, reassemble, span, splitThink, summarizePr, summarizePrs, utf8Bytes,
} from "../mods/foreman-run/model.js";

const T0 = 1_700_000_000_000;
const NOW = T0 + 600_000;
const iso = (ms) => new Date(ms).toISOString();
const turn = (over = {}) => ({ seq: 1, at: iso(T0), kind: "text", source: "stdout", text: "ok", ...over });
const prep = (over = {}, agent = true) => prepareTurn(turn(over), agent);

// ------------------------------------------------------------------------------------------ reassemble

const MSG = "The quick brown fox jumps over the lazy dog";
const DELTAS = ["The quick bro", "wn fox jumps o", "ver the lazy dog"];

test("reassemble keeps only the FINAL chunk when the deltas provably concatenate to it", () => {
  const r = reassemble(`${DELTAS.join("\n")}\n${MSG}`);
  expect(r).toEqual({ text: MSG, merged: 1, fragments: false });
});

test("reassemble merges several messages and keeps the unproven tail as sent, marked unmerged", () => {
  const second = "Second whole message here";
  const text = `${DELTAS.join("\n")}\n${MSG}\nSecond whole\n message here\n${second}\nstreaming par\ntial delta`;
  const r = reassemble(text);
  expect(r.merged).toBe(2);
  expect(r.text).toBe(`${MSG}\n\n${second}\n\nstreaming par\ntial delta`);
  expect(r.fragments).toBe(true);
});

test("reassemble never guesses: deltas without a final and ordinary lines stay untouched", () => {
  const noFinal = DELTAS.join("\n");
  expect(reassemble(noFinal)).toEqual({ text: noFinal, merged: 0, fragments: false });
  const prose = "First line of a paragraph\nSecond line of a paragraph";
  expect(reassemble(prose).text).toBe(prose);
  expect(reassemble("one line").merged).toBe(0);
  expect(reassemble("").text).toBe("");
});

test("reassemble does not mistake two identical short lines for a repeat", () => {
  const code = "  end\n  end";
  expect(reassemble(code)).toEqual({ text: code, merged: 0, fragments: false });
});

test("reassemble recovers a message whose first deltas were cut off by the log window", () => {
  const cut = `umps over\n the lazy dog\n${MSG}`;
  const r = reassemble(cut);
  expect(r.text).toBe(MSG);
  expect(r.merged).toBe(1);
});

test("prepareTurn only reassembles an agent's own stdout", () => {
  const text = `${DELTAS.join("\n")}\n${MSG}`;
  expect(prep({ text }, true).text).toBe(MSG);
  expect(prep({ text }, true).merged).toBe(1);
  expect(prep({ text }, false).text).toBe(text);
  expect(prep({ text, source: "stderr" }, true).text).toBe(text);
});

test("cleanText strips terminal sequences and isBlankTurn sees escaped control characters", () => {
  expect(cleanText("\u001b[31mred\u001b[0m\r\nnext\u0007")).toBe("red\nnext");
  expect(isBlankTurn({ text: "\\u0007  \n" })).toBe(true);
  expect(isBlankTurn({ text: "\\u0007 hi" })).toBe(false);
});

// ------------------------------------------------------------------------------------------ splitThink

test("splitThink separates answer from thinking and drops the tags", () => {
  expect(splitThink("<think>plan it</think>the answer")).toEqual([{ think: true, text: "plan it" }, { think: false, text: "the answer" }]);
  expect(splitThink("a<thinking>b</thinking>c<think>d</think>")).toEqual([
    { think: false, text: "a" }, { think: true, text: "b" }, { think: false, text: "c" }, { think: true, text: "d" },
  ]);
});

test("splitThink: cut-off opening tag, unfinished block, empty block, no tags", () => {
  expect(splitThink("reasoning</think>final")).toEqual([{ think: true, text: "reasoning" }, { think: false, text: "final" }]);
  expect(splitThink("answer<think>still going")).toEqual([{ think: false, text: "answer" }, { think: true, text: "still going" }]);
  expect(splitThink("x<think>  </think>y")).toEqual([{ think: false, text: "x" }, { think: false, text: "y" }]);
  expect(splitThink("plain")).toEqual([{ think: false, text: "plain" }]);
  expect(splitThink(null)).toEqual([]);
});

// ------------------------------------------------------------------------------------------ compressTurns / liveTail

test("compressTurns folds a burst of tiny turns of one stream into one row", () => {
  const turns = [0, 1000, 2000].map((d, i) => prep({ at: iso(T0 + d), text: `w${i}` }));
  const out = compressTurns(turns);
  expect(out).toHaveLength(1);
  expect(out[0].count).toBe(3);
  expect(out[0].text).toBe("w0\nw1\nw2");
  expect(out[0].atMs).toBe(T0);
  expect(out[0].lastAtMs).toBe(T0 + 2000);
  expect(turns[0].count).toBe(1); // input untouched
});

test("compressTurns does not fold across a gap, another stream, long text, fragments or a missing timestamp", () => {
  const a = prep({ at: iso(T0), text: "a" });
  expect(compressTurns([a, prep({ at: iso(T0 + 30_001), text: "b" })])).toHaveLength(2);
  expect(compressTurns([a, prep({ at: iso(T0 + 30_000), text: "b" })])).toHaveLength(1);
  expect(compressTurns([a, prep({ at: iso(T0 + 1), text: "b", source: "stderr" })])).toHaveLength(2);
  expect(compressTurns([a, prep({ at: iso(T0 + 1), text: "x".repeat(81) })])).toHaveLength(2);
  expect(compressTurns([a, { ...prep({ at: iso(T0 + 1), text: "b" }), fragments: true }])).toHaveLength(2);
  expect(compressTurns([a, prep({ at: undefined, text: "b" })])).toHaveLength(2);
  expect(compressTurns([a, prep({ at: iso(T0 + 1), kind: "steer", text: "go" })])).toHaveLength(2);
});

test("liveTail is the newest line worth showing: skips blank turns, prefers answer over thinking", () => {
  const turns = [
    prep({ at: iso(T0), text: "first\nolder line" }),
    prep({ at: iso(T0 + 1000), text: "<think>hmm</think>\nthe answer line" }),
    prep({ at: iso(T0 + 2000), text: "   \n" }),
  ];
  const tail = liveTail(turns);
  expect(tail).toMatchObject({ text: "the answer line", thinking: false, atMs: T0 + 1000, tag: "agent" });
  expect(liveTail([prep({ text: "<think>only thoughts\nlast thought</think>" })])).toMatchObject({ text: "last thought", thinking: true });
  expect(liveTail([])).toBeNull();
  expect(liveTail([prep({ kind: "verdict", text: "not_met: gaps left" })]).verdict).toBe("not_met");
});

// ------------------------------------------------------------------------------------------ phases

const started = (over = {}) => ({ phase_id: "p1", index: 1, name: "plan", attempt: 1, status: "completed", started_at_ms: T0, last_event_at_ms: T0 + 60_000, ...over });
const snapshot = [
  { phase_id: "p1", name: "plan", provider: "pi", models: { default: "m-plan" }, artifact_template: "reports/{run}/plan.md" },
  { phase_id: "p2", name: "implement", action: "agent" },
  { phase_id: "p3", name: "review", command: "mix test" },
];
const running = { run_id: "r1", status: "in_progress", started_at_ms: T0, last_event_at_ms: NOW - 5000 };
const impl = (over = {}) => started({ phase_id: "p2", index: 2, name: "implement", status: "in_progress", started_at_ms: T0 + 60_000, last_event_at_ms: T0 + 120_000, ...over });

test("buildPhaseRows: running run has done / running / pending rows with durations", () => {
  const rows = buildPhaseRows(running, [started(), impl()], snapshot, new Map(), NOW);
  expect(rows.map((r) => [r.name, r.state, r.label])).toEqual([["plan", "done", "done"], ["implement", "running", "running"], ["review", "pending", "pending"]]);
  expect(rows[0].durationMs).toBe(60_000);
  expect(rows[0]).toMatchObject({ provider: "pi", model: "m-plan", reportName: "plan.md" });
  expect(rows[1].durationMs).toBe(NOW - (T0 + 60_000)); // still ticking
  expect(rows[1].endedAt).toBeNull();
  expect(rows[2]).toMatchObject({ started: false, durationMs: null, command: "mix test", index: 3 });
});

test("buildPhaseRows: a paused run pauses its running phase and keeps counting", () => {
  const rows = buildPhaseRows({ ...running, status: "paused" }, [started(), impl()], snapshot, null, NOW);
  expect(rows[1]).toMatchObject({ state: "paused", label: "paused", durationMs: NOW - (T0 + 60_000) });
  expect(rows[2].state).toBe("pending");
});

test("buildPhaseRows: a run that stopped closes its open phase with the run's outcome and last event time", () => {
  const end = T0 + 200_000;
  for (const [status, state, label] of [["stuck", "failed", "stuck"], ["blocked", "failed", "blocked"], ["failed", "failed", "failed"], ["cancelled", "cancelled", "cancelled"], ["completed", "done", "done"]]) {
    const run = { ...running, status, last_event_at_ms: end };
    const rows = buildPhaseRows(run, [started(), impl()], snapshot, new Map(), NOW);
    expect(rows[1]).toMatchObject({ state, label, endedAt: end, durationMs: end - (T0 + 60_000) });
    expect(rows[2]).toMatchObject({ state: "skipped", label: "not run" }); // never reached
  }
});

test("buildPhaseRows: terminal? wins over an unknown status, and an unfinished phase of a dead run has no clock", () => {
  const run = { ...running, status: "weird", "terminal?": true, last_event_at_ms: null };
  const row = buildPhaseRows(run, [impl()], snapshot, new Map(), NOW)[0];
  expect(row.state).toBe("failed");
  expect(row.durationMs).toBeNull();
});

test("buildPhaseRows: a retried phase shows its attempt and never also appears as pending", () => {
  const retried = impl({ status: "failed", attempt: 1, failure_reason: "boom" });
  const again = impl({ attempt: 2, started_at_ms: T0 + 130_000 });
  const rows = buildPhaseRows(running, [started(), retried, again], snapshot, new Map(), NOW);
  expect(rows.filter((r) => r.name === "implement").map((r) => [r.attempt, r.state])).toEqual([[1, "failed"], [2, "running"]]);
  expect(rows.filter((r) => r.name === "implement")[0].reason).toBe("boom");
  expect(rows.filter((r) => !r.started).map((r) => r.name)).toEqual(["review"]);
  const ev = notableEvents(running, rows, [], NOW, 20).map((e) => e.text);
  expect(ev).toContain("implement started (attempt 2)");
  expect(ev.some((t) => t.startsWith("implement failed after 1m 0s: boom"))).toBe(true);
});

test("buildPhaseRows: odd timestamps give no duration instead of a negative or invented one; artifacts unknown vs none", () => {
  const row = buildPhaseRows(running, [started({ started_at_ms: null })], snapshot, null, NOW)[0];
  expect(row.durationMs).toBeNull();
  expect(row.artifactState).toBe("unknown");
  const back = buildPhaseRows(running, [started({ last_event_at_ms: T0 - 1 })], snapshot, new Map(), NOW)[0];
  expect(back.durationMs).toBeNull();
  expect(back.artifactState).toBe("none");
  const entry = { phase_id: "p1", path: "/r/plan.md", bytes: 10 };
  expect(buildPhaseRows(running, [started()], snapshot, new Map([["p1", entry]]), NOW)[0]).toMatchObject({ artifactState: "present", artifact: entry });
});

test("groupTurns puts turns under the latest started phase; unstamped turns follow the one before", () => {
  const rows = buildPhaseRows(running, [started(), impl()], snapshot, new Map(), NOW);
  const turns = [
    prep({ at: iso(T0 - 1000), text: "before" }),
    prep({ at: iso(T0 + 1000), text: "in plan" }),
    prep({ at: undefined, text: "unstamped" }),
    prep({ at: iso(T0 + 60_000), text: "in impl" }), // boundary belongs to the phase that started then
    prep({ at: iso(T0 + 90_000), text: "later" }),
  ];
  const groups = groupTurns(turns, rows);
  expect(groups.map((g) => [g.key, g.turns.map((t) => t.text)])).toEqual([
    ["run", ["before"]], ["p1", ["in plan", "unstamped"]], ["p2", ["in impl", "later"]],
  ]);
  expect(groupTurns([prep({ at: undefined, text: "x" })], rows)[0].turns).toHaveLength(1);
});

// ------------------------------------------------------------------------------------------ nowSummary / outcomeOf

test("nowSummary: tone follows quiet time and stalls; phase number and starting state", () => {
  const rows = buildPhaseRows(running, [started(), impl()], snapshot, new Map(), NOW);
  const at = (quiet, run = {}) => nowSummary({ ...running, last_event_at_ms: NOW - quiet, ...run }, rows, [], NOW);
  expect(at(30_000)).toMatchObject({ tone: "ok", quietMs: 30_000, phaseNumber: 2, phaseCount: 3, paused: false });
  expect(at(120_000).tone).toBe("warn");
  expect(at(600_000).tone).toBe("bad");
  expect(at(1000, { latest_stall: { reason: "no output", idle_ms: 90_000, phase_name: "implement" } })).toMatchObject({ tone: "bad" });
  expect(at(0, { last_event_at_ms: null }).tone).toBe("dim");
  const idle = buildPhaseRows({ ...running, status: "awaiting_worker" }, [], snapshot, new Map(), NOW);
  expect(nowSummary({ status: "awaiting_worker" }, idle, [], NOW)).toMatchObject({ starting: true, phase: null, phaseNumber: 0 });
  expect(nowSummary({ ...running, status: "paused" }, rows, [], NOW).paused).toBe(true);
});

test("outcomeOf: a live run has no outcome; a completed run has no failing phase or reason", () => {
  expect(outcomeOf(running, [], [], NOW)).toBeNull();
  const run = { ...running, status: "completed", last_event_at_ms: T0 + 300_000 };
  const rows = buildPhaseRows(run, [started(), impl({ status: "completed" })], snapshot, new Map(), NOW);
  expect(outcomeOf(run, rows, [], NOW)).toMatchObject({ status: "completed", tone: "ok", glyph: "✓", phase: null, reason: null, elapsedMs: 300_000, done: 2, total: 3 });
});

test("outcomeOf: a failed run keeps a huge Elixir-term reason whole; the one-line event is bounded", () => {
  const term = `{:error, %{__struct__: ForemanServer.Error, detail: ${JSON.stringify("x".repeat(5000))},\n  trace: [${"{Mod, :fun, 2, [file: ~c\"a.ex\", line: 1]}, ".repeat(100)}]}}`;
  const run = { ...running, status: "failed", failure_reason: term, last_event_at_ms: T0 + 100_000 };
  const rows = buildPhaseRows(run, [started(), impl({ status: "failed", failure_reason: term, last_event_at_ms: T0 + 100_000 })], snapshot, new Map(), NOW);
  const o = outcomeOf(run, rows, [], NOW);
  expect(o).toMatchObject({ status: "failed", tone: "bad", glyph: "✕", reasonFrom: "run", done: 1 });
  expect(o.reason).toBe(term);
  expect(o.phase.name).toBe("implement");
  const failedEvent = notableEvents(run, rows, [], NOW, 20).find((e) => e.text.startsWith("implement failed"));
  expect(failedEvent.text.length).toBeLessThan(220);
  expect(failedEvent.text.endsWith("…")).toBe(true);
  expect(failedEvent.text).not.toContain("\n");
});

test("outcomeOf: a cancelled run's reason comes from the 'Run cancelled: …' status turn", () => {
  const run = { ...running, status: "cancelled", failure_reason: null, last_event_at_ms: T0 + 90_000 };
  const rows = buildPhaseRows(run, [started(), impl()], snapshot, new Map(), NOW);
  const turns = [prep({ kind: "status", at: iso(T0 + 80_000), text: "Run started" }), prep({ kind: "status", at: iso(T0 + 90_000), text: "Run cancelled: operator stopped it" })];
  expect(turns[1].failure).toBe(true);
  expect(outcomeOf(run, rows, turns, NOW)).toMatchObject({ status: "cancelled", tone: "dim", glyph: "–", reason: "operator stopped it", reasonFrom: "transcript" });
  expect(outcomeOf(run, rows, [turns[0]], NOW).reason).toBeNull();
  expect(outcomeOf({ ...run, failure_reason: "from projection" }, rows, turns, NOW)).toMatchObject({ reason: "from projection", reasonFrom: "run" });
});

test("outcomeOf: a stalled (stuck) run is bad and carries its stall", () => {
  const stall = { reason: "no output", stall_kind: "idle", idle_ms: 125_000, detected_at_ms: T0 + 150_000, phase_name: "implement" };
  const run = { ...running, status: "stuck", latest_stall: stall, last_event_at_ms: T0 + 150_000 };
  const rows = buildPhaseRows(run, [started(), impl()], snapshot, new Map(), NOW);
  const o = outcomeOf(run, rows, [], NOW);
  expect(o).toMatchObject({ status: "stuck", tone: "bad", stall });
  expect(o.phase.label).toBe("stuck");
  expect(notableEvents(run, rows, [], NOW, 20).find((e) => e.kind === "stall").text).toBe("stalled: no output · idle 2m 5s · in implement");
});

// ------------------------------------------------------------------------------------------ markdownRows

test("markdownRows: headings, bullets, numbering, nesting, rules, quotes and comments", () => {
  const rows = markdownRows("<!-- hidden -->\n# Title\n#### Deep ##\n- one\n    - child\n3) third\n---\n> quoted **x**\n\ntext");
  expect(rows).toEqual([
    { kind: "h", level: 1, text: "Title" },
    { kind: "h", level: 3, text: "Deep" },
    { kind: "li", text: "one", depth: 0, bullet: "•" },
    { kind: "li", text: "child", depth: 2, bullet: "•" },
    { kind: "li", text: "third", depth: 0, bullet: "3." },
    { kind: "rule" },
    { kind: "quote", text: "quoted x" },
    { kind: "blank" },
    { kind: "p", text: "text" },
  ]);
});

test("markdownRows: bold lead-ins become labels, a lone bold line a heading; links stay visible", () => {
  const rows = markdownRows("- **Verdict**: met\n**Summary**\n**Note**: see [doc](http://x.test/a) and `**raw**`\n- **Only**");
  expect(rows[0]).toMatchObject({ kind: "li", label: "Verdict:", text: "met" });
  expect(rows[1]).toEqual({ kind: "bold", text: "Summary" });
  expect(rows[2]).toMatchObject({ kind: "p", label: "Note:", text: "see doc (http://x.test/a) and **raw**" });
  expect(rows[3]).toMatchObject({ kind: "li", label: "Only", text: "" });
});

test("markdownRows: tables drop the rule row and mark the header; fences keep their content verbatim", () => {
  const rows = markdownRows("| a | **b** |\n|---|:--:|\n| 1 | 2 |\n\n```js\n# not a heading **x**\n~~~\n```\nafter\n```\nunclosed | x |");
  expect(rows.slice(0, 2)).toEqual([{ kind: "table", cells: ["a", "b"], header: true }, { kind: "table", cells: ["1", "2"], header: false }]);
  const fenced = rows.slice(3);
  expect(fenced.slice(0, 4)).toEqual([{ kind: "fence", text: "js" }, { kind: "code", text: "# not a heading **x**" }, { kind: "code", text: "~~~" }, { kind: "p", text: "after" }]);
  expect(fenced.slice(4)).toEqual([{ kind: "fence", text: "" }, { kind: "code", text: "unclosed | x |" }]); // an unclosed fence swallows the rest
});

test("markdownRows: empty input, blank collapsing and the row cap", () => {
  expect(markdownRows(null)).toEqual([]);
  expect(markdownRows("\n\n a \n\n\n\nb\n\n")).toEqual([{ kind: "p", text: "a" }, { kind: "blank" }, { kind: "p", text: "b" }]);
  const rows = markdownRows(Array.from({ length: MAX_REPORT_ROWS + 50 }, (_, i) => `line ${i}`).join("\n"));
  expect(rows).toHaveLength(MAX_REPORT_ROWS + 1);
  expect(rows[rows.length - 1].kind).toBe("note");
});

// ------------------------------------------------------------------------------------------ PR evidence

const PR = "https://github.com/acme/app/pull/12";
const item = (state, name = state) => ({ name, state, conclusion: state === "failing" ? "failure" : null });

test("summarizePr: failing checks make the PR red and are counted by state", () => {
  const p = summarizePr({
    pr_url: PR, status: "open", watching: true, checks: { items: [item("passing"), item("failing", "ci"), item("pending"), item("weird")] },
    eligibility: { status: "eligible", reasons: [] },
  });
  expect(p.number).toBe(12);
  expect(p.checks).toMatchObject({ observed: true, pass: 1, fail: 1, pending: 1, unknown: 1, total: 4 });
  expect(p.checks.items.map((c) => c.tone)).toEqual(["ok", "bad", "pending", "unknown"]);
  expect(p.overall).toEqual({ tone: "bad", text: "1 failing" }); // even though the gate says eligible
});

test("summarizePr: absent evidence is 'not observed' and never reads as clean", () => {
  const p = summarizePr({ pr_url: PR, status: "open", watching: true });
  expect(p.checks).toMatchObject({ observed: false, total: 0, fail: 0 });
  expect(p.findings).toEqual({ observed: false });
  expect(p.risk).toBeNull();
  expect(p.eligibility.status).toBe("unknown");
  expect(p.eligibility.reasons[0].code).toBe("evidence_missing");
  expect(p.overall).toEqual({ tone: "warn", text: "unknown" });
});

test("summarizePr: findings sum a per-severity map and stay observed even when empty", () => {
  const p = summarizePr({ pr_url: PR, eligibility: { status: "ineligible", reasons: [{ code: "unresolved_findings", detail: "2 high" }] },
    findings: { status: "recorded", total: 4, unresolved: { high: 2, low: 1 }, items: [{ severity: "high", description: "d", path: "a.ex", line: 3 }] } });
  expect(p.findings).toMatchObject({ observed: true, total: 4, unresolved: 3, unresolvedBy: { high: 2, low: 1 } });
  expect(p.findings.items[0]).toMatchObject({ severity: "high", path: "a.ex", line: 3 });
  expect(p.overall).toEqual({ tone: "bad", text: "ineligible" });
  expect(summarizePr({ pr_url: PR, findings: {} }).findings).toMatchObject({ observed: true, total: 0, unresolved: 0 });
});

test("prOverall: green only when the evidence says so", () => {
  const base = { checks: { fail: 0, pending: 0 }, eligibility: { status: "eligible" }, status: "open", watching: true, stopReason: null };
  const o = (over) => prOverall({ ...base, ...over, checks: { ...base.checks, ...over.checks }, eligibility: { ...base.eligibility, ...over.eligibility } });
  expect(o({})).toEqual({ tone: "ok", text: "eligible" });
  expect(o({ eligibility: { status: "waived" } }).tone).toBe("ok");
  expect(o({ checks: { pending: 2 } })).toEqual({ tone: "warn", text: "2 pending" });
  expect(o({ eligibility: { status: "unknown" } }).tone).toBe("warn");
  expect(o({ status: "conflicted" })).toEqual({ tone: "bad", text: "conflicted" });
  expect(o({ status: "merged", eligibility: { status: "ineligible" } }).tone).toBe("bad");
  expect(o({ status: "closed", watching: false })).toMatchObject({ tone: "bad" });
  expect(o({ status: "closed", watching: false, stopReason: "merged" }).tone).toBe("ok");
  expect(o({ eligibility: { status: "off" } })).toEqual({ tone: "dim", text: "gate off" });
});

test("summarizePrs rejects what is not the documented shape instead of showing it clean", () => {
  for (const body of [null, {}, { prs: {} }, { prs: "x" }]) expect(() => summarizePrs(body)).toThrow(/unexpected PR evidence/);
  expect(summarizePrs({ prs: [] })).toEqual([]);
  expect(() => summarizePrs({ prs: [{ status: "open" }] })).toThrow(/pr_url/);
  expect(() => summarizePrs({ prs: [{ pr_url: PR, checks: { items: "x" } }] })).toThrow(/checks\.items/);
  expect(() => summarizePrs({ prs: [{ pr_url: PR, findings: [] }] })).toThrow(/findings/);
  expect(() => summarizePrs({ prs: [{ pr_url: PR, findings: { unresolved: "3" } }] })).toThrow(/unresolved/);
  expect(summarizePrs({ prs: [{ pr_url: PR }, { pr_url: "https://x.test/y" }] }).map((p) => p.number)).toEqual([12, null]);
});

// ------------------------------------------------------------------------------------------ fetch errors, filters, formatting

test("classifyFetchError tells a missing route from a real 404 answer", () => {
  const err = (message, status, code) => Object.assign(new Error(message), { status, code });
  expect(classifyFetchError(err("Not Found", 404), "/api/runs/:id/phases").kind).toBe("missing_route");
  expect(classifyFetchError(err("Not Found", 404), "/api/runs/:id/phases").text).toContain("/api/runs/:id/phases");
  expect(classifyFetchError(err("thread_not_found", 404, "thread_not_found"), "x").kind).toBe("absent");
  expect(classifyFetchError(err("run_not_found\nstack", 404, "run_not_found"), "x")).toEqual({ kind: "failed", text: "run_not_found" });
  expect(classifyFetchError(err("boom", 500), "x")).toEqual({ kind: "failed", text: "boom" });
  expect(classifyFetchError("plain string", "x")).toEqual({ kind: "failed", text: "plain string" });
  expect(classifyFetchError(undefined, "x").kind).toBe("failed");
});

test("filters: agent excludes stderr, events are steer/status/verdict, errors are stderr or failed status", () => {
  const turns = [
    prep({ text: "answer" }), prep({ source: "stderr", text: "warn" }), prep({ kind: "steer", text: "go" }),
    prep({ kind: "status", text: "Run started" }), prep({ kind: "status", text: "Run failed: boom" }), prep({ kind: "verdict", text: "met: ok" }),
  ];
  expect(filterCounts(turns)).toEqual({ all: 6, agent: 1, events: 4, errors: 2 });
  expect(matchesFilter(turns[1], "agent")).toBe(false);
  expect(matchesFilter(turns[4], "errors")).toBe(true);
  expect(matchesFilter(turns[0], "errors")).toBe(false);
  expect(filterCounts([])).toEqual({ all: 0, agent: 0, events: 0, errors: 0 });
});

test("bytesText / span / compact edge values", () => {
  expect([bytesText(NaN), bytesText(undefined), bytesText(null), bytesText(0), bytesText(1023), bytesText(1024), bytesText(1048576)]).toEqual(["?", "?", "?", "0 B", "1023 B", "1.0 KB", "1.0 MB"]);
  expect(bytesText(1048575)).toBe("1.0 MB"); // not "1024.0 KB"
  expect([span(-5), span(0), span(59_999), span(60_000), span(3_599_000), span(3_600_000), span(90_061_000)]).toEqual(["0s", "0s", "59s", "1m 0s", "59m 59s", "1h 0m", "1d 1h"]);
  expect([compact(0), compact(undefined), compact(999), compact(1000), compact(74_800), compact(1_500_000)]).toEqual(["0", "0", "999", "1.0k", "74.8k", "1.5M"]);
  expect(compact(999_999)).toBe("1.0M"); // not "1000.0k"
});

// ---- reports recovered from the run's commits
const SHA = (c) => c.repeat(40);

test("parsePhaseCommits keeps the newest commit of exactly the asked run and phase", () => {
  const out = [
    `${SHA("a")}\tForeman run run-1 phase 10`, // not phase 1
    `${SHA("b")}\tForeman run run-1 phase 1`, // newest first: this is the one
    `${SHA("c")}\tForeman run run-1 phase 1`, // the earlier attempt of the same phase
    `${SHA("d")}\tForeman run run-12 phase 2`, // another run whose id starts the same
    `${SHA("e")}\tfix: Foreman run run-1 phase 3`, // not a phase commit: the subject only contains it
    `${SHA("f")}\tForeman run run-1 phase 2`,
    `nothex\tForeman run run-1 phase 4`,
    "",
  ].join("\n");
  const commits = parsePhaseCommits(out, "run-1");
  expect([...commits]).toEqual([[10, SHA("a")], [1, SHA("b")], [2, SHA("f")]]);
  expect(parsePhaseCommits("", "run-1").size).toBe(0);
  expect(parsePhaseCommits(undefined, "run-1").size).toBe(0);
});

test("parsePhaseCommits does not read a run id as a pattern", () => {
  const out = `${SHA("a")}\tForeman run run-a.b phase 1\n${SHA("b")}\tForeman run run-aXb phase 1`;
  expect([...parsePhaseCommits(out, "run-a.b")]).toEqual([[1, SHA("a")]]);
});

test("pickReportFiles prefers the file the workflow names, else the documents under docs/reports", () => {
  const names = ["src/app.ex", "docs/reports/foreman-t1/FIX_REPORT.md", "docs/reports/foreman-t1/NOTES.md", "docs/reports/foreman-t1/data.json", ""].join("\n");
  expect(pickReportFiles(names, "FIX_REPORT.md")).toEqual(["docs/reports/foreman-t1/FIX_REPORT.md"]);
  expect(pickReportFiles(names, null)).toEqual(["docs/reports/foreman-t1/FIX_REPORT.md", "docs/reports/foreman-t1/NOTES.md"]);
  // the workflow's name is not among the commit's files: fall back to the documents there
  expect(pickReportFiles(names, "OTHER.md")).toEqual(["docs/reports/foreman-t1/FIX_REPORT.md", "docs/reports/foreman-t1/NOTES.md"]);
  expect(pickReportFiles("src/app.ex\nlib/b.ex", "FIX_REPORT.md")).toEqual([]);
  expect(pickReportFiles(undefined, null)).toEqual([]);
});

test("pickReportFiles drops paths git quoted and paths that could pass for an option", () => {
  const names = ['"docs/reports/we\\"ird.md"', "-docs/reports/x.md", "docs/reports/foreman-beads:foreman:t/REPORT.md"].join("\n");
  expect(pickReportFiles(names, null)).toEqual(["docs/reports/foreman-beads:foreman:t/REPORT.md"]);
});

test("parseBlob splits the size from the text and flags a report over the cap", () => {
  expect(parseBlob("22\nNo response requested.", 1000)).toEqual({ bytes: 22, text: "No response requested.", truncated: false });
  expect(parseBlob("5000\nabc", 1000)).toEqual({ bytes: 5000, text: "abc", truncated: true });
  expect(parseBlob("0\n", 1000)).toEqual({ bytes: 0, text: "", truncated: false });
  expect(parseBlob("", 1000)).toBeNull();
  expect(parseBlob("not a size\ntext", 1000)).toBeNull();
  expect(parseBlob("12", 1000)).toBeNull(); // no newline: no text follows the size
});

test("pickReportFiles strict takes only the named file, so a later commit's own reports are not credited to a deferred phase", () => {
  const later = ["src/app.ex", "docs/reports/foreman-t1/PLAN.md", "docs/reports/foreman-t1/FIX_REPORT.md"].join("\n");
  expect(pickReportFiles(later, "PLAN.md", true)).toEqual(["docs/reports/foreman-t1/PLAN.md"]);
  expect(pickReportFiles(later, "REVIEW.md", true)).toEqual([]); // not strict it would return both documents
  expect(pickReportFiles(later, "REVIEW.md", false)).toEqual(["docs/reports/foreman-t1/PLAN.md", "docs/reports/foreman-t1/FIX_REPORT.md"]);
  expect(pickReportFiles(later, null, true)).toEqual([]);
});

test("utf8Bytes counts bytes, not characters", () => {
  expect([utf8Bytes(""), utf8Bytes(undefined), utf8Bytes("abc")]).toEqual([0, 0, 3]);
  expect(utf8Bytes("é")).toBe(2); // 1 char, 2 bytes
  expect(utf8Bytes("✓")).toBe(3);
  expect(utf8Bytes("😀")).toBe(4); // one code point, a surrogate pair in UTF-16
  expect(utf8Bytes("a✓😀")).toBe(8);
  expect(utf8Bytes("é".repeat(1000))).toBe(Buffer.byteLength("é".repeat(1000), "utf8"));
});
