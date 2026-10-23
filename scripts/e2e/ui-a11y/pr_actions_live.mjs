#!/usr/bin/env node
// Drives the workspace PR action buttons of ONE thread card in a real browser.
// Used by scripts/e2e/claude_projects/github_extras.sh against a real GitHub PR; it
// prints one JSON object on stdout and exits 0 unless the page, the card or the
// requested click could not be exercised.
//
//   node pr_actions_live.mjs --base http://127.0.0.1:4810 --token <api token> \
//        --project <id> --thread run:run-abc... \
//        [--click fix_ci|address_comments|resolve_conflicts|create_pr] \
//        [--shot <png path>] [--settle-ms 4000]
//
// Reported: for each of the four buttons whether it exists, is enabled and the visible reason
// next to a disabled one; every button label inside the card (a merge/approve control must never
// be among them, the merge gate is operator-only CLI/HTTP) and on the whole page; and, after a
// click, the text and kind of the `#notice` status line the LiveView sets.
import { chromium } from "playwright";

const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, a, i, all) => {
    if (a.startsWith("--")) acc.push([a.slice(2), all[i + 1] && !all[i + 1].startsWith("--") ? all[i + 1] : "true"]);
    return acc;
  }, []),
);
const base = args.base ?? process.env.FOREMAN_UI_BASE;
const token = args.token ?? process.env.FOREMAN_API_TOKEN ?? "";
const project = args.project ?? process.env.FOREMAN_UI_PROJECT;
const thread = args.thread;
const click = args.click;
const settleMs = Number(args["settle-ms"] ?? 4000);
const kinds = ["fix_ci", "address_comments", "resolve_conflicts", "create_pr"];

if (!base || !project || !thread) throw new Error("--base, --project and --thread are required");
if (click && !kinds.includes(click)) throw new Error(`--click must be one of ${kinds.join(", ")}`);

const result = { thread, click: click ?? null, buttons: {}, card_buttons: [], page_buttons: [], merge_controls: [] };
const browser = await chromium.launch({ headless: true });
try {
  const page = await (await browser.newContext({ viewport: { width: 1280, height: 1100 } })).newPage();
  await page.goto(`${base}/dashboard/projects/${project}?token=${encodeURIComponent(token)}`, { waitUntil: "load" });
  await page.waitForFunction(() => window.liveSocket?.isConnected() && document.querySelector("[data-phx-main] *"), null, { timeout: 20000 });

  const card = page.locator(`[id="thread-${thread}"]`);
  await card.waitFor({ state: "visible", timeout: 20000 });
  result.card_title = (await card.locator("h4").first().textContent())?.trim() ?? null;
  result.card_status_line = ((await card.locator("p.ws-muted").first().textContent()) ?? "").replace(/\s+/g, " ").trim();
  result.card_group = await card.evaluate((el) => el.closest("section")?.getAttribute("aria-label") ?? el.closest("section")?.querySelector("h3")?.textContent?.trim() ?? null);

  const inspect = async () => {
    const out = {};
    for (const kind of kinds) {
      const btn = page.locator(`[id="pr-action-${thread}-${kind}"]`);
      if ((await btn.count()) === 0) {
        out[kind] = { present: false };
        continue;
      }
      const reasonId = await btn.getAttribute("aria-describedby");
      out[kind] = {
        present: true,
        label: ((await btn.textContent()) ?? "").trim(),
        enabled: await btn.isEnabled(),
        reason: reasonId ? ((await page.locator(`[id="${reasonId}"]`).textContent()) ?? "").trim() : null,
      };
    }
    return out;
  };
  const labels = async (scope) =>
    (await scope.locator("button, [role=button], input[type=submit]").allTextContents()).map((t) => t.replace(/\s+/g, " ").trim()).filter(Boolean);

  result.buttons = await inspect();
  result.card_buttons = await labels(card);
  result.page_buttons = await labels(page.locator("body"));
  result.merge_controls = [...new Set([...result.card_buttons, ...result.page_buttons])].filter((t) => /merge/i.test(t));
  result.pr_actions_aria = await card.locator('[role="group"][aria-label^="Pull request actions for"]').count();

  if (args.shot) {
    await card.screenshot({ path: args.shot.replace(/\.png$/, "") + "-before.png" });
  }

  if (click) {
    const target = result.buttons[click];
    if (!target?.present) throw new Error(`button ${click} is not rendered on the card`);
    if (!target.enabled) throw new Error(`button ${click} is disabled: ${target.reason}`);
    await page.locator("#notice").evaluate((el) => (el.textContent = ""));
    await page.locator(`[id="pr-action-${thread}-${click}"]`).click();
    await page.waitForFunction(() => (document.querySelector("#notice")?.textContent ?? "").trim() !== "", null, { timeout: 30000 });
    result.notice = ((await page.locator("#notice").textContent()) ?? "").trim();
    result.notice_is_error = (await page.locator("#notice").getAttribute("class"))?.includes("ws-error") ?? false;
    await page.waitForTimeout(settleMs);
    result.buttons_after = await inspect();
    if (args.shot) await card.screenshot({ path: args.shot.replace(/\.png$/, "") + "-after.png" });
  }
  console.log(JSON.stringify(result));
} catch (error) {
  result.error = String(error?.message ?? error);
  console.log(JSON.stringify(result));
  process.exitCode = 1;
} finally {
  await browser.close();
}
