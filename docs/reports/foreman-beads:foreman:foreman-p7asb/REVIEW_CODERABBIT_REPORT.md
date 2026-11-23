

Phase complete.

**CodeRabbit review — `beads:foreman:foreman-p7asb`, run-094b44822fad0645a866d2f5a6cef3ec**

**Engine**: `coderabbit review --agent --base main` (base from `$FOREMAN_BASE_BRANCH`), run twice from the worktree root. Both exit 0, `outcome: "completed"`.

**Round 1** — 2 major findings, both in `packages/foreman_server/test/foreman_server/agents/operator_question_dispatcher_test.exs`:
1. L393 `assert atomized(data) =~ question_id` — `=~` on a map raises `FunctionClauseError`; asserted nothing. **Fixed** → precise map pattern on the `QuestionOpened` fields (`run_id: "global"`, pinned `question_id`/`agent_id`, `timeout_ms: 300_000`), mirroring siblings at L204-207/L228-233.
2. L357 — the two new dispatcher tests sat at module top level while binding `question_id`/`agent_id` that only the question-opening describe setup supplies ⇒ both failed on the context match (baseline: 15/17). **Fixed** → moved both inside `describe "dispatch/1 opens the question (question.open)"`.

**Round 2** — `findings: 0` ⇒ stopped (2 of 3 rounds used). **Declined: none.**

**Verification**
- `mix test …/operator_question_dispatcher_test.exs --warnings-as-errors` → before: exit 2 (15/17, 2 failed); after: exit 0, `Result: 17 passed`
- `mix format` on the file → clean; `mix format --check-formatted` → exit 0
- Report blocks verified programmatically: `ReviewFindings.parse/1` ⇒ `{:recorded, 2 findings, artifact_sha256 …}`, `PrRisk.parse_judgement/1` ⇒ `%{status: "recorded", level: "LOW"}` (marker lines stand alone, outside fences, raw JSON between them)

**Artifacts**
- Report: `docs/reports/foreman-beads:foreman:foreman-p7asb/REVIEW_CODERABBIT_REPORT.md` (5 sections + findings block + risk block)
- Fix left **uncommitted** for Foreman to commit (`git status`: `M` test file, `??` report)
- Progress notes sent: inbox `msg_p7asb_cr_review_done` (sent), task comment added (beads)
- kata: created `wktt`, claimed, closed with test evidence

**Documentation gate** — this phase added/removed/renamed **no** externally visible identifiers (test-only edit + a report file): no command/event type, MCP tool, route, CLI verb, env var, config key, workflow or prompt name. Grepped `CLAUDE.md`, `README.md`, `docs/user-guide.md`, `docs/cli-reference.md`: `question.open` already documented (CLAUDE.md:1164, docs/user-guide.md E8 section); `deduped` no hits; `foreman-run.next-tab`/`prev-tab` no hits but they come from commit 018da6b1 (a different, earlier run's sidebar change), not from this run's diff, and the four gate files are not a sidebar-keybinding reference. None of the four files needed edits — no operator-visible change.