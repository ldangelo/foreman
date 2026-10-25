#!/usr/bin/env node
// Browser a11y / keyboard-path / idle-traffic check for the Foreman LiveView
// workspace and settings pages. See docs/spikes/E16-SP1.md.
//
//   node ui_a11y.mjs --base http://localhost:47671 --token <api token> \
//        --project <id> [--idle-seconds 10] [--max-idle-frames 2] \
//        [--report docs/lessons/ui-a11y-report-YYYY-MM-DD.md]
//
// Exit 0 only when: zero serious/critical axe violations, every keyboard
// expectation holds and idle LiveView frames <= --max-idle-frames.
import { chromium } from "playwright";
import { createRequire } from "node:module";
import { writeFileSync } from "node:fs";

const require = createRequire(import.meta.url);
const axePath = require.resolve("axe-core/axe.min.js");

const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, a, i, all) => {
    if (a.startsWith("--")) acc.push([a.slice(2), all[i + 1] && !all[i + 1].startsWith("--") ? all[i + 1] : "true"]);
    return acc;
  }, []),
);
const base = args.base ?? process.env.FOREMAN_UI_BASE ?? "http://localhost:4766";
const token = args.token ?? process.env.FOREMAN_API_TOKEN ?? "";
const project = args.project ?? process.env.FOREMAN_UI_PROJECT;
const idleSeconds = Number(args["idle-seconds"] ?? 10);
const maxIdleFrames = Number(args["max-idle-frames"] ?? 2);
if (!project) throw new Error("--project (or FOREMAN_UI_PROJECT) is required");

const pages = [
  { name: "workspace", path: `/dashboard/projects/${project}` },
  { name: "settings", path: `/dashboard/projects/${project}/settings` },
  // The run dashboard shares the workspace root layout (foreman-70eq6): it must mount a
  // LiveSocket and pass axe like the others. It is outside the idle-traffic check because
  // it refreshes itself on a 2 s timer by design (OperatorRunDashboardLive).
  { name: "runs", path: `/dashboard/runs`, idle: false },
];
const url = (p) => `${base}${p}?token=${encodeURIComponent(token)}`;

const failures = [];
const lines = [];
const fail = (m) => { failures.push(m); lines.push(`- **FAIL** ${m}`); };
const ok = (m) => lines.push(`- ok: ${m}`);

const browser = await chromium.launch({ headless: true });
const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 } });

// The workspace layout bootstraps `window.liveSocket`; mounted == socket connected
// and the main LiveView container has rendered children.
async function connected(page) {
  await page.waitForFunction(
    () => window.liveSocket?.isConnected() && document.querySelector("[data-phx-main] *"),
    null,
    { timeout: 15000 },
  );
}

async function open(p) {
  const page = await ctx.newPage();
  await page.goto(url(p), { waitUntil: "load" });
  await connected(page);
  return page;
}

// ---- 1. axe scans -------------------------------------------------------
const axeRows = [];
for (const p of pages) {
  const page = await open(p.path);
  await page.addScriptTag({ path: axePath });
  const res = await page.evaluate(() =>
    // eslint-disable-next-line no-undef
    axe.run(document, { runOnly: { type: "tag", values: ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "best-practice"] } }),
  );
  for (const v of res.violations) {
    axeRows.push({ page: p.name, id: v.id, impact: v.impact, help: v.help, nodes: v.nodes.map((n) => n.target.join(" ")).slice(0, 5) });
    if (v.impact === "serious" || v.impact === "critical") {
      fail(`axe ${p.name}: ${v.id} (${v.impact}) ${v.help} -> ${v.nodes.map((n) => n.target.join(" ")).slice(0, 3).join(" | ")}`);
    }
  }
  ok(`axe ${p.name}: ${res.violations.length} violation(s), ${res.passes.length} rules passed`);
  await page.close();
}

// ---- 2. keyboard paths --------------------------------------------------
async function tabTo(page, predicate, max = 80) {
  const seq = [];
  for (let i = 0; i < max; i++) {
    await page.keyboard.press("Tab");
    const info = await page.evaluate(() => {
      const e = document.activeElement;
      const cs = e ? getComputedStyle(e) : null;
      return e && e !== document.body
        ? {
            tag: e.tagName.toLowerCase(),
            id: e.id,
            name: e.getAttribute("name"),
            label: (e.getAttribute("aria-label") || e.textContent || "").trim().slice(0, 40),
            type: e.getAttribute("type"),
            visibleFocus: cs.outlineStyle !== "none" && parseFloat(cs.outlineWidth) > 0 || cs.boxShadow !== "none",
          }
        : null;
    });
    if (!info) continue;
    seq.push(info);
    if (!info.visibleFocus) fail(`focus not visible on ${info.tag}#${info.id} "${info.label}"`);
    if (predicate(info)) return seq;
  }
  return null;
}

{
  const page = await open(pages[0].path);
  const seq = await tabTo(page, (i) => i.tag === "textarea" && i.name === "text");
  if (!seq) fail("workspace: composer textarea not reachable by Tab");
  else {
    ok(`workspace: composer reached by keyboard after ${seq.length} stops: ${seq.map((s) => `${s.tag}${s.id ? "#" + s.id : ""}[${s.label}]`).join(" > ")}`);
    // composer then its Send button
    await page.keyboard.press("Tab");
    const send = await page.evaluate(() => ({ tag: document.activeElement.tagName.toLowerCase(), type: document.activeElement.getAttribute("type"), label: document.activeElement.textContent.trim() }));
    if (send.tag === "button" && send.type === "submit") ok(`workspace: Tab from composer lands on submit button "${send.label}"`);
    else fail(`workspace: Tab after composer landed on ${JSON.stringify(send)}, expected the Send submit button`);
    // first thread action (only when the project has thread cards)
    const hasThreads = (await page.locator('[role="group"][aria-label^="Actions for "]').count()) > 0;
    if (!hasThreads) fail("workspace: project has no thread cards; seed at least one thread before running this check");
    else {
      const more = await tabTo(page, (i) => i.tag === "button" && /^(Pause|Resume|Stop|Resolve|Reopen)$/.test(i.label), 40);
      if (!more) fail("workspace: no thread action button reachable by Tab after the composer");
      else ok(`workspace: first thread action "${more.at(-1).label}" reached by keyboard ${more.length} stops after the composer Send button`);
    }
  }
  await page.close();
}
{
  const page = await open(pages[1].path);
  const seq = await tabTo(page, (i) => i.tag === "button" && i.type === "submit" && /Save settings/.test(i.label), 120);
  if (!seq) fail("settings: 'Save settings' not reachable by Tab");
  else {
    const idx = (f) => seq.findIndex(f);
    const instr = idx((s) => s.id === "settings_instructions");
    const save = idx((s) => /Save settings/.test(s.label));
    if (instr >= 0 && instr < save) ok(`settings: instructions textarea (stop ${instr + 1}) precedes Save settings (stop ${save + 1}) in focus order`);
    else fail(`settings: focus order wrong, instructions=${instr} save=${save}`);
    // keyboard operation: Enter on Save must produce the polite status region text
    await page.keyboard.press("Enter");
    await page.waitForFunction(() => document.getElementById("notice")?.textContent.trim().length > 0, null, { timeout: 8000 })
      .then(() => ok("settings: Enter on Save settings updated the aria-live #notice region"))
      .catch(() => fail("settings: Save via keyboard produced no message in #notice"));
  }
  await page.close();
}

// ---- 3. idle websocket traffic -----------------------------------------
const idle = [];
for (const p of pages.filter((q) => q.idle !== false)) {
  const page = await ctx.newPage();
  let sent = [], recv = [], armed = true;
  page.on("websocket", (ws) => {
    ws.on("framesent", (f) => armed && sent.push(f.payload));
    ws.on("framereceived", (f) => armed && recv.push(f.payload));
  });
  await page.goto(url(p.path), { waitUntil: "load" });
  await connected(page);
  await page.waitForTimeout(1500); // let mount-time pushes settle
  const mountFrames = sent.length + recv.length;
  armed = false; sent = []; recv = []; armed = true;
  await page.waitForTimeout(idleSeconds * 1000);
  const isHeartbeat = (s) => typeof s === "string" && s.includes('"heartbeat"');
  const total = sent.length + recv.length;
  const nonHb = [...sent, ...recv].filter((s) => !isHeartbeat(s)).length;
  idle.push({ page: p.name, total, nonHeartbeat: nonHb, mountFrames });
  if (mountFrames === 0) fail(`idle ${p.name}: frame listener saw 0 mount frames, the counter is not observing the socket`);
  if (nonHb > maxIdleFrames) fail(`idle ${p.name}: ${nonHb} LiveView frames in ${idleSeconds}s (max ${maxIdleFrames})`);
  else ok(`idle ${p.name}: ${nonHb} non-heartbeat frame(s) (${total} total) in ${idleSeconds}s`);
  await page.close();
}
await browser.close();

// ---- report -------------------------------------------------------------
const stamp = new Date().toISOString();
const md = [
  `# UI accessibility report`,
  ``,
  `Generated ${stamp} by \`scripts/e2e/ui-a11y/ui_a11y.mjs\` against ${base} (project \`${project}\`).`,
  ``,
  `## Result: ${failures.length === 0 ? "PASS" : "FAIL"}`,
  ``,
  ...lines,
  ``,
  `## axe violations (all impacts, wcag2a/aa/21a/21aa + best-practice)`,
  ``,
  axeRows.length ? `| page | rule | impact | help | first nodes |\n|---|---|---|---|---|\n` + axeRows.map((r) => `| ${r.page} | ${r.id} | ${r.impact} | ${r.help} | ${r.nodes.join(", ").replace(/\|/g, "\\|")} |`).join("\n") : "none",
  ``,
  `## Idle traffic`,
  ``,
  idle.map((i) => `- ${i.page}: ${i.nonHeartbeat} non-heartbeat / ${i.total} total frames in ${idleSeconds}s (counter sanity: ${i.mountFrames} frames seen during mount)`).join("\n"),
  ``,
].join("\n");
if (args.report) writeFileSync(args.report, md);
console.log(md);
process.exit(failures.length === 0 ? 0 : 1);
