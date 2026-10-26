#!/usr/bin/env node
// Browser driver for the Scheduled tab of the Foreman project workspace (audit row C9, bead
// foreman-8vf0s). It drives a REAL Chromium against a running server and, at every step, compares what
// the page shows with what `GET /api/projects/:id/schedules` (the tab's own data source, and the CLI's
// `project schedule list`) says:
//
//   node scheduled_tab_ui.mjs --base http://localhost:<port> --token <api token> --project <id> \
//        --pause <schedule name> [--expect-next <name>=<ISO instant> ...] [--shot-dir <dir>]
//
// 1. open /dashboard/projects/<id>, wait for the LiveView socket, click the Scheduled tab;
// 2. every non-deleted schedule of the API is a row: same name, same status, same next fire;
//    a next fire matches the independent expectation when one is given (--expect-next, e.g. a yearly
//    cron) or, for an interval, anchor + k * every computed here from the API's own spec;
// 3. click "Pause <name>": the row says paused, shows no next fire and offers "Resume <name>"; the API
//    says paused with no next fire; the OTHER schedules are untouched;
// 4. click "Resume <name>": the row is active again with a next fire in the future that matches the
//    expectation, the API agrees.
//
// One JSON line per observation on stdout; the checks are the lines with a "check" key
// ({"check": ..., "ok": true|false, "detail": ...}). Exit 0 when every check passed, 1 otherwise.
//
// Uses the Playwright + Chromium of scripts/e2e/ui-a11y (`cd scripts/e2e/ui-a11y && npm ci`). Open the
// page on `localhost`, not 127.0.0.1: the dev endpoint's origin check refuses the LiveView socket for
// the latter (the page then stays phx-error and every button is inert).
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const require = createRequire(path.join(here, "ui-a11y", "package.json"));
const { chromium } = require("playwright");

const argv = process.argv.slice(2);
const args = {};
const expectNext = {};
for (let i = 0; i < argv.length; i += 2) {
  if (!argv[i].startsWith("--")) continue;
  const key = argv[i].slice(2);
  if (key === "expect-next") {
    const [name, instant] = argv[i + 1].split(/=(.+)/);
    expectNext[name] = instant;
  } else {
    args[key] = argv[i + 1];
  }
}
const base = args.base;
const token = args.token ?? process.env.FOREMAN_API_TOKEN ?? "";
const project = args.project;
const pauseName = args.pause;
const shotDir = args["shot-dir"];
if (!base || !project || !pauseName) {
  console.error("usage: scheduled_tab_ui.mjs --base http://localhost:PORT --token T --project ID --pause NAME [--expect-next NAME=ISO] [--shot-dir DIR]");
  process.exit(2);
}
if (new URL(base).hostname === "127.0.0.1") {
  console.error("use http://localhost:<port>: the LiveView socket is refused for 127.0.0.1");
  process.exit(2);
}
const apiBase = base.replace("//localhost:", "//127.0.0.1:");
const DEADLINE_MS = 20000;

const log = (obj) => console.log(JSON.stringify({ at: new Date().toISOString(), ...obj }));
const failures = [];
function check(name, ok, detail) {
  log({ check: name, ok: Boolean(ok), detail });
  if (!ok) failures.push(name);
}

// Exit 3, not 1: a host without a Chromium cannot say anything about the tab (the flow script records UNVERIFIED).
let browser;
try {
  browser = await chromium.launch({ headless: true });
} catch (e) {
  log({ event: "error", message: `browser launch failed: ${String(e).split("\n")[0]}` });
  process.exit(3);
}
const ctx = await browser.newContext({ viewport: { width: 1280, height: 1000 } });
const page = await ctx.newPage();
const consoleErrors = [];
const pageErrors = [];
page.on("console", (m) => m.type() === "error" && consoleErrors.push(m.text()));
page.on("pageerror", (e) => pageErrors.push(String(e)));

async function shot(name) {
  if (!shotDir) return;
  mkdirSync(shotDir, { recursive: true });
  const file = path.join(shotDir, `scheduled-tab-${name}.png`);
  await page.screenshot({ path: file, fullPage: true });
  log({ event: "screenshot", file });
}

async function apiSchedules() {
  const res = await fetch(`${apiBase}/api/projects/${encodeURIComponent(project)}/schedules`, {
    headers: { authorization: `Bearer ${token}` },
  });
  if (!res.ok) throw new Error(`GET schedules answered ${res.status}`);
  return (await res.json()).schedules;
}

// `foreman project schedule list --json` (--cli <binary>; FOREMAN_API_URL/FOREMAN_API_TOKEN come from the environment):
// the CLI reads the same projection, through its own client.
function cliSchedules() {
  if (!args.cli) return null;
  const out = execFileSync(args.cli, ["project", "schedule", "list", "--project-id", project, "--json"], { env: process.env, encoding: "utf8" });
  return JSON.parse(out).schedules;
}

// The Scheduled tab's table, as rendered.
const uiRows = () =>
  page.evaluate(() =>
    [...document.querySelectorAll("#panel-scheduled tbody tr")].map((tr) => {
      const cells = tr.querySelectorAll("td");
      return {
        name: cells[0]?.textContent.trim(),
        status: cells[1]?.textContent.trim(),
        next_fire: cells[2]?.textContent.trim(),
        buttons: [...tr.querySelectorAll("button")].map((b) => b.textContent.trim()),
      };
    }),
  );

// Poll `fn` until it returns a truthy value or the deadline passes (never a fixed sleep).
async function until(fn, ms = DEADLINE_MS) {
  const end = Date.now() + ms;
  for (;;) {
    const value = await fn();
    if (value) return value;
    if (Date.now() >= end) return null;
    await new Promise((r) => setTimeout(r, 250));
  }
}

const rowOf = (rows, name) => rows.find((r) => r.name === name);
const apiOf = (list, name) => list.find((s) => s.name === name);
const sameInstant = (a, b) => a && b && Date.parse(a) === Date.parse(b);

// The next slot after `now` of an interval spec (anchor + k * every, k >= 1 once past the anchor).
function intervalNext(spec, now) {
  const m = /^(\d+)(s|m|h|d)$/.exec(spec.every);
  if (!m) return null;
  const every = Number(m[1]) * { s: 1, m: 60, h: 3600, d: 86400 }[m[2]] * 1000;
  const anchor = Date.parse(spec.anchor);
  const k = Math.max(1, Math.floor((now - anchor) / every) + 1);
  return new Date(anchor + k * every).toISOString();
}

function expectedNext(s) {
  if (expectNext[s.name]) return expectNext[s.name];
  if (s.spec.every && s.spec.anchor) return intervalNext(s.spec, Date.now());
  return null;
}

try {
  await page.goto(`${base}/dashboard/projects/${encodeURIComponent(project)}?token=${encodeURIComponent(token)}`, { waitUntil: "load" });
  // The socket being connected is not enough: a click before the LiveView CHANNEL has joined is dropped, and the
  // joined main view carries .phx-connected.
  await page.waitForFunction(() => window.liveSocket?.isConnected() && document.querySelector("[data-phx-main].phx-connected"), null, { timeout: DEADLINE_MS });
  log({ event: "connected", url: page.url().replace(/token=[^&]*/, "token=<redacted>") });

  await page.click("#tab-scheduled");
  await page.waitForSelector('#tab-scheduled[aria-selected="true"]', { timeout: DEADLINE_MS });
  check("scheduled tab selected", true, "aria-selected=true on #tab-scheduled");

  const before = await apiSchedules();
  check("API lists schedules", before.length >= 2, before.map((s) => ({ name: s.name, spec: s.spec, status: s.status, next_fire_at: s.next_fire_at })));

  const listed = await until(async () => {
    const rows = await uiRows();
    return rows.length === before.length ? rows : null;
  });
  check("every API schedule is a row of the tab", listed !== null, listed ?? { ui: await uiRows(), api: before.map((s) => s.name) });
  await shot("listed");

  for (const s of before) {
    const row = rowOf(listed ?? [], s.name);
    const want = expectedNext(s);
    check(`row "${s.name}": status ${s.status}`, row?.status === s.status, { ui: row?.status, api: s.status });
    check(`row "${s.name}": next fire shown = API next_fire_at`, row && sameInstant(row.next_fire, s.next_fire_at), { ui: row?.next_fire, api: s.next_fire_at });
    if (want) check(`row "${s.name}": next fire = the independently expected slot ${want} (spec ${JSON.stringify(s.spec)})`, sameInstant(row?.next_fire, want), { ui: row?.next_fire, expected: want });
    check(`row "${s.name}": offers Pause`, row?.buttons.includes(`Pause ${s.name}`), row?.buttons);
  }

  const target = apiOf(before, pauseName);
  const others = before.filter((s) => s.name !== pauseName);
  if (!target) throw new Error(`no schedule named ${pauseName} in the API list`);

  // ---- pause
  await page.getByRole("button", { name: `Pause ${pauseName}`, exact: true }).click();
  log({ event: "clicked", button: `Pause ${pauseName}` });
  const pausedRow = await until(async () => {
    const r = rowOf(await uiRows(), pauseName);
    return r?.status === "paused" ? r : null;
  });
  check("pause: the row flips to paused in the UI", pausedRow !== null, pausedRow ?? rowOf(await uiRows(), pauseName));
  check("pause: the row shows no next fire (-)", pausedRow?.next_fire === "-", pausedRow?.next_fire);
  check("pause: the row now offers Resume and not Pause", pausedRow?.buttons.includes(`Resume ${pauseName}`) && !pausedRow.buttons.includes(`Pause ${pauseName}`), pausedRow?.buttons);
  const apiPaused = await until(async () => {
    const s = apiOf(await apiSchedules(), pauseName);
    return s?.status === "paused" ? s : null;
  });
  check("pause: GET /api/projects/:id/schedules says paused", apiPaused !== null, apiPaused && { status: apiPaused.status, next_fire_at: apiPaused.next_fire_at });
  check("pause: the API has no next_fire_at for it", apiPaused?.next_fire_at === null, apiPaused?.next_fire_at);
  const afterPause = await apiSchedules();
  for (const o of others) {
    const now = apiOf(afterPause, o.name);
    check(`pause: schedule "${o.name}" is untouched (${o.status})`, now?.status === o.status && sameInstant(now.next_fire_at, o.next_fire_at), { status: now?.status, next_fire_at: now?.next_fire_at });
  }
  log({ event: "notice", text: (await page.textContent("#notice").catch(() => null))?.trim() ?? null });
  await shot("paused");

  // ---- resume
  await page.getByRole("button", { name: `Resume ${pauseName}`, exact: true }).click();
  log({ event: "clicked", button: `Resume ${pauseName}` });
  const resumedRow = await until(async () => {
    const r = rowOf(await uiRows(), pauseName);
    return r?.status === "active" ? r : null;
  });
  check("resume: the row flips back to active in the UI", resumedRow !== null, resumedRow ?? rowOf(await uiRows(), pauseName));
  check("resume: the row offers Pause again", resumedRow?.buttons.includes(`Pause ${pauseName}`), resumedRow?.buttons);
  const apiResumed = await until(async () => {
    const s = apiOf(await apiSchedules(), pauseName);
    return s?.status === "active" ? s : null;
  });
  check("resume: GET /api/projects/:id/schedules says active", apiResumed !== null, apiResumed && { status: apiResumed.status, next_fire_at: apiResumed.next_fire_at });
  check("resume: the API has a next_fire_at in the future again", apiResumed?.next_fire_at && Date.parse(apiResumed.next_fire_at) > Date.now(), apiResumed?.next_fire_at);
  check("resume: the row's next fire = the API's", resumedRow && sameInstant(resumedRow.next_fire, apiResumed?.next_fire_at), { ui: resumedRow?.next_fire, api: apiResumed?.next_fire_at });
  const want = apiResumed ? expectedNext(apiResumed) : null;
  if (want) check(`resume: next fire = the independently expected slot ${want}`, sameInstant(apiResumed.next_fire_at, want), { api: apiResumed.next_fire_at, expected: want });
  await shot("resumed");

  check("no uncaught page errors", pageErrors.length === 0, pageErrors.slice(0, 3));
  if (consoleErrors.length) log({ event: "console-errors", errors: consoleErrors.slice(0, 5) });
  await browser.close();
  process.exit(failures.length === 0 ? 0 : 1);
} catch (e) {
  log({ event: "error", message: String(e).split("\n")[0], rows: await uiRows().catch(() => null), notice: await page.textContent("#notice").catch(() => null) });
  await shot("error").catch(() => {});
  await browser.close();
  process.exit(1);
}
