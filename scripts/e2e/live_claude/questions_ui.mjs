#!/usr/bin/env node
// Browser driver for the operator-question pane of the Foreman workspace
// (docs/acceptance/live-claude-and-approvals.md, bead foreman-exofh). One action per
// invocation, one JSON line per observation on stdout, so a shell script can sequence it
// with the server side (raising a question, reading the event log):
//
//   node questions_ui.mjs <action> --base http://localhost:<port> --token <api token> --project <id>
//        [--question <question_id>] [--text <answer>] [--hold-secs 8] [--wait-secs 60]
//        [--shot-dir <dir>] [--label <name>]
//
// Actions:
//   state    print the open questions (text, asker, answer box, buttons), the "Waiting on you"
//            cards and the notice; click nothing
//   watch    wait until a question shows, print it, screenshot; click nothing
//   answer   wait for a question, type --text into its answer box, click Answer, wait for the
//            notice and for the question to leave the pane
//   blank    submit a whitespace-only answer through the real form (the browser's `required`
//            lets it through) and print the refusal; the question must stay
//   keep     type --text into a question's answer box, move the focus away (the Pull requests
//            tab, which also re-renders the page), wait --hold-secs (raise another question
//            meanwhile to force a refresh) and print whether the typed text survived
//   gone     wait for a question to leave the pane with no click here (answered over the CLI/HTTP,
//            or expired) and print how long the refresh took
//   limit    (foreman-7c191) wait for a question, print its answer box's `maxlength`, fill the box with the first <maxlength>
//            characters of --text (the exact limit), type ONE more character as a user would (the browser must stop it),
//            then set the value of the box to the whole --text (max+1 characters: a client that ignores the attribute),
//            click Answer and print the server's refusal; the question must stay
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
const waitMs = Number(args["wait-secs"] ?? 60) * 1000;
const holdMs = Number(args["hold-secs"] ?? 8) * 1000;
const shotDir = args["shot-dir"];
const label = args.label ?? action;
const actions = ["state", "watch", "answer", "blank", "keep", "gone", "limit"];
if (!actions.includes(action) || !base || !project) {
  console.error(`usage: questions_ui.mjs ${actions.join("|")} --base URL --token T --project ID [--question ID] [--text ANSWER]`);
  process.exit(2);
}
if (["answer", "keep", "limit"].includes(action) && !args.text) {
  console.error(`questions_ui.mjs ${action} needs --text`);
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
  return page.evaluate(() => ({
    heading: document.querySelector("#questions-heading")?.textContent?.replace(/\s+/g, " ").trim() ?? null,
    questions: [...document.querySelectorAll("#questions-pane article")].map((a) => ({
      id: a.id,
      text: a.querySelector(".ws-msg")?.textContent?.trim(),
      meta: a.querySelector("p.ws-muted")?.textContent?.replace(/\s+/g, " ").trim(),
      answer_box: a.querySelector("textarea")?.value ?? null,
      maxlength: a.querySelector("textarea")?.getAttribute("maxlength") ?? null,
      buttons: [...a.querySelectorAll("button")].map((b) => b.textContent.trim()),
    })),
    waiting_on_you: [...document.querySelectorAll('#group-waiting_on_you article.ws-card[id^="thread-"]')].map(
      (c) => c.querySelector("h4")?.textContent?.trim(),
    ),
    working: [...document.querySelectorAll('#group-working article.ws-card[id^="thread-"]')].map(
      (c) => c.querySelector("h4")?.textContent?.trim(),
    ),
    notice: document.querySelector("#notice")?.textContent?.trim() ?? null,
  }));
}

const rowSelector = args.question ? `#questions-pane article[id$="-${args.question}"]` : "#questions-pane article";
const noticeText = async () => (await page.textContent("#notice"))?.trim() ?? "";

try {
  await page.goto(`${base}/dashboard/projects/${encodeURIComponent(project)}?token=${encodeURIComponent(token)}`, { waitUntil: "load" });
  await page.waitForFunction(() => window.liveSocket?.isConnected() && document.querySelector("[data-phx-main] *"), null, { timeout: 20000 });
  log({ event: "connected", url: page.url().replace(/token=[^&]*/, "token=<redacted>") });

  if (action === "state") {
    log({ event: "state", ...(await snapshot()) });
    await shot("state");
  } else {
    const row = page.locator(rowSelector).first();
    const started = Date.now();
    await row.waitFor({ state: "visible", timeout: waitMs });
    const rowId = await row.getAttribute("id");
    log({ event: "question-visible", waited_ms: Date.now() - started, ...(await snapshot()) });
    await shot("before");

    if (action === "answer") {
      await row.getByLabel("Your answer").fill(args.text);
      log({ event: "typed", row: rowId, text: args.text.length > 200 ? `${args.text.slice(0, 80)}... (${args.text.length} characters)` : args.text, text_length: args.text.length, box_length: (await row.getByLabel("Your answer").inputValue()).length });
      await row.getByRole("button", { name: "Answer", exact: true }).click();
      log({ event: "clicked", button: "Answer", row: rowId });
      await page.waitForFunction(() => (document.querySelector("#notice")?.textContent ?? "").trim() !== "", null, { timeout: 20000 });
      log({ event: "notice", text: await noticeText() });
      await page.waitForFunction((id) => !document.getElementById(id), rowId, { timeout: 20000 }).catch(() => {});
      log({ event: "row-after", still_present: (await page.locator(`[id="${rowId}"]`).count()) > 0, ...(await snapshot()) });
      await shot("after");
    } else if (action === "blank") {
      await row.getByLabel("Your answer").fill("   ");
      await row.getByRole("button", { name: "Answer", exact: true }).click();
      log({ event: "clicked", button: "Answer", row: rowId, text: "(whitespace only)" });
      await page.waitForFunction(() => (document.querySelector("#notice")?.textContent ?? "").trim() !== "", null, { timeout: 20000 });
      log({
        event: "notice",
        text: await noticeText(),
        error_styled: await page.evaluate(() => document.querySelector("#notice")?.classList.contains("ws-error") ?? false),
        row_still_present: (await page.locator(`[id="${rowId}"]`).count()) > 0,
      });
      await shot("after");
    } else if (action === "keep") {
      const box = row.getByLabel("Your answer");
      await box.fill(args.text);
      log({ event: "typed", row: rowId, text: args.text });
      await page.locator("#tab-pull_requests").click();
      await page.waitForFunction(() => document.querySelector("#tab-pull_requests")?.getAttribute("aria-selected") === "true", null, { timeout: 10000 });
      log({ event: "focus-moved-and-page-rerendered", active: await page.evaluate(() => document.activeElement?.id ?? document.activeElement?.tagName) });
      log({ event: "after-rerender", answer_box: await box.inputValue() });
      await page.waitForTimeout(holdMs);
      const survivors = (await snapshot()).questions.map((q) => ({ id: q.id, answer_box: q.answer_box }));
      log({ event: "after-hold", hold_ms: holdMs, kept: survivors.find((q) => q.id === rowId)?.answer_box === args.text, questions: survivors });
      await shot("after");
    } else if (action === "limit") {
      const box = row.getByLabel("Your answer");
      const attr = await box.getAttribute("maxlength");
      const limit = Number(attr);
      log({ event: "limit-attribute", row: rowId, maxlength: attr, text_length: args.text.length });
      await box.fill(args.text.slice(0, limit));
      log({ event: "typed-exact-limit", row: rowId, length: (await box.inputValue()).length });
      await box.focus();
      await box.evaluate((el) => el.setSelectionRange(el.value.length, el.value.length));
      await page.keyboard.type("Z");
      log({ event: "typed-one-more-character", row: rowId, length: (await box.inputValue()).length });
      await box.evaluate((el, t) => {
        el.value = t;
        el.dispatchEvent(new Event("input", { bubbles: true }));
      }, args.text);
      log({ event: "value-set-past-limit", row: rowId, length: (await box.inputValue()).length });
      await row.getByRole("button", { name: "Answer", exact: true }).click();
      log({ event: "clicked", button: "Answer", row: rowId, text_length: args.text.length });
      await page.waitForFunction(() => (document.querySelector("#notice")?.textContent ?? "").trim() !== "", null, { timeout: 20000 });
      log({
        event: "notice",
        text: await noticeText(),
        error_styled: await page.evaluate(() => document.querySelector("#notice")?.classList.contains("ws-error") ?? false),
        row_still_present: (await page.locator(`[id="${rowId}"]`).count()) > 0,
        answer_box_length: await box.inputValue().then((v) => v.length).catch(() => null),
      });
      await shot("after");
    } else if (action === "gone") {
      const waitedFrom = Date.now();
      await page.waitForFunction((id) => !document.getElementById(id), rowId, { timeout: waitMs });
      log({ event: "row-gone", after_ms: Date.now() - waitedFrom, ...(await snapshot()) });
      await shot("after");
    }
  }
  if (consoleErrors.length) log({ event: "console-errors", errors: consoleErrors.slice(0, 5) });
  await browser.close();
} catch (e) {
  log({ event: "error", message: String(e).split("\n")[0], state: await snapshot().catch(() => null) });
  await shot("error").catch(() => {});
  await browser.close();
  process.exit(1);
}
