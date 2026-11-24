# Fix report — beads:foreman:foreman-d6rth

Run: `run-090f5deed6c91ee5e888f52db133f185` · Workflow: `fix` · Task: `beads:foreman:foreman-d6rth`

> **Provenance note.** Phase 2 of this run (`fix`) produced no implementation: its
> committed `FIX_REPORT.md` was a 153-byte tool-error fragment ("Probe ended — that write was a
> false positive…"), and it also truncated the phase-1 `PLAN.md` from 154 lines to 25. Phase 3
> (`coderabbit-review`) restored `PLAN.md`, applied the plan's single documentation edit, and
> rewrote this report. The change below is the plan's edit, applied as planned; nothing was
> widened beyond it.

## 1. Root cause

The bead asks for user-guide documentation of PR title/body behaviour. The phase-1 plan
established that three of the bead's four claims describe features that do not exist in this
codebase, and that only one real documentation gap remains:

- The **PR title rule already is documented** — `docs/user-guide.md:2966-2971` and
  `docs/cli-reference.md:622` match `Workflow.PhasePr.pr_title/1`
  (`packages/foreman_server/lib/foreman_server/workflow/phase_pr.ex:368-371`): the run's task
  title when the run has one, else the first conventional-commit subject among the run's
  commits, else the legacy `feat(phase): <phase>` title.
- The **`## PR body` convention does not exist** — `git grep -- "## PR body"` (excluding
  `docs/reports/`) matches nothing: no bundled prompt instructs an agent to write such a
  section and nothing parses it.
- The **project body-template setting does not exist** — `git grep "pr_body_template"`
  (excluding `docs/reports/`) matches nothing, and
  `packages/foreman_server/lib/foreman_server/aggregates/project/settings.ex` `@keys`
  (`:48-51`) lists no such key.
- The **one real gap** is the generated-body `Artifact:` rule.
  `packages/foreman_server/lib/foreman_server/workflow/pr_body_path.ex` `artifact_line/2`
  (`:81-90`) emits `"\nArtifact: <repo-relative>\n"` only when the artifact path can be
  expressed relative to the repository root, and `""` when it cannot — never an absolute host
  path. It is used by `Workflow.PhasePr.gh_pr_create/2` (`phase_pr.ex:408-413`) and
  `Workflow.AutoPr.generated_body/1` (`auto_pr.ex:715-724`). Nothing in `docs/user-guide.md`,
  `README.md`, `CLAUDE.md` or `docs/cli-reference.md` stated that rule.

## 2. Change

- `docs/user-guide.md` (+16 / -0) — new paragraph **"A generated PR body carries no absolute
  host path."** inserted after the review-findings paragraph (now lines 3010-3024), stating
  that a generated PR body names the phase artifact on an `Artifact:` line that is always
  repository-relative, that an artifact outside the repository gets **no** `Artifact:` line
  rather than an absolute one, and that a task-backed final AutoPR body is the task
  description verbatim and carries no `Artifact:` line. This is the operator-facing
  counterpart of the rule `CLAUDE.md:1216`, `README.md:288` and `docs/cli-reference.md:622`
  already state in engineering terms. CodeRabbit round 2 tightened three sentences of this
  paragraph (see `REVIEW_CODERABBIT_REPORT.md`): a missing `Artifact:` line has two causes
  (no artifact path recorded, or a path outside the repository), a `commit: false` phase can
  open its PR before the artifact is committed, and a title-only task falls back to a
  generated body that does carry the line.
- `docs/reports/foreman-beads:foreman:foreman-d6rth/PLAN.md` — restored byte-identically from
  commit `534a5150` (154 lines) after phase 2 truncated it to 25 lines, then narrowed the two
  premise greps to exclude `docs/reports/` (CodeRabbit round 1, finding B). See
  `REVIEW_CODERABBIT_REPORT.md` for that finding's record.

## 3. Deviations from the plan

- **Phase attribution.** The plan's edit was applied in phase 3 (`coderabbit-review`) rather
  than phase 2 (`fix`), because phase 2 committed only the tool-error fragment above and no
  later phase of this workflow implements. The edit itself is the plan's, verbatim.
- **Insertion point.** The plan placed the paragraph after the blank line 3009 and before
  `**Marker lines.**`. After insertion the marker-line paragraph starts at line 3026; its text
  is unchanged. The plan's "do not touch lines 3010 onward" meant the pre-insert file.
- None otherwise. The plan's "Out of scope" list was honoured: no `## PR body` convention and
  no `pr_body_template` setting were implemented, `AGENTS.md`, `docs/PRD/*`, `docs/TRD/*` and
  `packages/foreman_server/CHANGELOG.md` were not touched.

## 4. Tests

- **Failing-before check** (the plan's "Failing check first"): the premise greps
  `git grep -- "## PR body" -- ':(exclude)docs/reports'` and
  `git grep "pr_body_template" -- ':(exclude)docs/reports'` (both exit 1, no output) and
  `grep -n "Artifact:" docs/user-guide.md docs/cli-reference.md README.md CLAUDE.md`
  (exit 1, no output) — i.e. the `Artifact:` rule was documented nowhere. After the change the
  third check matches the new paragraph by design: the gap is closed.
- **Tests added/updated:** none. The change is one prose paragraph in a Markdown file; the
  repository has no documentation assertion covering it (`test/foreman_server/observability/docs_test.exs`
  asserts SigNoz/OTel configuration only), and the plan called for no new test.

## 5. Local verification

```console
$ devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test --warnings-as-errors test/foreman_server/observability/docs_test.exs'
# exit 0 — Result: 3 passed

$ cd packages/foreman_cli && go test ./cmd/foreman/ -run 'TestUserGuide|TestUsageAdvertisesExactlyTheDispatchedVerbs|TestCLIReferenceDocumentsEveryDispatchedVerb|TestAgentCommandSpecsRouteToDispatchedVerbs|TestCLIReferenceNotImplementedClaimsAreAccurate' -v
# exit 0 — 6 tests PASS; ok github.com/fortium/foreman/packages/foreman_cli/cmd/foreman 0.166s
```

The first run of the Elixir command failed to boot (`Can't continue due to errors on
dependencies` — the fresh worktree had no `deps/`); `devbox run -- bash -c 'cd
packages/foreman_server && mix deps.get'` fixed that, and the command above then passed. Only
noise in the output: `[error] idempotency store is not durable: no repo is configured (ETS
fallback)`. No formatter applies: the change touches no `.ex`/`.exs` file.

CodeRabbit round 2 caught a defect in the first version of this section: the Go filter was
written `-run 'TestUserGuide\|TestUsageDrift'`. Inside single quotes the backslash reaches Go's
regexp engine, where `\|` is a literal pipe, so the pattern matched **no** test and the exit
code 0 proved nothing. `TestUsageDrift` does not exist either; the usage-drift tests are
named `TestUsageAdvertisesExactlyTheDispatchedVerbs`,
`TestCLIReferenceDocumentsEveryDispatchedVerb`, `TestAgentCommandSpecsRouteToDispatchedVerbs`
and `TestCLIReferenceNotImplementedClaimsAreAccurate`. The command above uses the unescaped
alternation and `-v`, so the six named tests are visible as `PASS` in the output.

## 6. Follow-ups

- The two features the bead names but that do not exist in the codebase — a `## PR body`
  section convention and a project body-template setting — remain unimplemented and
  undocumented, deliberately. They need their own beads (a feature bead for the behaviour, a
  documentation bead for whichever of the two lands).
- `PLAN.md` carries the phase-1 plan unchanged except for one narrowing: it was restored
  byte-identically from commit `534a5150` and then, once, its two premise greps were given
  a `:(exclude)docs/reports` pathspec (CodeRabbit round 1, finding R1-F2 — an unscoped
  `git grep` matched the plan's own quoted strings and would have tripped the plan's own
  stop condition). Per `fix.md` line 19 the plan stays unedited by implementation agents in
  any other respect; Foreman commits it as part of this phase's work.
