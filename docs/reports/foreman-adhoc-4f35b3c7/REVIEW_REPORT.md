# Repo-rules review — run-30ab70c9019bd2df980642a0c395e65f

## Review engine

Repository-rules reviewer (this phase), inline pass over the diff; rules taken from the
repository's own contributor guidance `AGENTS.md` (§Typed Boundaries §5.1–§5.7, §Documentation
Gate, §Invariants) and the `docs/lessons/claude-projects-architecture.md` rule that read-only
workspace panels must use data the server already exposes. No external reviewer CLI used.

**Diff range reviewed:** `git diff "$FOREMAN_BASE_BRANCH"...HEAD` with `$FOREMAN_BASE_BRANCH=main`
— merge-base `4ee1b417` to `HEAD` (`b6d70d41`), branch
`foreman/adhoc-4f35b3c7/run-30ab70c9019bd2df980642a0c395e65f`. Six files, 565 insertions /
83 deletions:

- `packages/foreman_server/lib/foreman_server_web/operator_run_dashboard_live.ex` (+219/−82)
- `packages/foreman_server/lib/foreman_server_web/workspace/layouts.ex` (+6)
- `packages/foreman_server/test/foreman_server_web/operator_run_dashboard_ui_test.exs` (new, 207 lines)
- `docs/reports/foreman-adhoc-4f35b3c7/FIX_REPORT.md` (new)
- `docs/reports/foreman-adhoc-4f35b3c7/REVIEW_CODERABBIT_REPORT.md`, `REVIEW_REPORT.md` (this file)

**Previous phase's findings:** `docs/reports/foreman-adhoc-4f35b3c7/REVIEW_CODERABBIT_REPORT.md`
is 57 bytes and contains **no `FOREMAN_REVIEW_FINDINGS_START`/`END` block** — nothing to carry
forward from CodeRabbit. The carry-forward requirement is satisfied as nil.

## Findings

Report-only phase (per operator instruction): **zero source files were edited here.** Every
finding below was verified line-by-line against working-tree files at `HEAD` before recording it.

- **F1 — the earlier phases' committed reports misstate this diff and their own validation.
  Fix required: regenerate or annotate them.**
  `FIX_REPORT.md` and the pre-existing `REVIEW_REPORT.md` claim the run touched
  `operator_dashboard.ex`, `workspace/components.ex`, `workspace/nav_runs.ex`,
  `aggregates/run.ex`, `change_evidence.ex`, `router.ex`,
  `test/.../operator_run_dashboard_live_test.exs`, and
  `test/support/projection_store_reset.ex`, and report "49 tests, 0 failures". None of those files
  is in `git diff main...HEAD` (the four code/test files never even appear in any commit of the
  run branch, and `git cat-file -e main:packages/foreman_server/test/foreman_server_web/operator_run_dashboard_ui_test.exs`
  proves `ui_test.exs` is new in this run). `AGENTS.md` §"A failing test is a failed build" and
  the loud-failure principle make a validation claim that doesn't match the diff a defect report,
  not decoration. Severity: **Major**.
- **F2 — §5.2/§5.3: silent degradation to a plausible-looking default.**
  `operator_run_dashboard_live.ex:658` `Map.get(@chip_kinds, status, "muted")`: a run/phase status
  the projection starts emitting (e.g. `needs_recovery`, `unresponsive` — both live in
  `lib/foreman_server/overview/group.ex:117` and `lib/foreman_server/coordinator/context.ex:138`)
  renders as a muted, settled-looking chip. `:659` `chip_kind(_) -> "muted"` swallows
  non-binaries. Same pattern at `:488-492` (`entry_kind(_)` → `msg--system`) and `:561-566`
  (`change_kind(_)` → `chip--muted`). Narrowest fix: raise (or log-and-flag) on unmapped
  vocabulary, or partition the maps by run-vs-phase status. Severity: **Major**.
- **F3 — §5.1/§5.7: the `ChangeEvidence` boundary is re-implemented inside the LiveView.**
  `operator_run_dashboard_live.ex:555-560` (`change_kind/1`, porcelain letters) and `:621-633`
  (`live_status?/1` with its own `~w(live live_partial pending)` literals) duplicate status
  vocabulary owned by `ForemanServerWeb.OperatorDashboard.ChangeEvidence`
  (`lib/foreman_server_web/operator_dashboard/change_evidence.ex:66` `@known_status`,
  `:248-257` `status?/2`). Two files will now disagree on what a status means. Fix: export/use
  `ChangeEvidence.status?/2` (or a shared classifier module) from the template. Severity: **Major**.
- **F4 — §5.1: open-data map reaches presentation without normalization.**
  `operator_run_dashboard_live.ex:530` `meta: Map.get(changes, :meta)` then `:584` renders
  `meta[:live_status]`, `meta[:partial_reason]`, `meta[:error]`, `meta[:pr_url]` with a catch-all.
  Keys are never declared, so a rename on the producer side vanishes silently. Fix: a typed
  struct (with `@enforce_keys`/`@type t`) or a whitelist-normalized, documented key list at the
  boundary. Severity: Minor.
- **F5 — §5.1: exception struct leaks its module name through the error path.**
  `operator_run_dashboard_live.ex:155` `describe(@error)` falls through `describe/1`'s
  `is_atom` clause onto `inspect/1` (`:640`) for tuple/struct reasons, so an operator can see
  `%ForemanServer.Errors.NotFoundError{...}`. The detail-error branch (`:262`) already formats
  the same kind of reason properly via `Errors.error_payload` (`lib/foreman_server/errors.ex:32`).
  Fix: route `@error` through `Errors.error_payload/1`. Severity: Minor.
- **F6 — the structural guard is unsound in both directions, and will mislead the next pass.**
  `operator_run_dashboard_ui_test.exs:157-160` `styled_classes/0` scans every `.name` in
  `layouts.ex`, including CSS declarations (`:root { --muted: … }`, `font-size: 12px`, `flex: none`)
  and any selector inside comments — e.g. the new comment added by this run
  (`workspace/layouts.ex:213-215` mentions `.ws-layout`) counts as a styled class. And
  `:148-150` `emitted_classes/0` hard-codes `~w(ok info warn err muted)` as the only dynamic
  suffixes, so a chip class produced by an unmapped status can never be caught. Fix: strip
  `[...]`-selectors and declaration blocks before scanning, and enumerate the dynamic classes from
  `@chip_kinds` in the source rather than a hardcoded list. Severity: Minor (test hygiene,
  §"never assert mock behavior / pin the real contract").
- **F7 — new `.thread-dot--muted` has no `color` fallback and no text.**
  `workspace/layouts.ex:163` gives the dot `background: var(--muted)`; `--muted` is a grey the
  theme file also uses for body text (`:17`). `operator_run_dashboard_live.ex` renders the dot
  `aria-hidden="true"` and lets `chip_kind` decide the label, so this is a contrast/legibility
  observation only, not a correctness break. Declined as **informational**: no repo rule violated,
  and it matches how the sibling `thread-dot--*` modifiers are written.
- **F8 — documentation gate for the restyled page.**
  Grep of the nine removed CSS class names (`operator-run-dashboard`, `dashboard-layout`,
  `run-list`, `run-detail`, `focus-marker`, `dashboard-stale`, `dashboard-error`,
  `dashboard-action-result`, `dashboard-detail-error`) across `CLAUDE.md`, `README.md`,
  `docs/user-guide.md`, `docs/cli-reference.md`: zero hits — nothing stale to fix. `docs/user-guide.md`
  describes `/dashboard/runs` at `:1348-1380` and `:2576` without naming any of them, so no
  operator-visible change requires an edit there. `docs/PRD/PRD-2026-c7977e9d-*` and
  `docs/TRD/TRD-2026-c7977e9d-*` do name the removed classes; per `AGENTS.md` point-in-time specs
  stay as written — this is the documented "no edit needed", not silence. Verdict: **Declined
  (compliant)**.
- **F9 — pre-existing dead classes elsewhere in the workspace.**
  `workspace/components.ex:138/403/408/412/564` emit `ws-nav-run`, `ws-nav-branch`,
  `ws-nav-worktree`, `ws-nav-pr`, `ws-nav-trd`, `ws-nav-docs`, `ws-nav-conversation`,
  `ws-add-files`, `ws-showall`, `thread-earlier` with no rule in `workspace/layouts.ex` (verified
  present in `main`, untouched by this run). The same defect class this run fixed for the
  dashboard, now visible in a file this run did not touch. Fixing it is a separate scope decision,
  so it is listed in unresolved findings rather than done here. Severity: Minor.
- **F10 — copy still says "Existing Jido dashboard remains at `/dashboard`."**
  `operator_run_dashboard_live.ex:147` now lives inside the shared `ws-main` shell, while
  `/dashboard` itself (`live_dashboard.ex:62,64`) keeps its old unstyled classes. The sentence is
  accurate but now juxtaposed against the restyled page; a one-line wording tweak is all that's
  warranted. Listed as unresolved, severity Minor.

## Fixed

None. Report-only phase (operator instruction: choose option 2, do not apply fixes, do not edit
source files). No file other than this report was changed; scratch diff files created during the
pass were deleted (`git status --porcelain` clean apart from this report).

## Declined

- F7 — informational; matches sibling `thread-dot--*` convention, no rule violated.
- F8 — documentation gate satisfied by grep evidence above; no externally visible identifier was
  added, removed or renamed (no routes, config keys, env vars, CLI verbs or tools in the diff).

## Verification

- `git rev-parse --abbrev-ref HEAD` → `foreman/adhoc-4f35b3c7/run-30ab70c9019bd2df980642a0c395e65f`;
  `$FOREMAN_BASE_BRANCH` → `main` (exit 0).
- `git diff main...HEAD --stat` → 6 files, 565(+/83−) (exit 0); per-file diff reviewed line by line.
- `git grep -n "needs_recovery\|unresponsive\|status_class\|live_status?" main -- packages/foreman_server/lib`
  → hits only in `overview/group.ex:117`, `coordinator/context.ex:138`, `change_evidence.ex:66,248-257`
  (exit 0). No `raise`-based classifier and no `run_chip_kind/phase_chip_kind` exists anywhere
  (exit 1) — i.e. the `REVIEW_CODERABBIT_REPORT.md`-era fixes that earlier report text describes
  were never applied.
- `grep -c . FOREMAN_REVIEW... REVIEW_CODERABBIT_REPORT.md` → file is 57 bytes, no findings block.
- **Not run in this phase:** `mix compile --warnings-as-errors`, `mix test`,
  `mix format --check-formatted`. Per the report-only instruction nothing was changed to
  re-verify, so the earlier reports' "49 tests 0 failures" claims are **not** reproduced or
  endorsed here — see F1.

## Verdict (honest)

The code diff itself is a disciplined, in-scope UI restyle: it stays on the read-only server data
`OperatorDashboard` already exposes (no new commands/events — the workspace rule holds), it uses
`describe/1` to stop leaking atoms, and it adds a genuinely useful structural test. Against
`AGENTS.md` its real gaps are the three silent-default/cross-boundary-duplication issues (F2, F3)
and the unsound test guard (F6). The most consequential finding is not in the code at all: the
reports committed by phases 1–2 describe a different, larger change set than this branch contains
(F1) — that must be corrected before the PR reads as trustworthy. No compile or tests were run by
this phase; the diff's claims of green tests are unverified.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
- `docs/reports/foreman-adhoc-4f35b3c7/FIX_REPORT.md:1-123` Major — the committed fix report (and the pre-existing REVIEW_REPORT.md) lists files never touched by this run (`operator_dashboard.ex`, `components.ex`, `nav_runs.ex`, `aggregates/run.ex`, `change_evidence.ex`, `router.ex`, two test files) and claims "49 tests, 0 failures"; regenerate or annotate it to describe the real 6-file diff.
- `packages/foreman_server/lib/foreman_server_web/operator_run_dashboard_live.ex:658-659` Major — `Map.get(@chip_kinds, status, "muted")` + `chip_kind(_) -> "muted"` degrade an unmapped run/phase status (`needs_recovery`, `unresponsive` exist in `overview/group.ex:117`, `coordinator/context.ex:138`) to a settled-looking chip, violating §5.2/§5.3 loud-failure; same catch-all at `:488-492` (`entry_kind`) and `:561-566` (`change_kind`).
- `packages/foreman_server/lib/foreman_server_web/operator_run_dashboard_live.ex:555-560,621-633` Major — `change_kind/1` and a private `live_status?/1` re-implement `ChangeEvidence` status vocabulary (`@known_status` `change_evidence.ex:66`, `status?/2` `:248-257`) inside the LiveView, duplicating a boundary across files (§5.7).
- `packages/foreman_server/lib/foreman_server_web/operator_run_dashboard_live.ex:530,584` Minor — open `meta` map consumed with undeclared keys and a catch-all clause; normalize to a typed struct or documented whitelist at the boundary (§5.1).
- `packages/foreman_server/lib/foreman_server_web/operator_run_dashboard_live.ex:155` Minor — `describe(@error)` falls through to `inspect/1` (`:640`) for non-atom reasons, leaking exception struct names; reuse `Errors.error_payload/1` as the detail-error branch already does (`:261`).
- `packages/foreman_server/test/foreman_server_web/operator_run_dashboard_ui_test.exs:148-160` Minor — `styled_classes/0` counts CSS declarations and commented-out selector names as styled classes, and `emitted_classes/0` hardcodes `~w(ok info warn err muted)`, so unmapped status chips can never be caught; derive suffixes from `@chip_kinds` and strip `[...]`/declaration blocks.
- `packages/foreman_server/lib/foreman_server_web/workspace/components.ex:138,403,408,412,564` Minor — pre-existing (present in `main`, untouched): `ws-nav-run`, `ws-nav-branch`, `ws-nav-worktree`, `ws-nav-pr`, `ws-nav-trd`, `ws-nav-docs`, `ws-nav-conversation`, `ws-add-files`, `ws-showall`, `thread-earlier` have no rule in `workspace/layouts.ex`; the same dead-class defect this run fixed for the dashboard, needs its own pass.
- `packages/foreman_server/lib/foreman_server_web/live_dashboard.ex:62,64` Minor — pre-existing: `/dashboard` and `/admin` still use `jido-live-dashboard` / `dashboard-meta`, classes no stylesheet defines, so that page stays unstyled while `/dashboard/runs` is now on the shared shell.
- `packages/foreman_server/lib/foreman_server_web/operator_run_dashboard_live.ex:147` Minor — "Existing Jido dashboard remains at `/dashboard`" copy now sits inside the restyled shell; wording tweak only.
<!-- FOREMAN_REVIEW_FINDINGS_END -->
