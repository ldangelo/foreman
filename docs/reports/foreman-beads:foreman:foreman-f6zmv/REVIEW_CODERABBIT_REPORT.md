# CodeRabbit review — foreman-f6zmv

Run `run-ec499920490857a5227e8fbddb92d9d0`, phase 3 (`coderabbit-review`).
Diff base: `main` (`$FOREMAN_BASE_BRANCH` was set to `main`).

## Review engine

Command run from the worktree root:

```
coderabbit review --agent --base main
```

Exit code `0`, `status: review_completed`, `findings: 1`. Files reviewed:
`docs/reports/foreman-beads:foreman:foreman-f6zmv/FIX_REPORT.md`,
`docs/reports/foreman-beads:foreman:foreman-f6zmv/PLAN.md`,
`ops/herdr-sidebar/keys.layout-foreman.json`,
`ops/herdr-sidebar/mods/foreman-run/main.js`,
`packages/foreman_server/lib/foreman_server/approvals/sweeper.ex`,
`packages/foreman_server/test/foreman_server/approvals/sweeper_test.exs`.

The engine emitted one finding, `minor`, on the phase-2 report artifact. No
finding on the product code (`sweeper.ex`) or its test.

## Rounds

**Round 1** — 1 finding received:
- `docs/reports/foreman-beads:foreman:foreman-f6zmv/FIX_REPORT.md:1`, minor —
  "Record the required documentation-gate outcome." Declined (see Declined).

No `Critical` or `Major` finding was fixed, so per the round rule the phase
stopped after round 1. Rounds 2 and 3 were not run.

## Fixed

None.

## Declined

- `docs/reports/foreman-beads:foreman:foreman-f6zmv/FIX_REPORT.md:1` (minor) —
  finding: the fix report does not record the documentation-gate outcome, so the
  repo gate's required statement is missing from the run's artifacts.
  Reason: the observation about the content is true — the file's only line is
  "Now Edit 2 — insert the new `describe` block after line 155 in the test file.",
  which is the fix phase's leftover narration rather than a report, and PLAN.md
  §4 does require the documentation-gate outcome to be stated there. Declined
  because it is the previous phase's work product, not this run's diff to repair
  from here: the file is the `fix` phase's `artifact:`
  (`packages/foreman_server/priv/defaults/workflows/fix.yaml:51`), its content is
  Foreman's record of what the fix phase itself claimed, and rewriting it here
  would mean authoring a gate statement (which files were checked and why none
  needed edits) that this phase did not perform as the fix agent. This phase
  verified the underlying substance instead and records it under Verification.
  Operator note: the defect is in an artifact Foreman commits (`commit: true`),
  so it is not reachable by a code change in this phase either way.

## Verification

This phase fixed no code, so nothing was re-formatted or re-tested as a result of
this phase. The commands below were run to verify the phase-2 change that the
findings and the risk judgement describe.

| Command | Exit |
| --- | --- |
| `devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test --warnings-as-errors test/foreman_server/approvals/sweeper_test.exs test/foreman_server/approvals/config_test.exs'` | `0` — `Result: 15 passed`, zero failures, `--warnings-as-errors` clean |
| `devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted lib/foreman_server/approvals/sweeper.ex test/foreman_server/approvals/sweeper_test.exs'` | `0` |

Documentation gate for the change under review (the state the declined finding
asks the fix report to have recorded): the diff adds one private function,
`ForemanServer.Approvals.Sweeper.validated_on_timeout/1`
(`packages/foreman_server/lib/foreman_server/approvals/sweeper.ex:70`), and
changes no externally visible identifier — no route, config key, env var, CLI
verb/flag, MCP tool, or command/event type is added, removed or renamed. The
`:on_timeout` config key and its `:surface` / `:deny` values are unchanged;
`docs/user-guide.md:3427` is the only doc mention of `on_timeout` and still
describes them accurately. `CLAUDE.md`, `README.md`, `docs/user-guide.md` and
`docs/cli-reference.md` needed no edits (no operator-visible change).

Behaviour check by reading, not by new test: `init/1` resolves `:on_timeout` once
via `Keyword.get_lazy(opts, :on_timeout, &Config.on_timeout/0)` and stores the
validated atom in `policy_opts`, so `TimeoutPolicy.apply/3` no longer reaches its
`Config.on_timeout/0` lazy default on the sweeper path — which is the reported
defect (an invalid value raised inside `do_sweep/1` after the tool-call
`Enum.each` and before any question expired). The ordering in `do_sweep/1` is
unchanged, and `ForemanServer.Agents.OperatorTimeout`
(`lib/foreman_server/agents/operator_timeout.ex:37`), the other
`TimeoutPolicy.apply/3` caller, keeps its own lazy default and is untouched.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-f6zmv/FIX_REPORT.md", "line": 1, "description": "The committed fix report contains only leftover plan narration and never records the documentation-gate outcome the repository rules require.", "disposition": "declined", "source": "coderabbit"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "LOW", "rationale": "The change moves an existing validation earlier: Sweeper.init/1 resolves and validates :on_timeout once instead of TimeoutPolicy.apply/3 doing it lazily mid-sweep, with no new config keys, no reordered sweep, and the other apply/3 caller untouched. The behavioural change is that a misconfigured value now crashes the sweeper at start instead of silently expiring nothing, which is the intended loud failure; both touched files pass their tests with --warnings-as-errors and mix format --check-formatted."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
