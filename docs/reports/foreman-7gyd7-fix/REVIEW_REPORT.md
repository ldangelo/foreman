Repo-rules review done.

**Range**: `git diff main...HEAD` (FOREMAN_BASE_BRANCH=main, local main == origin/main == 4f37fa96, merge-base 1334dc59, HEAD 0a48c32a) → 11 files, +375/-1.

**Carry-forward**: none — prior `REVIEW_CODERABBIT_REPORT.md` is a captured tool-call wrapper, no findings block.

**Fixed (4)**
1. `packages/foreman_server/CHANGELOG.md` — no `Unreleased/Fixed` entry for new prompt keys + stale `~/.foreman/workflows` copies → bullet added at L7 (names `foreman init --force` / `foreman workflow install`).
2. `docs/user-guide.md:2796` — `{{task.title}}`/`{{task.description}}` undocumented → §13 Delivery paragraph now names both, empty-string rule, bundled prompts rendering them, and the `FOREMAN_TASK_TITLE`/`FOREMAN_TASK_DESCRIPTION` env channel for `command:` phases.
3. `run_executor_test.exs:4380` — added statement not format-clean ⇒ CI gate fails → `mix format` (base commit was clean ⇒ run's fault).
4. `run_executor_prompt_section_test.exs:210` — same format-gate failure → `mix format`.

**Declined (3)**
- `render_for_test/2` mirrors private `render_prompt_template/6` (private ⇒ can't call; public `prompt_template_assigns/5` pinned separately).
- `review-repo-rules.md:169` / `review-coderabbit.md:149` still render only `{{#section input.prompt}}` — task scoped `review-*` out; flagged as operator follow-up.
- prior-phase artifacts are junk one-liners — `docs/reports/` off-limits.

**Verification** (exit codes)
- `mix test --warnings-as-errors` on `run_executor_prompt_section_test.exs` + `run_executor_test.exs` → 62 passed, 0 (before and after fixes)
- `mix format --check-formatted` on 3 changed Elixir files → 0; HEAD versions → 1 (reproduced findings 3/4)
- report JSON/marker check → each marker exactly once, standalone, JSON parses, 7 findings (4 fixed / 3 declined), risk MEDIUM

**Report**: `docs/reports/foreman-7gyd7-fix/REVIEW_REPORT.md` (5 sections + findings block + risk block).

**State**: fixes UNCOMMITTED (4 modified files + new report) — Foreman commits. Kata `c777` claimed/commented/closed with test evidence. `foreman_inbox_send`/`foreman_task_add_comment` unavailable this phase ⇒ no operator/task notes sent (kata comment used).