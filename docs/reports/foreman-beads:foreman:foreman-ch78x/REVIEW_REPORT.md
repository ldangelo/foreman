

Phase complete.

**Repo-rules review** — run-8dec153539dbd49ac86c0a25c6bbc698, task `beads:foreman:foreman-ch78x`

**Diff range**: `FOREMAN_BASE_BRANCH=main`, merge-base `4099cce4`. `git diff main...HEAD` = **2 files, 44 insertions, both phase artifacts**. Zero source/test/doc changes. Working tree clean → nothing to fix, no new violation introduced.

**Reviewer basis**: repo root `AGENTS.md` (the repo's conventions file; no CONTRIBUTING.md).

**Carried findings**: previous phase's `REVIEW_CODERABBIT_REPORT.md` has **no machine-read block** (no `FOREMAN_REVIEW_FINDINGS_START`/`FOREMAN_RISK_JUDGEMENT_START` in its committed 2638 B) despite prose claiming both — its text is truncated mid-sentence (proxy-damaged write). Recovered its one finding from prose and carried it manually with `source: coderabbit`.

**Findings (5)**
| sev | path | disposition |
|---|---|---|
| major | `workflows/fix.yaml:35` (`/enseble:merge-pr`) | **declined — stale**: file at HEAD is byte-identical to `main`/`origin/main` (md5 match), prompt-driven 3-phase, no `command:` key |
| major | `workflow/run_executor.ex:1589` | **open** — base still derived from checkout HEAD via `JobsiteGit.current_branch/1`, no fetch of `origin/<base>` |
| major | `events/run_base_branch_recorded.ex:1` | **open** — event still enforces `[:run_id, :base_branch]`, no base commit SHA |
| major | `REVIEW_CODERABBIT_REPORT.md:1` | **open** — prior artifact not machine-readable |
| minor | `workflows/fix.yaml:27` | **declined** — no plan phase ⇒ `PLAN.md`; pre-existing on `main`, out of scope |

**Verification** (exit codes in report): `mix test test/foreman_server/workflow/catalog_test.exs bundled_workflow_models_test.exs` → **32 passed, 0 failures**; `mix event_store.init` → 0; `mix run --no-start` with real parsers → `ReviewFindings.read/1` = `{:recorded, …}` (5 findings), `PrRisk.parse_judgement/1` = `recorded` / **HIGH**. Ambient `DATABASE_URL` (55434) fails auth → overrode to `foreman_test_ch78x` on 55432.

**Open objective (unchanged, operator action)**: the task's fix is wholly unimplemented — `grep -rn base_ref_policy` → 0 hits repo-wide. Two EXPECTED variants exist (fetch-and-base-on-origin vs. record-SHA-and-surface-behind-count); picking one is an operator/product call, and escalation tools are unavailable here (`foreman_inbox_send`/`foreman_task_add_comment` not exposed, `contact_supervisor` errors outside a subagent, `ask_advisor` fails with Anthropic 400 `invalid_grant`). Also note branch base is **6 commits behind `origin/main`** — the exact stale-base condition the task targets.

Artifact: `docs/reports/foreman-beads:foreman:foreman-ch78x/REVIEW_REPORT.md` (untracked, uncommitted for Foreman).