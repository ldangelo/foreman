Phase 4 (repo-rules review) complete.

**Diff reviewed:** `git diff main...HEAD` (merge-base `db20c66a`…HEAD `9d022987`) — 3 report files only. The `ingest/1` `[:started, :deduped]` change plus its two tests are **not** in that range; `PLAN.md` §1 uses the 2-dot range and records the code as pre-existing at branch creation (commits `26467648`/`e5f772a4`/`6f46d735`), so I reviewed the code in the working-tree state against `AGENTS.md` and said so in §1. `.beads/issues.jsonl` and `docs/lessons/run-logs-known-issues.md` appear in the 2-dot diff but are main drift (commits `0988b071`, `8a87a312`), not this branch's.

**Fixed (4):**
- `REVIEW_CODERABBIT_REPORT.md` — phase-3 commit step replaced it with prose, dropping the `foreman.review_findings/1` block (so `record_review_findings/3` saw `:absent`) and overwriting the judgement with a second findings doc. Restored byte-identical from `5a187245` (sha256 `042ab395…` both sides).
- `FIX_REPORT.md` — held one stray narration line, not the six sections `priv/defaults/workflows/prompts/fix.md` requires; no prior version in any ref. Authored the six sections from `PLAN.md` §2/§4/§5 plus this phase's own runs.
- `CLAUDE.md:1164` (E8) and `docs/user-guide.md:3425` — deduped-still-opens + timer-armed-once undocumented (`grep -n dedup` hit only Notifier `dedupe_window_ms`). One clause/sentence each.

**Declined (2, both pre-existing, `PLAN.md` §6 out of scope):** dual-key `Map.get(data,"question_id") || Map.get(data,:question_id)` at dispatcher `:61,63,65,75` (`AGENTS.md` §5.4); `record_question/4` logging a failed open and returning `:ok` (§5.2/§5.3) — recorded as a follow-up in `FIX_REPORT.md` §6 instead.

**Carried:** both coderabbit majors (`…_test.exs:393`, `:357`), copied verbatim with `source: coderabbit`, `fixed`.

**Verification:** 5-file `mix test --warnings-as-errors` (dispatcher, flow, webhook, `tool_inventory_test`, `observability/docs_test` — added because they parse the two doc files I edited) ⇒ **36 passed, exit 0**; `mix format --check-formatted` ⇒ **exit 0**. Final `git diff main` re-read found no new violation.

**Artifacts:** `docs/reports/foreman-beads:foreman:foreman-p7asb/REVIEW_REPORT.md` — 5 sections, `foreman.review_findings/1` (8 findings: 2 carried + 6 own), own `foreman.risk_judgement/1` = MEDIUM. Blocks validated by parser script (1 findings + 1 judgement per file, keys/severities/dispositions conform). Kata `8bk7` created and closed with the test command as evidence. All fixes left uncommitted for Foreman.