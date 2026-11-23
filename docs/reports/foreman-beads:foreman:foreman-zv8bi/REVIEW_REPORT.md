# Repository rules review — `base_ref_policy` project setting

Task: `beads:foreman:foreman-zv8bi` · Run: `run-59f7dec0c17ee9867d8c48735ac5416d` · Phase 4 (`repo-rules-review`, workflow `fix`)

## Review engine

- Reviewer: repository-rules review phase, running in the run's own worktree. Phase index 4 of the `fix` workflow (`packages/foreman_server/priv/defaults/workflows/fix.yaml`: plan → fix → coderabbit-review → repo-rules-review).
- Diff base: `$FOREMAN_BASE_BRANCH=main`, as required. The committed range at phase start, `git diff main...HEAD`, was **three added files under `docs/reports/foreman-beads:foreman:foreman-zv8bi/`** (`PLAN.md` +215, `FIX_REPORT.md` +1, `REVIEW_CODERABBIT_REPORT.md` +17) and **no production code at all** — the bead's feature did not exist anywhere in the branch. During this phase the working tree carried the implementation (14 files, `git diff main`).
- Rules applied: `AGENTS.md` (documentation gate, §5 typed boundaries, surgical changes, "a failing test is a failed build"), `CLAUDE.md` §24/§26 (project-settings whitelist; operator-only settings; "a new setting is one entry there plus the CLI flag (`packages/foreman_cli/cmd/foreman/project.go`) and the settings table in `docs/user-guide.md`"), plus the codebase's own established patterns (mirroring `notification_preference` for an enum-shaped setting, `required_checks`/`repo_allowlist` for operator-only settings).
- **The previous phase's findings block is not readable at `HEAD`.** Foreman's phase-3 commit (`f72547d7`) replaced the phase agent's `REVIEW_CODERABBIT_REPORT.md` (commit `c678205f`, 158 lines, both machine-read blocks present) with a 17-line summary that has no marker blocks at all. The four phase-3 findings were recovered from `c678205f`, are carried forward below with their original `source`, and the blocks were restored into the artifact in this phase (finding 10).
- Nothing else was left unreviewed: `main...HEAD` contained only report files, so the reviewable surface is exactly the plan this run produced and the code this phase added.

## Findings

| # | source | severity | path:line | finding | disposition |
|---|--------|----------|-----------|---------|-------------|
| 1 | coderabbit | minor | `docs/reports/foreman-beads:foreman:foreman-zv8bi/PLAN.md:5` | The phase-2 commit replaced the 215-line executable plan with a 20-line summary, so the plan path later phases read contained no plan. | fixed |
| 2 | coderabbit | minor | `docs/reports/foreman-beads:foreman:foreman-zv8bi/PLAN.md:113` | The proposed HEEx referenced an undefined `@base_ref_policy_id` assign and never supplied the option list, so the settings page would raise undefined assign. | fixed |
| 3 | coderabbit | minor | `docs/reports/foreman-beads:foreman:foreman-zv8bi/PLAN.md:84` | The validator clause omitted `when` before `is_binary(value)`, so the snippet would not compile if copied into `settings.ex`. | fixed |
| 4 | coderabbit | minor | `docs/reports/foreman-beads:foreman:foreman-zv8bi/PLAN.md:116` | The form help text promised the selection controls the PR base although no run code reads the key, letting an operator choose `checkout` and see no effect. | fixed |
| 5 | repo-rules | major | `docs/reports/foreman-beads:foreman:foreman-zv8bi/FIX_REPORT.md:1` | The run's fix phase left a one-line note instead of an implementation, so the bead's feature was absent from the branch — the run would have shipped an empty change. | fixed |
| 6 | repo-rules | major | `packages/foreman_server/lib/foreman_server/aggregates/project/settings.ex:53` | `base_ref_policy` is registered, validated, persisted, typed and shown in the settings form, but no run, worktree or pull-request code reads it, so the operator-visible setting changes nothing on its own. | open |
| 7 | repo-rules | minor | `packages/foreman_server/lib/foreman_server/mcp/tools.ex:1467` | An atom-keyed `:base_ref_policy` was dropped silently by the MCP settings whitelist, so a caller that set it got a success that changed nothing (`AGENTS.md` §5.2: never degrade to a plausible-looking success). | fixed |
| 8 | repo-rules | minor | `packages/foreman_server/lib/foreman_server_web/project_settings_live.ex:882` | The settings-form help text described the two policies as if they were already in force. | fixed |
| 9 | repo-rules | minor | `docs/user-guide.md:736` | The new settings-table row was inserted after a blank line, which ended the markdown table and left the row orphaned below it. | fixed |
| 10 | repo-rules | minor | `docs/reports/foreman-beads:foreman:foreman-zv8bi/REVIEW_CODERABBIT_REPORT.md:17` | Foreman's phase-3 commit replaced the phase artifact with a 17-line summary and dropped both machine-read blocks, so the phase's four findings no longer parse and the operator sees none of them. | fixed |
| 11 | repo-rules | minor | `packages/foreman_server/lib/foreman_server/mcp/tools.ex:1447` | An atom-keyed `:repo_allowlist` or `:max_repos_per_run` is still dropped silently by the MCP settings whitelist. | declined |

Findings 1–4 are carried forward verbatim from the phase-3 block recovered from `c678205f` (`source: coderabbit`). Findings 5–11 were found by this phase against the repository's own rules (`source: repo-rules`).

## Fixed

**Finding 5 — the bead was never implemented.** `docs/reports/foreman-beads:foreman:foreman-zv8bi/FIX_REPORT.md` (phase 2) contained one line: the plan had been overwritten, nothing implemented. The plan is this run's own work product (commit `9db30e48`, 215 lines) and this is the last phase of the workflow, so the surface was implemented here, following the plan's §1 scope (the setting only — the sibling bead "fetch `origin/<base>` before creating the run worktree" stays out of scope):

- `packages/foreman_server/lib/foreman_server/aggregates/project/settings.ex` — new key `base_ref_policy` in `@keys` (line 53), `@type key` (line 79) and `@type error` (line 106, `{:base_ref_policy_invalid, term(), [String.t()]}`); `@base_ref_policies ~w(origin checkout)`; public `base_ref_policies/0`; validator clauses (nil → `{:ok, nil}`; binary → trim + downcase, blank → `{:ok, nil}`, member → `{:ok, policy}`, otherwise `{:error, {:base_ref_policy_invalid, value, @base_ref_policies}}`; non-binary → the same error tuple).
- `packages/foreman_server/lib/foreman_server/events/project_updated.ex` — `base_ref_policy: String.t() | nil` in `@type t` (line 31) and in the `defstruct` (line 56).
- `packages/foreman_server/lib/foreman_server/project_settings.ex` — `base_ref_policy: String.t() | nil` in `@type t` (lines 24–28).
- `packages/foreman_server/lib/foreman_server_web/project_settings_live.ex` — `base_ref_policy` in `@text_fields` (line 58), the `base_ref_policies: Settings.base_ref_policies()` assign (line 831) and the `<.field>` control (line 882).
- `packages/foreman_cli/cmd/foreman/project.go` — `--base-ref-policy` flag (usage text, flag declaration, payload entry, `projectSettingNames`), so the setting is settable by an operator exactly like every other project setting.
- Docs (documentation gate): `docs/user-guide.md` settings-table row, `docs/cli-reference.md` usage line + flag-table row, `CLAUDE.md` §26 `Settings.keys/0` list and its operator-only parenthetical. `README.md` carries no project-settings table or enumeration, so it needed no edit.

The value is stored as the string `"origin"` / `"checkout"` (not atoms — atoms do not round-trip through the typed JSON event), mirroring `notification_preference`; unset means `origin`.

**Finding 7 — atom-keyed MCP argument dropped silently.** `packages/foreman_server/lib/foreman_server/mcp/tools.ex`: the new private helper `operator_only_atom_arg/1` (lines 1490–1492) returns the first of `[:required_checks, :base_ref_policy]` present as an atom key, and `check_args/4` now computes it above the `cond` (line 1447) and fails with `%ToolError{code: "INVALID_PARAMS", message: "Unknown arguments: base_ref_policy"}` (lines 1467–1469) instead of letting `Map.take` drop the key. The binding must be computed *above* the `cond`: Elixir does not carry a binding made in a condition expression into the clause body.

**Finding 8 — help text promised unimplemented behaviour.** `packages/foreman_server/lib/foreman_server_web/project_settings_live.ex:882`: the help text now ends "Registered only: no run reads it yet." — the same correction phase 3 applied to the plan.

**Finding 9 — orphaned table row.** `docs/user-guide.md`: the row now sits directly under the `required_checks` row (line 735 → row at 736), with the paragraph "Text values are trimmed …" after a blank line.

**Finding 10 — clobbered phase-3 artifact.** `docs/reports/foreman-beads:foreman:foreman-zv8bi/REVIEW_CODERABBIT_REPORT.md`: the findings block is restored verbatim from `c678205f`; the judgement block keeps phase 3's level `LOW` with a rewritten rationale, because the rationale stored in `c678205f` is a compression placeholder rather than text. The artifact now carries a note explaining the restoration.

**Tests added** (all green, see `## Verification`):

- `packages/foreman_server/test/foreman_server/aggregates/project_settings_test.exs` — `describe "base_ref_policy"`: accepts `origin`/`checkout` with case and whitespace normalised; rejects `upstream` with `{:base_ref_policy_invalid, "upstream", allowed}` where `allowed == ~w(origin checkout)`; rejects a non-string value; `nil` and blank clear the setting; a blank value is reported in `cleared_settings`.
- `packages/foreman_server/test/foreman_server/mcp/tools_project_settings_test.exs` — an atom- or string-keyed `base_ref_policy` is refused with `INVALID_PARAMS` / "Unknown arguments: base_ref_policy" and emits no `ProjectUpdated` event; clearing stays available (a reset, not a set — same precedent as `repo_allowlist`; only `required_checks` is refused a clear). The parity test's operator-only list now names `base_ref_policy`, so the whitelist and the MCP schema cannot drift apart.
- `packages/foreman_server/test/foreman_server_web/live/project_settings_live_test.exs` — the policy saves as `checkout`, a blank value clears it back to the default, an invalid value is refused at its field (`#base_ref_policy-error`, "base_ref_policy_invalid"), and the control has a label bound by `for`/`id`.
- `packages/foreman_cli/cmd/foreman/project_settings_test.go` — `--base-ref-policy checkout` reaches the payload as `"base_ref_policy": "checkout"`.

## Declined

- **Finding 11 — atom-keyed `:repo_allowlist` / `:max_repos_per_run` still dropped silently** (`packages/foreman_server/lib/foreman_server/mcp/tools.ex:1447`). Pre-existing, not introduced by this bead: those keys were already absent from the MCP schema and from the tool's whitelist, so an atom key is dropped by `Map.take` exactly as it was before this change. Fixing it means changing how the two existing operator-only settings are rejected — a separate change with its own test surface, and outside the surgical scope of this bead (the new key is already loud, which is what the review required here).
- **Finding 6 — the setting is registered but inert** (`settings.ex:53`). Not declined as invalid: the finding stands and stays **open**. The consumer (resolving the run's pull-request base from `origin/<base>` or the local checkout) is the sibling bead, deliberately outside this bead's scope per the plan's §1; the setting, its validation, its storage and its operator surface are all in place, and the docs state that no run reads it yet.

## Verification

All commands run from the run worktree; the inherited `DATABASE_URL` (port 55434) fails password authentication, so the test database was addressed explicitly on port 55432.

| Command | Result |
|---------|--------|
| `cd packages/foreman_server && MIX_ENV=test mix compile --warnings-as-errors` | exit 0, no warnings |
| `cd packages/foreman_server && mix format <8 changed files> && mix format --check-formatted` | exit 0 |
| `cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test TEST_DB_POOL_SIZE=5 MIX_ENV=test mix test test/foreman_server/aggregates/project_settings_test.exs` | 37 tests, 0 failures |
| `cd packages/foreman_server && … mix test test/foreman_server/mcp/tools_project_settings_test.exs` | 14 tests, 0 failures |
| `cd packages/foreman_server && … mix test test/foreman_server_web/live/project_settings_live_test.exs` | 61 tests, 0 failures |
| `cd packages/foreman_server && … mix test --warnings-as-errors` (6 affected files: project_settings read-model + replay, coordinator dispatch, aggregate settings, MCP tools, live view) | 129 tests, 0 failures, 0 warnings |
| `cd packages/foreman_cli && gofmt -l ./cmd/` | empty |
| `cd packages/foreman_cli && go build ./cmd/foreman` | build ok |
| `cd packages/foreman_cli && go test -count=1 ./cmd/foreman/` | ok (usage drift test included) |
| `git diff main...HEAD` + `git diff main` re-read after the fixes | no new violation introduced; fixes are confined to the planned surface |

Fixes are left uncommitted for this phase, as the phase contract requires.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema":"foreman.review_findings/1","reviewed":true,"findings":[{"severity":"minor","path":"docs/reports/foreman-beads:foreman:foreman-zv8bi/PLAN.md","line":5,"description":"The phase-2 commit replaced the 215-line executable plan with a 20-line summary, so the plan path later phases read contained no plan.","disposition":"fixed","source":"coderabbit"},{"severity":"minor","path":"docs/reports/foreman-beads:foreman:foreman-zv8bi/PLAN.md","line":113,"description":"The proposed HEEx referenced an undefined @base_ref_policy_id assign and never supplied the option list, so the settings page would raise undefined assign.","disposition":"fixed","source":"coderabbit"},{"severity":"minor","path":"docs/reports/foreman-beads:foreman:foreman-zv8bi/PLAN.md","line":84,"description":"The validator clause omitted `when` before is_binary(value), so the snippet would not compile if copied into settings.ex.","disposition":"fixed","source":"coderabbit"},{"severity":"minor","path":"docs/reports/foreman-beads:foreman:foreman-zv8bi/PLAN.md","line":116,"description":"The form help text promised the selection controls the PR base although no run code reads the key, letting an operator choose checkout and see no effect.","disposition":"fixed","source":"coderabbit"},{"severity":"major","path":"docs/reports/foreman-beads:foreman:foreman-zv8bi/FIX_REPORT.md","line":1,"description":"The run's fix phase left a one-line note instead of an implementation, so the bead's feature was absent from the branch - the run would have shipped an empty change.","disposition":"fixed","source":"repo-rules"},{"severity":"major","path":"packages/foreman_server/lib/foreman_server/aggregates/project/settings.ex","line":53,"description":"base_ref_policy is registered, validated, persisted, typed and shown in the settings form, but no run, worktree or pull-request code reads it, so the operator-visible setting changes nothing on its own. The consumer is the sibling bead; this finding stays open.","disposition":"open","source":"repo-rules"},{"severity":"minor","path":"packages/foreman_server/lib/foreman_server/mcp/tools.ex","line":1467,"description":"An atom-keyed :base_ref_policy was dropped silently by the MCP settings whitelist, so a caller that set it got a success that changed nothing.","disposition":"fixed","source":"repo-rules"},{"severity":"minor","path":"packages/foreman_server/lib/foreman_server_web/project_settings_live.ex","line":882,"description":"The settings-form help text described the two policies as if they were already in force.","disposition":"fixed","source":"repo-rules"},{"severity":"minor","path":"docs/user-guide.md","line":736,"description":"The new settings-table row was inserted after a blank line, which ended the markdown table and left the row orphaned below it.","disposition":"fixed","source":"repo-rules"},{"severity":"minor","path":"docs/reports/foreman-beads:foreman:foreman-zv8bi/REVIEW_CODERABBIT_REPORT.md","line":17,"description":"Foreman's phase-3 commit replaced the phase artifact with a 17-line summary and dropped both machine-read blocks, so the phase's four findings no longer parse and the operator sees none of them.","disposition":"fixed","source":"repo-rules"},{"severity":"minor","path":"packages/foreman_server/lib/foreman_server/mcp/tools.ex","line":1447,"description":"An atom-keyed :repo_allowlist or :max_repos_per_run is still dropped silently by the MCP settings whitelist.","disposition":"declined","source":"repo-rules"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->
<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema":"foreman.risk_judgement/1","level":"MEDIUM","rationale":"The bead's surface now exists and is verified: key and validator, typed event field, read model, settings form, operator-only CLI flag and the CLAUDE.md / user-guide / cli-reference documentation rows, with the full affected test set green. Risk stays MEDIUM rather than LOW because the setting is inert on its own - no run, worktree or pull-request path reads base_ref_policy yet, so an operator who sets checkout sees no effect until the sibling bead lands; the docs, CLI help and form help all say so explicitly. The run also needed two repairs: the fix phase shipped no implementation, and Foreman's phase-3 commit dropped the phase-3 findings block, hiding four findings from the operator."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
