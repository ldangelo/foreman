#!/usr/bin/env node
// Browser driver for the in-flight tool approvals of the Foreman workspace
// (docs/acceptance/live-claude-and-approvals.md). One action per invocation, one JSON line per
// observation on stdout, so a shell script can sequence it with live agent runs:
//
//   node approvals_ui.mjs <action> --base http://localhost:<port> --token <api token> --project <id>
//        [--thread <thread id>] [--call <tool_call_id>] [--wait-secs 120] [--shot-dir <dir>] [--label <name>]
//
// Actions:
//   state    print every thread card (title, status, approvals, notice); click nothing
//   watch    wait until a pending approval row shows, print it, screenshot; click nothing
//   approve  wait for a pending approval row, click its Approve button, wait for the notice
//   deny     same with Deny
//   stop     click the thread card's Stop, then Confirm stop
//
// Uses the Playwright + Chromium of scripts/e2e/ui-a11y (`cd scripts/e2e/ui-a11y && npm ci`).
// Open the page on `localhost`, not 127.0.0.1: the dev endpoint's origin check refuses the
// LiveView socket for the latter (the page then stays phx-error and every button is inert).
import { createRequire } from "node:module";
import { mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const require = createRequire(path.join(here, "..", "ui-a11y", "package.json"));
const { chromium } = require("playwright");

const [action, ...rest] = process.argv.slice(2);
const args = Object.fromEntries(
  rest.reduce((acc, a, i, all) => {
    if (a.startsWith("--")) acc.push([a.slice(2), all[i + 1]]);
    return acc;
  }, []),
);
const base = args.base ?? process.env.FOREMAN_UI_BASE;
const token = args.token ?? process.env.FOREMAN_API_TOKEN ?? "";
const project = args.project ?? process.env.FOREMAN_UI_PROJECT;
const waitMs = Number(args["wait-secs"] ?? 120) * 1000;
const shotDir = args["shot-dir"];
const label = args.label ?? action;
if (!["state", "watch", "approve", "deny", "stop"].includes(action) || !base || !project) {
  console.error("usage: approvals_ui.mjs state|watch|approve|deny|stop --base URL --token T --project ID [--thread ID]");
  process.exit(2);
}
if (new URL(base).hostname === "127.0.0.1") {
  console.error("use http://localhost:<port>: the LiveView socket is refused for 127.0.0.1");
  process.exit(2);
}

const log = (obj) => console.log(JSON.stringify({ at: new Date().toISOString(), ...obj }));
const browser = await chromium.launch({ headless: true });
const ctx = await browser.newContext({ viewport: { width: 1280, height: 1000 } });
const page = await ctx.newPage();
const consoleErrors = [];
page.on("console", (m) => m.type() === "error" && consoleErrors.push(m.text()));

async function shot(name) {
  if (!shotDir) return;
  mkdirSync(shotDir, { recursive: true });
  const file = path.join(shotDir, `${label}-${name}.png`);
  await page.screenshot({ path: file, fullPage: true });
  log({ event: "screenshot", file });
}

async function snapshot() {
  return page.evaluate(() =>
    [...document.querySelectorAll('article.ws-card[id^="thread-"]')].map((card) => ({
      id: card.id,
      title: card.querySelector("h4")?.textContent?.trim(),
      status: card.querySelector("p.ws-muted")?.textContent?.replace(/\s+/g, " ").trim(),
      failure: card.querySelector("p.ws-error")?.textContent?.trim() ?? null,
      buttons: [...card.querySelectorAll(".thread-actions button")].map((b) => b.textContent.trim()),
      approvals: [...card.querySelectorAll(".ws-approval")].map((a) => ({
        id: a.id,
        text: a.textContent.replace(/\s+/g, " ").trim(),
        buttons: [...a.querySelectorAll("button")].map((b) => b.textContent.trim()),
      })),
    })),
  );
}

const rowSelector = args.call
  ? `.ws-approval[id$="-${args.call}"]`
  : args.thread
    ? `[id="thread-${args.thread}"] .ws-approval`
    : ".ws-approval";
const cardSelector = args.thread ? `[id="thread-${args.thread}"]` : 'article.ws-card[id^="thread-"]';

try {
  await page.goto(`${base}/dashboard/projects/${encodeURIComponent(project)}?token=${encodeURIComponent(token)}`, { waitUntil: "load" });
  await page.waitForFunction(() => window.liveSocket?.isConnected() && document.querySelector("[data-phx-main] *"), null, { timeout: 20000 });
  log({ event: "connected", url: page.url().replace(/token=[^&]*/, "token=<redacted>") });

  if (action === "state") {
    log({ event: "state", cards: await snapshot(), notice: (await page.textContent("#notice"))?.trim() });
  } else if (action === "stop") {
    const card = page.locator(cardSelector).first();
    await card.waitFor({ state: "visible", timeout: 20000 });
    await shot("before");
    await card.getByRole("button", { name: "Stop", exact: true }).click();
    log({ event: "clicked", button: "Stop" });
    await card.getByRole("button", { name: "Confirm stop", exact: true }).click();
    log({ event: "clicked", button: "Confirm stop" });
    // The stop notice wording is not part of the contract: wait for any notice, but do not fail on none.
    await page.waitForFunction(() => (document.querySelector("#notice")?.textContent ?? "").trim() !== "", null, { timeout: 8000 }).catch(() => {});
    log({ event: "notice", text: (await page.textContent("#notice"))?.trim() });
    await shot("after");
  } else {
    const row = page.locator(rowSelector).first();
    const started = Date.now();
    await row.waitFor({ state: "visible", timeout: waitMs });
    log({ event: "approval-visible", waited_ms: Date.now() - started, rows: (await snapshot()).flatMap((c) => c.approvals) });
    await shot("before");
    if (action !== "watch") {
      const name = action === "approve" ? "Approve" : "Deny";
      const rowId = await row.getAttribute("id");
      await row.getByRole("button", { name, exact: true }).click();
      log({ event: "clicked", button: name, row: rowId });
      await page.waitForFunction(() => document.querySelector("#notice")?.textContent?.trim() !== "", null, { timeout: 20000 });
      log({ event: "notice", text: (await page.textContent("#notice"))?.trim() });
      await page.waitForFunction((id) => !document.getElementById(id), rowId, { timeout: 20000 }).catch(() => {});
      log({ event: "row-after", still_present: (await page.locator(`[id="${rowId}"]`).count()) > 0 });
      await shot("after");
    }
  }
  if (consoleErrors.length) log({ event: "console-errors", errors: consoleErrors.slice(0, 5) });
  await browser.close();
} catch (e) {
  log({ event: "error", message: String(e).split("\n")[0], cards: await snapshot().catch(() => null), notice: await page.textContent("#notice").catch(() => null) });
  await shot("error").catch(() => {});
  await browser.close();
  process.exit(1);
}
