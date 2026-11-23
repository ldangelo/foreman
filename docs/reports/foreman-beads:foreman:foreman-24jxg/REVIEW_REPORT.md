

Phase complete.

## Review range
`git diff main...HEAD` — 9 files (merge-base `796c888c`, HEAD `2afec107`). `$FOREMAN_BASE_BRANCH=main` set.

## Findings (5)
| sev | file | disp | source |
|---|---|---|---|
| minor | README.md:385 + docs/user-guide.md:2202 | **fixed** | repo-rules |
| minor | REVIEW_CODERABBIT_REPORT.md:30 | open | repo-rules |
| minor | FIX_REPORT.md:1 | open | repo-rules |
| minor | PLAN.md:1 | fixed | coderabbit |
| minor | tools.ex:1891 | fixed | coderabbit |

- **Fixed**: run-status DTO field lists in README.md + user-guide.md omitted `reason` (cli-reference.md:1599 already documented it). Added.
- **Open (other-phase artifacts, not mine to rewrite)**: `REVIEW_CODERABBIT_REPORT.md` claims two machine-read blocks it doesn't contain; `FIX_REPORT.md` is a 4-byte placeholder.
- Implementation itself compliant: one shared projection boundary (`ProjectionStore.pending_run/1`, reused by `RunController.show_pending/2`), loud `ArgumentError` not silent success, `foreman_run_get` deliberately unchanged.

## Verification (exit codes)
- `mix format --check-formatted` (tools.ex, tools_test.exs) → 0
- `mix test test/foreman_server/mcp/tools_test.exs --warnings-as-errors` → 0, 31 passed
- `mix test test/foreman_server/mcp/ --warnings-as-errors` → 0, 217 passed
- `mix test test/foreman_server/mcp/tool_inventory_test.exs` → 0, 8 passed
- docs tests → 0, 6 passed
- `mix test test/foreman_server/dispatcher_test.exs` → **1**, aborted at startup (`ProjectionLeakGuard never saw the end of the suite`), zero test results — cause not established, no claim made
- server parsers on my artifact (`ReviewFindings.read/1`, `PrRisk.parse_judgement/1`) → 0, findings `{:recorded, 5}`, judgement `recorded/MEDIUM`

## Artifact
`docs/reports/foreman-beads:foreman:foreman-24jxg/REVIEW_REPORT.md` — five sections, findings block (schema/reviewed/findings), risk block `MEDIUM` last in file.

Notes: fixes left **uncommitted** (fix.yaml phase `repo-rules-review` has `commit: true`). Inbox note + task Work Log comment sent. `ask_advisor` unavailable (Anthropic refresh token expired → `invalid_grant`).