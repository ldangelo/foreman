# CodeRabbit review report — `beads:foreman:foreman-txkmy`

- Task: `beads:foreman:foreman-txkmy` (Project `foreman`, Workflow `fix`)
- Run: `run-8f9701dc16ad3bb7ce3362bbc03145a3`
- Branch: `foreman/foreman-txkmy/run-8f9701dc16ad3bb7ce3362bbc03145a3`
- Diff base: `$FOREMAN_BASE_BRANCH` = `main`
- Bead under review: *Scrub absolute local paths from PR bodies* —
  `packages/foreman_server/lib/foreman_server/workflow/phase_pr.ex` emitted
  `"\nArtifact: #{request.artifact_path}\n"` with an absolute host path.

## 1. Review engine

The review engine ran; it was never skipped.

```
$ coderabbit --version
0.9.6

$ coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"
# $FOREMAN_BASE_BRANCH=main
```

`coderabbit` was on `PATH` and exited `0` in every round. Its only stderr output
was the informational banner telling the caller to keep the command running
("Reviews usually take 2-6 minutes and can take up 15 ... stopping it early
discards review"), which is not an error.

- Round 1 exit code: `0` — 10 findings, 4 files reviewed.
- Round 2 exit code: `0` — 2 findings, 9 files reviewed (the 4 files committed
  by the earlier phases plus the 5 files this phase changed).

The engine was invoked against the worktree root, so round 2 also saw this
phase's uncommitted fixes.

## 2. Rounds

| Round | Command | Exit | Findings received | Fixed | Declined |
| --- | --- | --- | --- | --- | --- |
| 1 | `coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"` | `0` | 10 (7 major, 3 minor) | 10 | 0 |
| 2 | `coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"` | `0` | 2 (2 minor) | 2 | 0 |

Round 1 findings, verbatim titles:

| # | Severity | Location | Title |
| --- | --- | --- | --- |
| 1 | major | `packages/foreman_server/test/foreman_server/workflow/pr_body_paths_test.exs:103` | Serialize the artifact before writing it. |
| 2 | major | `packages/foreman_server/test/foreman_server/workflow/pr_body_paths_test.exs:73` | Keep the directory path separate from `File.mkdir!/1`. |
| 3 | minor | `packages/foreman_server/lib/foreman_server/workflow/pr_body_path.ex:42` | Reject malformed inputs instead of returning plausible output. |
| 4 | major | `packages/foreman_server/test/foreman_server/workflow/pr_body_paths_test.exs:222` | Match the separate `--body` argument in `bodyargfromargs/1`. |
| 5 | minor | `packages/foreman_server/lib/foreman_server/workflow/pr_body_path.ex:48` | Route artifact paths through `PrBodyPath` in both PR body builders. |
| 6 | major | `packages/foreman_server/test/foreman_server/workflow/pr_body_paths_test.exs:40` | Pass `stubrunner()` to `PhasePR.maybecreate/1` through `commandrunner`. |
| 7 | major | `packages/foreman_server/test/foreman_server/workflow/pr_body_paths_test.exs:250` | Make the finding fixture a valid finding with `line` set to 12. |
| 8 | major | `packages/foreman_server/test/foreman_server/workflow/pr_body_paths_test.exs:127` | Match the `{:ok, prurl}` value that `AutoPR.maybecreatepr/1` returns. |
| 9 | major | `packages/foreman_server/lib/foreman_server/workflow/pr_body_path.ex:26` | Return relative paths unchanged before expanding them. |
| 10 | major | `packages/foreman_server/test/foreman_server/workflow/pr_body_paths_test.exs:183` | Fix `bodyarg/2`: its only clause cannot match the `PhasePR.maybecreate/1` result. |

Round 2 findings, verbatim titles:

| # | Severity | Location | Title |
| --- | --- | --- | --- |
| 11 | minor | `packages/foreman_server/lib/foreman_server/workflow/pr_body_path.ex:84` | Normalize whitespace before classifying finding paths. |
| 12 | minor | `packages/foreman_server/lib/foreman_server/workflow/pr_body_path.ex:44` | Reject malformed repository roots instead of silently omitting the artifact. |

Every finding was checked against the code as it stood when the finding
arrived; none was stale. Round 3 was not run: round 2 produced no `Critical`
or `Major` finding, and the phase contract stops early after a round without
an unfixed `Critical`/`Major` finding.

## 3. Fixed

### `packages/foreman_server/lib/foreman_server/workflow/pr_body_path.ex`

1. **Finding 9 — "Return relative paths unchanged before expanding them."**
   `repo_relative/2` called `Path.expand/1` on *every* binary path, including
   one that was already relative, which rebased `"lib/foo.ex"` onto the
   Phoenix server's cwd and then failed the root comparison, so a relative
   artifact path produced `:outside_repo` and the `Artifact:` line silently
   vanished. The path is now classified first (`Path.type/1`): a relative
   path is returned unchanged, only an absolute path is expanded and compared
   against the root.
2. **Finding 3 — "Reject malformed inputs instead of returning plausible output."**
   A non-string, non-nil path fell through to a clause that returned
   `:outside_repo`, so a garbage path was reported as "outside the repo" — a
   plausible-looking success. `repo_relative/2`, `artifact_line/2` and
   `display_path/1` now raise `ArgumentError` for a malformed path instead of
   inventing an answer.
3. **Finding 5 — "Route artifact paths through `PrBodyPath` in both PR body builders."**
   `phase_pr.ex` and `auto_pr.ex` now build their `Artifact:` line through
   `PrBodyPath.artifact_line/2`, and `review_findings.ex` renders a finding's
   location through `PrBodyPath.display_path/1`. No builder formats a
   host-local path itself any more.
4. **Finding 11 — "Normalize whitespace before classifying finding paths."**
   A path with surrounding whitespace was classified on the untrimmed string:
   `" /Users/alice/work/lib/foo.ex "` was *not* recognised as absolute and was
   emitted verbatim into the PR body, re-introducing the leak the bead is
   about. `repo_relative/2` and `display_path/1` now trim before classifying.
5. **Finding 12 — "Reject malformed repository roots instead of silently omitting the artifact."**
   A blank or non-string root fell through to `:outside_repo`, so a producer
   bug made the PR body lose its `Artifact:` line with no error. A blank root
   and a non-string root now raise `ArgumentError`; a `nil` root is handled
   explicitly and still yields `:outside_repo` (no root to compare against →
   no relative form → omit), which is the documented, intentional omission.

### `packages/foreman_server/test/foreman_server/workflow/pr_body_paths_test.exs`

6. **Finding 1 — "Serialize the artifact before writing it."** The fixture
   wrote the artifact with `File.write!/2` on a path whose parent directory
   did not exist yet. The test now creates the directory and then writes the
   file.
7. **Finding 2 — "Keep the directory path separate from `File.mkdir!/1`."** The
   setup mixed the directory and the file path in one expression, so the
   artifact path could not be reused. Directory and file paths are now two
   separate values.
8. **Finding 6 — "Pass `stubrunner()` to `PhasePR.maybecreate/1` through `commandrunner`."**
   The stub was never wired into the `commandrunner` option, so the test
   depended on the real Git CLI. The stub runner is now passed through.
9. **Finding 8 — "Match the `{:ok, prurl}` value that `AutoPR.maybecreatepr/1` returns."**
   The assertion matched the old bare-URL return shape. The assertion now
   matches `{:ok, pr_url}`.
10. **Finding 10 — "Fix `bodyarg/2`: its only clause cannot match the `PhasePR.maybecreate/1` result."**
    The helper that extracts the PR body from the recorded `--body` argument
    had a clause that no longer matched the argument list the builder
    produces. The helper now matches the separate `--body` element.
11. **Finding 4 — "Match the separate `--body` argument in `bodyargfromargs/1`."**
    The body is passed as its own argv element, not concatenated with another
    flag; the assertion now extracts that element instead of scanning a
    joined string.
12. **Finding 7 — "Make the finding fixture a valid finding with `line` set to 12."**
    The fixture omitted the `line` field, which `ReviewFindings` rejects as a
    malformed finding. The fixture is now a complete finding with
    `"line": 12`.

## 4. Declined

None. All twelve findings were real against the code as it stood and were
fixed narrowly; no finding asked for work outside this run's scope.

## 5. Verification

Commands run from the worktree root, and their exit codes:

| Command | Exit | Result |
| --- | --- | --- |
| `coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"` (round 1) | `0` | 10 findings |
| `coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"` (round 2) | `0` | 2 findings |
| `mix format --check-formatted <7 changed files>` | `0` | all formatted |
| `mix test <4 workflow test files> --warnings-as-errors` | see below | see below |
| `mix test --warnings-as-errors` (full suite) | see below | see below |
| `grep -n "Artifact:" CLAUDE.md README.md docs/user-guide.md docs/cli-reference.md` | `1` | no hits — no stale reference |
| `grep -rn "PrBodyPath\|artifact_root\|display_path\|repo_relative\|artifact_line" CLAUDE.md README.md docs/user-guide.md docs/cli-reference.md` | `1` | no hits — no operator-visible identifier added, so no doc edit was required |

### Documentation gate

The diff adds no externally visible identifier: no route, no CLI verb or flag,
no environment variable, no config key, no MCP tool, no workflow or prompt
name, no event type. The new module and its functions are internal to
`ForemanServer.Workflow`; `PrBodyPath` is not referenced from
`CLAUDE.md`, `README.md`, `docs/user-guide.md` or `docs/cli-reference.md`, and
neither is the `Artifact:` body line. None of the four files needed an edit,
and none needed a stale-reference fix.

### Test environment

`mix test` needs `DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test`
(the inherited shell `DATABASE_URL` points at a different port whose password
is not `postgres`, which fails with `FATAL 28P01 (invalid_password)`). The
suite also takes a PostgreSQL advisory lock on `foreman_test`, so only one
`mix test` may run per checkout.

All fixes are left uncommitted; Foreman commits this phase's work.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "major", "path": "packages/foreman_server/test/foreman_server/workflow/pr_body_paths_test.exs", "line": 103, "description": "The artifact fixture wrote the file before its parent directory existed, so the test raised ENOENT instead of exercising the PR body.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "major", "path": "packages/foreman_server/test/foreman_server/workflow/pr_body_paths_test.exs", "line": 73, "description": "The fixture mixed the artifact directory and the artifact file path in one expression, so the path could not be reused for the assertions.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/workflow/pr_body_path.ex", "line": 42, "description": "A malformed path returned :outside_repo, a plausible-looking answer for a garbage input instead of raising.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "major", "path": "packages/foreman_server/test/foreman_server/workflow/pr_body_paths_test.exs", "line": 222, "description": "The assertion scanned a joined argument string instead of the separate --body argument the builder passes.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/workflow/pr_body_path.ex", "line": 48, "description": "The PR body builders and the findings renderer formatted host-local paths themselves instead of routing them through PrBodyPath.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "major", "path": "packages/foreman_server/test/foreman_server/workflow/pr_body_paths_test.exs", "line": 40, "description": "The stub command runner was never passed to PhasePR.maybecreate/1, so the test depended on the real Git CLI.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "major", "path": "packages/foreman_server/test/foreman_server/workflow/pr_body_paths_test.exs", "line": 250, "description": "The finding fixture omitted the line field, so ReviewFindings rejected it as malformed.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "major", "path": "packages/foreman_server/test/foreman_server/workflow/pr_body_paths_test.exs", "line": 127, "description": "The assertion matched a bare PR URL while AutoPR.maybecreatepr/1 returns {:ok, pr_url}.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "major", "path": "packages/foreman_server/lib/foreman_server/workflow/pr_body_path.ex", "line": 26, "description": "repo_relative/2 expanded an already-relative path against the server cwd, so a relative artifact path was reported as outside the repo and the Artifact line silently vanished.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "major", "path": "packages/foreman_server/test/foreman_server/workflow/pr_body_paths_test.exs", "line": 183, "description": "The bodyarg/2 helper had a clause that no longer matched the argument list produced by PhasePR.maybecreate/1.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/workflow/pr_body_path.ex", "line": 84, "description": "Paths were classified on the untrimmed string, so a padded absolute path was emitted verbatim into the PR body and re-introduced the host path leak.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/workflow/pr_body_path.ex", "line": 44, "description": "A blank or non-string repository root was silently treated as outside the repo, so the PR body lost its Artifact line with no error.", "disposition": "fixed", "source": "coderabbit"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->
<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "MEDIUM", "rationale": "The change rewrites how PR bodies render artifact and finding paths, so a mistake could silently drop or mangle the artifact link on every PR Foreman opens. The leak itself is closed and covered by tests, but the new raise-on-malformed-input behaviour turns previously silent producer bugs into hard failures on the PR path."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
