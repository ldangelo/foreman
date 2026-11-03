Phase 3 repo-rules review complete.

## Result

- **Base:** `FOREMAN_BASE_BRANCH=main` (confirmed). Range `main...HEAD`, 5 source/test files reviewed.
- **Findings / fixes:** no real new violations → **0 fixes**. Diff already complies w/ `AGENTS.md` (§5 typed boundaries, doc gate).
- **Declined:** closed role/group vocab (correct §5.2/§5.3 loud-fail, not a defect); `project_chip_kind` cosmetic catch-all; operator-bubble bg deviation (card vs spec card-2, for contrast); carried-forward CodeRabbit operator-decision items (accent contrast, Show-all DOM duplication).
- **Carry-forward:** prior `REVIEW_CODERABBIT_REPORT.md` had **no** `FOREMAN_REVIEW_FINDINGS` block; its two prose operator-decision items carried into my findings block.

## Verification
- tests (2 affected files, warnings-as-errors, DATABASE_URL/EVENTSTORE_URL unset): **54 passed, exit 0**
- `mix format --check-formatted` (5 files): **exit 0**
- doc gate: no route/config/CLI/event/tool identifier changed; grep hits only in this run's own `docs/reports/`.

Report written to `docs/reports/foreman-coord-2982ba63f6435212/REVIEW_REPORT.md` w/ 3 unresolved (operator-decision) bullets. No source changes to commit; fixes left uncommitted per protocol (none were needed). `.beads/` untouched.