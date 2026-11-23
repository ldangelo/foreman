# repo-rules review :: foreman-og6ro

Task `beads:foreman:foreman-og6ro` · Run `run-e0942614fb7968e897927fb757b8c7b3` · Phase 4

## Review engine

Reviewer: this phase's own repository-rules pass. Conventions files read in
this worktree root: `AGENTS.md` (rules) and `CLAUDE.md` (the operator-facing
contract — §8 "Configuration keys (operator-visible)", §12 "Foreman-managed
worktree contract for implement-trd workflows", and the review-prompt contract
at `CLAUDE.md:1218` that requires a `FOREMAN_RISK_JUDGEMENT` block after the
findings block). `README.md`, `context.md`, `prompts.md` and `JIDO_FORKS.md` are
present but carry no rules this diff touches; there is no `CONTRIBUTING.md`
(`.github/` holds only workflows). Established idioms in the files under review
are the fallback standard. No external review CLI is used in this phase.

Diff range reviewed, exactly:

```
git diff main...HEAD        # $FOREMAN_BASE_BRANCH = main, non-empty, so not Blocked
```

Range content (`git diff main...HEAD --numstat`):

| file | + | - |
| --- | --- | --- |
| `docs/reports/foreman-beads:foreman:foreman-og6ro/PLAN.md` | 31 | 0 |
| `docs/reports/foreman-beads:foreman:foreman-og6ro/FIX_REPORT.md` | 18 | 0 |
| `docs/reports/foreman-beads:foreman:foreman-og6ro/REVIEW_CODERABBIT_REPORT.md` | 16 | 0 |

Total: 3 files, 65 insertions, 0 deletions, **zero non-markdown files**. No
`.ex`, `.exs` or `.go` file is touched anywhere in the run branch, so there is no
code in this diff to review for error handling, typed boundaries, or
unread-config-key defects. The review therefore reduces to two questions:
does the diff deliver the bead, and do the three documents describe things that
are not true?

## Findings

Two findings reached this phase, one from the bead/task prompt and one from this
review.

1. **major · bead unimplemented** — `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:4456`
   (the `resolve_revision(project_root, "HEAD")` fallback the requested tests
   would exercise). The bead requests tests for origin-base worktree creation,
   fetch-failure degradation, and `base_ref_policy: checkout`. The branch adds no
   test file.
   Disposition: **open** (not fixable by a review phase — see Declined/Fixed
   reasoning below).
2. **minor · previous phase's machine-read blocks absent** —
   `docs/reports/foreman-beads:foreman:foreman-og6ro/REVIEW_CODERABBIT_REPORT.md`.
   The carry-forward instruction says to copy each finding object out of the
   previous phase's `findings` array. That array does not exist in a machine-
   readable form: the file contains no marker lines at all. Disposition: **open**.

Nothing else in the diff violates a repository rule, for the reasons in Declined.

## Fixed

Nothing. No finding in this diff had a narrow code or document change that
improved it, and the phase contract forbids inventing scope (AGENTS.md Working
Rule 3/4: no speculative features, every changed line must trace to the request).

I explicitly considered and rejected editing the three report files. Their prose
is already garbled — mid-sentence truncation, missing verbs, stray backticks
(e.g. `REVIEW_CODERABBIT_REPORT.md` line beginning `**Verification** — no test
command` loses most of its clause content) — and rewriting that prose is not what
this bead asks for, would add churn to documents Foreman already attached to the
PR, and cannot recover information that was lost when the text was mangled. The
authoritative body of those findings is the `## Findings` section above.

## Declined

No finding is dispositioned `declined` in the findings block below: both
entries are `open`. What follows are the actions I declined to take while
resolving finding 1, recorded with the file each would have touched.

- **`packages/foreman_server/test/foreman_server/workflow/run_executor_origin_base_test.exs`
  — "write the tests now" — declined as out of this run's reach, reported open
  instead.** The bead names four identifiers: `resolve_origin_base`,
  `fetch_origin_base`, `base_ref_policy`, `__resolve_provisioned_base_for_test__`.
  All are absent from this branch:

  ```
  grep -rnE "base_ref_policy|resolve_origin_base|fetch_origin_base|__resolve_provisioned_base_for_test__" \
    packages/foreman_server/lib packages/foreman_server/test packages/foreman_cli
  # → no output
  ```

  The behaviour the tests would assert does not exist here.
  `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:4447-4458`
  (the `HEAD` fallback is at `:4456`) still reads:

  ```
  defp resolve_declared_base(spec, project_root) do
    case Map.get(spec, :base) do
      declared when is_binary(declared) and declared != "" -> ...
      _ -> resolve_revision(project_root, "HEAD")
    end
  end
  ```

  i.e. the worktree is cut from the local checkout HEAD, with no fetch and no
  `origin/<branch>` read. Writing the requested tests against this branch would
  produce tests that fail, which AGENTS.md treats as a failed build
  ("A failing test is a failed build, full stop"), and would pin a contract that
  only exists on unmerged PR #942 / #943. Phases 1-3 reached the same verdict;
  this review confirms it rather than overriding it. The finding therefore stays
  `open` for the operator: either merge PR #942 first (it already carries
  `run_executor_origin_base_test.exs`) and then re-scope the bead to the gap that
  remains, or implement origin-base resolution in this run before its tests.

- **Documentation-gate findings against `CLAUDE.md`, `README.md`,
  `docs/user-guide.md`, `docs/cli-reference.md` — declined: no stale references
  possible.** The diff adds, removes and renames zero externally visible
  identifiers: no command/event type, MCP tool, HTTP route, CLI flag/verb, env
  var, config key or workflow/prompt name. Grep of all four gate files for
  `foreman-og6ro`, `base_ref_policy`, `resolve_origin_base` and
  `run_executor_origin_base_test` returns zero hits, so there is nothing to
  reconcile. `AGENTS.md` is not a doc-update target per its own rule.

- **A finding I looked for and did not find: an unread declared config key.** The
  bead's own subject matter is a config key (`base_ref_policy`) that a previous
  run added without wiring, and that is exactly the §5.4b defect this phase is
  supposed to catch. Phases 1-3 recorded it as shipped-but-unwired on PR #943 at
  `settings.ex:53`; that is not checkable from this branch — the only settings
  aggregate here is
  `packages/foreman_server/lib/foreman_server/aggregates/project/settings.ex`
  and `grep -rn base_ref_policy packages/foreman_server/lib` returns nothing
  (Verification table). Either way it lives on PR #943, outside this diff range,
  so it is not a finding against this run's work and I did not "fix" it here.
  Recorded so it is not lost.

## Verification

All commands run in
`/Users/ldangelo/.foreman/worktrees/foreman/foreman-og6ro/run-e0942614fb7968e897927fb757b8c7b3/workspace`.

| command | exit |
| --- | --- |
| `git rev-parse --abbrev-ref HEAD` (branch check) | 0 |
| `git diff main...HEAD --name-only` / `--numstat` | 0 |
| `grep -rnE "base_ref_policy\|resolve_origin_base\|fetch_origin_base\|__resolve_provisioned_base_for_test__" packages/foreman_server/lib packages/foreman_server/test packages/foreman_cli` | 1 (no matches) |
| `grep -c FOREMAN_REVIEW_FINDINGS_START '<…>/REVIEW_CODERABBIT_REPORT.md'` | 1 (count 0) |
| `grep -c FOREMAN_RISK_JUDGEMENT_START '<…>/REVIEW_CODERABBIT_REPORT.md'` | 1 (count 0) |
| `grep -rn -E "foreman-og6ro\|base_ref_policy\|resolve_origin_base\|run_executor_origin_base_test" CLAUDE.md README.md docs/user-guide.md docs/cli-reference.md` | 1 (no matches — doc gate clean) |

- **Test command: not run, deliberately.** The phase contract says run the
  narrowest test command *for the files you changed*. This phase changed no
  `.ex`, `.exs` or `.go` file (Verification table row 2 above), so there is no
  affected test file. `deps/` does not exist under `packages/foreman_server` in
  this run worktree, so `mix test` could not compile the umbrella anyway; running
  the full suite is not called for by AGENTS.md for a markdown-only change.
- **Formatter/linter: not applicable, verified not speculation.**
  `packages/foreman_server/.formatter.exs` declares exactly
  `["{mix,.formatter}.exs", "lib/**/*.ex", "test/**/*.exs"]` — no `*.md` input, so
  no formatter in this repository's tooling covers the only files in the diff.
- **Marker-block validity.** Both blocks below were written outside any code
  fence, each marker on its own line, and I re-checked *this* file after writing
  with a script that walks the fences and prints every line starting
  `<!-- FOREMAN_`: exactly four such lines exist, all outside a fence, one per
  marker. Note `grep -c` over the whole file returns 3 per start marker because
  this section names them in backticks; only unindented, unfenced lines are
  counted by `ReviewFindings.extract_block/3`, and there is exactly one of each.
  The JSON was parsed with `python3` `json.loads` — see the second table.
- **Parser-equivalent re-check.** `packages/foreman_server/deps` does not exist in
  this run worktree, so `mix run` cannot execute `ReviewFindings.extract_block/3`
  (clauses at `packages/foreman_server/lib/foreman_server/workflow/review_findings.ex:180`,
  fence-aware counter at `:381-410`, which counts a marker only when the
  right-trimmed line equals it exactly and sits outside a code fence). I
  re-implemented that counter in `python3` and ran it over three report files:
  this report returns `{:ok, 1022 B}` findings and `{:ok, 750 B}` judgement, both
  `json.loads`-clean; the previous phase's `REVIEW_CODERABBIT_REPORT.md` returns
  `:absent` for **both** blocks, so finding #2 is reproduced with the real
  parser's logic rather than asserted. The same check over a known-good report
  from another run (`docs/reports/foreman-beads:foreman:foreman-jzycy/REVIEW_CODERABBIT_REPORT.md`)
  returns `{:ok, 940 B}` / `{:ok, 317 B}`, confirming the re-implementation does
  not simply report `:absent` for everything.
- **Independent advisor check: unavailable.** `ask_advisor` failed with
  `Anthropic token refresh request failed … status=400 …
  "error_description": "Refresh token expired"`, so the risk level below rests on
  my own reasoning with no second opinion. Operator needs to re-auth.
- **Working tree left as the contract requires:** only this report is new/changed
  and nothing is staged; Foreman commits this phase.

| re-check | exit |
| --- | --- |
| `python3` parser-equivalent `extract_block/3` over 3 report files | 0 |
| `python3` `json.loads` over the findings block | 0 |
| `python3` `json.loads` over the judgement block | 0 |
| fence-walk over this file counting unindented `<!-- FOREMAN_` lines | 0 (exactly 4: one per marker) |

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "major", "path": "packages/foreman_server/lib/foreman_server/workflow/run_executor.ex", "line": 4456, "description": "The bead's requested tests are absent because the behaviour they would assert (origin/<base_branch> worktree creation, fetch-failure warning, base_ref_policy: checkout) does not exist on this branch: resolve_declared_base/2 at run_executor.ex:4456 still resolves HEAD, so the tests cannot be written green here and remain open pending PR #942.", "disposition": "open", "source": "repo-rules"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-og6ro/REVIEW_CODERABBIT_REPORT.md", "line": 1, "description": "The previous phase's report contains no FOREMAN_REVIEW_FINDINGS_START or FOREMAN_RISK_JUDGEMENT_START marker lines, so its findings array could not be carried forward even though its prose claims machine-read blocks of 1416 and 625 bytes.", "disposition": "open", "source": "repo-rules"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "MEDIUM", "rationale": "The diff is markdown-only (3 report files, 65 insertions, 0 deletions, no code), so nothing here can break a build; the risk is signalling. Three phases produced a Blocked verdict and the bead delivered none of its requested tests, yet the branch reaches a PR as green delivered work, and the previous phase's report asserts machine-read findings and judgement blocks that its file does not contain. MEDIUM rather than LOW because a reader who trusts the diff rather than the Blocked verdict would believe origin-base behaviour is tested when it is not. No independent check backs this level: ask_advisor is unusable (Anthropic oauth 400 invalid_grant, Refresh token expired)."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
