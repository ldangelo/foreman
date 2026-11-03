# Repository-rules review

## Review engine

Reviewer: Foreman repo-rules phase (phase 3), reviewing against this repo's own
`AGENTS.md` (Working Rules, Documentation Gate, §5 Typed Boundaries, Invariants).

Diff range: `git diff "$FOREMAN_BASE_BRANCH"...HEAD` with `FOREMAN_BASE_BRANCH=main`
(confirmed set). Changed source/test files:
- `packages/foreman_server/lib/foreman_server_web/project_workspace_live.ex`
- `packages/foreman_server/lib/foreman_server_web/workspace/components.ex`
- `packages/foreman_server/lib/foreman_server_web/workspace/layouts.ex`
- `packages/foreman_server/test/foreman_server_web/live/project_workspace_live_test.exs`
- `packages/foreman_server/test/foreman_server_web/live/project_workspace_coordinator_live_test.exs`
(plus this run's own `docs/reports/.../*.md`, not reviewed as code).

Carry-forward: the previous phase's `REVIEW_CODERABBIT_REPORT.md` exists but
contains **no** `FOREMAN_REVIEW_FINDINGS_START/END` block — so there was no
machine-readable findings list to copy. Its prose names two unresolved
operator-decision items (accent-contrast token, Show-all text duplication);
both are carried forward in the unresolved block below.

## Findings

Own-review findings against repo rules:

1. Closed role/group vocabularies with loud failure (§5.2/§5.3) — **OK, no action.**
2. `Map.fetch!(@group_chip_kind, group)` totality (§5 compile/loud) — **OK, no action.**
3. Documentation gate — **OK, no action.**
4. Operator-message background deviates from spec token — **Declined** (cosmetic, operator reviews screenshots).

Carried-forward from CodeRabbit phase:
- Accent token contrast — **Declined** (spec pins token literally).
- Show-all text duplication in DOM — **Declined** (spec §4 mandates full text in DOM).

## Fixed

None. The diff already complies with this repo's rules; no narrowest-change fix
was warranted.

## Declined

- **`components.ex` sender/role vocabularies** — `sender_label/1`,
  `message_variant/1`, `coordinator_chip/1` have no permissive catch-all and
  raise on an unknown role/status. Reviewed as *correct*, not a defect: it is
  exactly §5.2 (no catch-all wrapping an unknown value) and §5.3 (loud failure).
  `thread_chip/1`'s `Map.fetch!(@group_chip_kind, group)` is total over
  `Group.all/0` (`[:ready_for_review, :waiting_on_you, :working, :landing,
  :idle, :resolved]`), which the `@group_chip_kind` map covers key-for-key;
  `ThreadCard` enforces `:group`, so the clause always matches. No change.
- **`project_chip_kind/1` catch-all `_status -> "chip--muted"`
  (`project_workspace_live.ex:376`)** — this is a purely cosmetic CSS-class
  picker for an open-ended project status string; a muted default is a display
  fallback, not an error hidden behind a success value. Not a §5.2 violation.
  No change.
- **Operator message background (`layouts.ex`, `.msg--operator`)** — spec §3
  asks for `background: var(--card-2)`; the code uses `var(--card)` because the
  transcript container (`.conv-transcript`) is already `var(--card-2)`, so a
  `card-2` bubble on a `card-2` surface would be invisible. Behaviour kept per
  the spec's "keep the behaviour and say so" rule; operator decides on live
  screenshots.
- **Accent-contrast token / Show-all duplication** (carried from CodeRabbit) —
  both are literal spec mandates; declining to override the spec.

## Verification

Run from the worktree root, `DATABASE_URL`/`EVENTSTORE_URL` unset:

- `devbox run -- bash -c 'cd packages/foreman_server && unset DATABASE_URL EVENTSTORE_URL && MIX_ENV=test mix test --warnings-as-errors test/foreman_server_web/live/project_workspace_live_test.exs test/foreman_server_web/live/project_workspace_coordinator_live_test.exs'`
  → **54 passed**, exit 0.
- `mix format --check-formatted` on the five changed source/test files → exit 0.

Doc gate: grep of `CLAUDE.md`, `README.md`, `docs/`, `docs/lessons/` for the
changed panel headings ("Memory topics", "Library files"), component ids
(`info_panels`, `panel-threads`, `ws-panel`) and `conversation_pane` found hits
only inside this run's own `docs/reports/` artifacts — no user-facing doc, route,
config key, CLI verb, event type or MCP tool changed. No doc file needed editing.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
- `packages/foreman_server/lib/foreman_server_web/workspace/layouts.ex` (`.msg--operator`) Minor — operator bubble uses `var(--card)` not spec §3's `var(--card-2)` (deliberate, for contrast on the `card-2` transcript); confirm on live screenshots.
- `packages/foreman_server/lib/foreman_server_web/workspace/layouts.ex` (`--accent`) Minor — light `--accent #c15f3c` on white may miss 4.5:1; token pinned by spec, operator decision.
- `packages/foreman_server/lib/foreman_server_web/workspace/components.ex` (`info_panels`) Minor — full instructions text is duplicated in the DOM (clamped copy + Show-all copy) per spec §4; operator decision.
<!-- FOREMAN_REVIEW_FINDINGS_END -->
