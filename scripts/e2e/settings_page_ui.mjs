#!/usr/bin/env node
// Browser driver for the project Settings page editors and the workspace's proposal Decline (audit rows C1, C9; bead
// foreman-l2ab7). Real Chromium against a running server; every step is compared with `foreman project settings` /
// `project setup-script show` (--cli <binary>, FOREMAN_API_URL/FOREMAN_API_TOKEN from the environment):
//
//   node settings_page_ui.mjs --base http://localhost:<port> --token T --project ID --cli foreman \
//        [--proposal TASK_ID] [--shot-dir DIR]
//
// 1. /dashboard/projects/<id>/settings: repo allowlist `relative/dir` is refused with the field error shown (nothing
//    persisted), `/abs/ok` saves; max repositories per run 0 and 1001 are refused with the field error, 3 saves;
//    notification preference every_turn saves; the setup script saves (and the page reload shows it);
// 2. reload: every field shows the persisted value, and the CLI agrees;
// 3. with --proposal: the workspace page shows the proposal card, Decline closes the task (card loses its buttons, shows
//    "(closed)") and the task projection says closed.
// One JSON line per observation; the checks carry {"check", "ok", "detail"}. Exit 0 all passed, 1 a check failed, 3 no browser.
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
for (let i = 0; i < argv.length; i += 2) if (argv[i].startsWith("--")) args[argv[i].slice(2)] = argv[i + 1];
const { base, project, cli, proposal } = args;
const token = args.token ?? process.env.FOREMAN_API_TOKEN ?? "";
const shotDir = args["shot-dir"];
if (!base || !project || !cli) {
  console.error("usage: settings_page_ui.mjs --base http://localhost:PORT --token T --project ID --cli FOREMAN [--proposal TASK_ID] [--shot-dir DIR]");
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

let browser;
try {
  browser = await chromium.launch({ headless: true });
} catch (e) {
  log({ event: "error", message: `browser launch failed: ${String(e).split("\n")[0]}` });
  process.exit(3);
}
const page = await (await browser.newContext({ viewport: { width: 1280, height: 1000 } })).newPage();
const pageErrors = [];
page.on("pageerror", (e) => pageErrors.push(String(e)));

async function shot(name) {
  if (!shotDir) return;
  mkdirSync(shotDir, { recursive: true });
  const file = path.join(shotDir, `settings-${name}.png`);
  await page.screenshot({ path: file, fullPage: true });
  log({ event: "screenshot", file });
}
async function until(fn, ms = DEADLINE_MS) {
  const end = Date.now() + ms;
  for (;;) {
    const v = await fn();
    if (v) return v;
    if (Date.now() >= end) return null;
    await new Promise((r) => setTimeout(r, 250));
  }
}
const fm = (...a) => execFileSync(cli, a, { env: process.env, encoding: "utf8" });
const cliSettings = () => JSON.parse(fm("project", "settings", "--format=json", project));
// the settings document may nest the keys; find one by name anywhere in it
const deepGet = (o, key) => {
  if (o && typeof o === "object") {
    if (key in o) return o[key];
    for (const v of Object.values(o)) {
      const r = deepGet(v, key);
      if (r !== undefined) return r;
    }
  }
  return undefined;
};
async function open(urlPath, ready) {
  await page.goto(`${base}${urlPath}?token=${encodeURIComponent(token)}`, { waitUntil: "load" });
  await page.waitForFunction(() => window.liveSocket?.isConnected() && document.querySelector("[data-phx-main].phx-connected"), null, { timeout: DEADLINE_MS });
  if (ready) await page.waitForSelector(ready, { timeout: DEADLINE_MS });
}
const errText = (sel) => page.textContent(sel, { timeout: 4000 }).then((t) => t.trim()).catch(() => null);
const notice = () => page.textContent("#notice").then((t) => t.trim()).catch(() => null);

async function saveSettings() {
  await page.click('#settings-form button[type="submit"]');
}
async function fill(sel, value) {
  await page.fill(sel, value);
}

try {
  await open(`/dashboard/projects/${encodeURIComponent(project)}/settings`, "#settings-form");
  log({ event: "connected", url: page.url().replace(/token=[^&]*/, "token=<redacted>") });

  // ---- repo allowlist
  await fill("#settings_repo_allowlist", "relative/dir");
  await saveSettings();
  const alErr = await until(() => errText("#repo_allowlist-error"));
  check("allowlist: a relative path is refused with the field error shown", alErr !== null, alErr);
  check("allowlist: nothing was persisted for the refused value", !JSON.stringify(deepGet(cliSettings(), "repo_allowlist") ?? []).includes("relative/dir"), deepGet(cliSettings(), "repo_allowlist"));
  await shot("allowlist-refused");
  await fill("#settings_repo_allowlist", "/tmp/foreman-l2ab7-allowed");
  await saveSettings();
  const alOk = await until(async () => ((await page.$("#repo_allowlist-error")) ? null : true));
  check("allowlist: an absolute prefix clears the field error", alOk === true, await notice());

  // ---- max repos per run
  for (const bad of ["0", "1001"]) {
    await fill("#settings_max_repos_per_run", bad);
    await saveSettings();
    const e = await until(async () => {
      const t = await errText("#max_repos_per_run-error");
      return t && t.includes(bad === "0" ? ", 0," : ", 1001,") ? t : null;
    });
    check(`max repositories per run: ${bad} is refused with the field error shown`, e !== null, e);
    if (bad === "0") await shot("max-repos-refused");
  }
  check("max repositories per run: nothing persisted for the refused values", deepGet(cliSettings(), "max_repos_per_run") !== 0 && deepGet(cliSettings(), "max_repos_per_run") !== 1001, deepGet(cliSettings(), "max_repos_per_run"));
  await fill("#settings_max_repos_per_run", "3");
  await page.selectOption("#settings_notification_preference", "every_turn");
  await saveSettings();
  const saved = await until(() => {
    try {
      const s = cliSettings();
      return deepGet(s, "max_repos_per_run") === 3 && deepGet(s, "notification_preference") === "every_turn" ? s : null;
    } catch { return null; }
  });
  check("max repos 3 + notification every_turn: the CLI settings show both", saved !== null, saved && { max: deepGet(saved, "max_repos_per_run"), notify: deepGet(saved, "notification_preference"), allowlist: deepGet(saved, "repo_allowlist") });
  await shot("saved");

  // ---- setup script
  const script = "echo foreman-l2ab7-setup > .setup-marker";
  await page.fill("#setup_script", script);
  await page.click('#setup-script-form button[type="submit"]');
  const cliScript = await until(() => {
    try { return fm("project", "setup-script", "show", project).includes("foreman-l2ab7-setup") ? true : null; } catch { return null; }
  });
  check("setup script: saved, `project setup-script show` prints it", cliScript === true, await notice());
  await shot("setup-script");

  // ---- reload shows the persisted values
  await open(`/dashboard/projects/${encodeURIComponent(project)}/settings`, "#settings-form");
  check("reload: repo allowlist shows the persisted prefix", (await page.inputValue("#settings_repo_allowlist")).trim() === "/tmp/foreman-l2ab7-allowed", await page.inputValue("#settings_repo_allowlist"));
  check("reload: max repositories per run shows 3", (await page.inputValue("#settings_max_repos_per_run")) === "3", await page.inputValue("#settings_max_repos_per_run"));
  check("reload: notification preference shows every_turn", (await page.inputValue("#settings_notification_preference")) === "every_turn", await page.inputValue("#settings_notification_preference"));
  check("reload: setup script shows the saved text", (await page.inputValue("#setup_script")).includes("foreman-l2ab7-setup"), await page.inputValue("#setup_script"));
  const final = cliSettings();
  check("CLI `project settings` agrees with the page", deepGet(final, "max_repos_per_run") === 3 && deepGet(final, "notification_preference") === "every_turn" && JSON.stringify(deepGet(final, "repo_allowlist")).includes("/tmp/foreman-l2ab7-allowed"), { max: deepGet(final, "max_repos_per_run"), notify: deepGet(final, "notification_preference"), allowlist: deepGet(final, "repo_allowlist") });
  await shot("reloaded");

  // ---- proposal Decline
  if (proposal) {
    await open(`/dashboard/projects/${encodeURIComponent(project)}`, "#proposals");
    const card = `#proposal-${proposal}`;
    check("proposal: the card shows Start and Decline", (await page.$(`${card} button:has-text("Decline")`)) !== null && (await page.$(`${card} button:has-text("Start")`)) !== null, await page.textContent(card).catch(() => null));
    await shot("proposal");
    await page.click(`${card} button:has-text("Decline")`);
    const closed = await until(async () => ((await page.textContent(card).catch(() => ""))?.includes("(closed)") ? true : null));
    check("proposal: Decline -> the card shows (closed) and loses its buttons", closed === true && (await page.$(`${card} button`)) === null, await page.textContent(card).catch(() => null));
    const res = await fetch(`${apiBase}/api/tasks/${encodeURIComponent(proposal)}`, { headers: { authorization: `Bearer ${token}` } });
    const body = res.ok ? await res.json() : null;
    check("proposal: the task projection says closed", JSON.stringify(body).includes('"closed"'), body && (body.task?.status ?? body.status));
    await shot("proposal-declined");
  }

  check("no uncaught page errors", pageErrors.length === 0, pageErrors.slice(0, 3));
  await browser.close();
  process.exit(failures.length === 0 ? 0 : 1);
} catch (e) {
  log({ event: "error", message: String(e).split("\n")[0], notice: await notice() });
  await shot("error").catch(() => {});
  await browser.close();
  process.exit(1);
}
