

Phase complete.

**CodeRabbit review — run-8dec153539dbd49ac86c0a25c6bbc698 (task beads:foreman:foreman-ch78x)**

Review engine
- `FOREMAN_BASE_BRANCH=main`; `coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"` from worktree root.
- 6 attempts: r1/r2 failed (WebSocket closed), r3 SIGTERM-interrupted, **r4/r5 completed** → 1 major finding each, **r6 (post-fix)** completed → 0 findings.

Finding (1)
- **major** — `packages/foreman_server/priv/defaults/workflows/fix.yaml:35`: `command: "/enseble:merge-pr --foreman"` → command exists in no registry. **disposition: fixed**.

Fix (uncommitted, 1 file, +13/−5)
- Restored the bundled `fix.yaml` verbatim from the branch's merge base `4099cce4` → prompt-driven 3-phase manifest (fix / coderabbit-review / repo-rules-review). Bogus `/enseble:merge-pr` and the command-based `fix` phase gone.
- CodeRabbit's own suggestion `/ensemble:merge-pr` rejected: ensemble registers `pr-merge`, not `merge-pr`; and branch tests (`catalog_test.exs:142-170`, `prompt_inbox_progress_test.exs:25-40`, `full_workflow_lifecycle_test.exs:510-524`) require `action == :prompt` and forbid any `command:` key — a 1-line typo edit would leave them red.

Verification (all exit 0)
- `mix test test/foreman_server/workflow` → **1564 passed** (363.4s); narrow re-run of the 3 pinned files → 42 passed; `mix format --check-formatted` clean; `grep -rn enselbe .` → only a historical note in `docs/reports/trd-2026-b9e27ab5-...md:83`.

Report
- `docs/reports/foreman-beads:foreman:foreman-ch78x/REVIEW_CODERABBIT_REPORT.md` (10608 B) with 5 sections + both machine-read blocks verified by the real parsers: `ReviewFindings.read/1` → 1 finding (major, fixed); `PrRisk.parse_judgement/1` → `recorded` / **MEDIUM** (rationale 573 chars).

Residual (operator)
- The ch78x task itself (fetch `origin/<base>` before worktree creation, `base_ref_policy`, base SHA in `RunBaseBranchRecorded`, "N commits behind" surfacing) is **still unimplemented** — phase 1 wrote "Blocked: no plan found".
- Branch base is stale vs main's 4-phase plan manifest (`e89fa4da`/#920) → rebase, not merge as-is. `.beads/issues.jsonl` changed on both sides → possible conflict.

Notes
- Doc gate: removed command strings were exactly what the merge base shipped; `CLAUDE.md`/`README.md`/`docs/user-guide.md`/`docs/cli-reference.md` contain no `enseble`/`merge-pr` references → no edits needed.
- `foreman_inbox_send` / `foreman_task_add_comment` not exposed in this phase → no operator push sent. `ask_advisor` failed (Anthropic refresh token expired, `invalid_grant`) — pre-existing environment issue.