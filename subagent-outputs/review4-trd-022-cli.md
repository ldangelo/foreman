## Review

- Blockers: none.

- Correct:
  - Trailing `--project` / `--output-dir` works for `foreman plan prd|trd`.
    - Child opts defined on subcmds: `src/cli/commands/plan.ts:457-483`.
    - Parent/child opts merged: `src/cli/commands/plan.ts:487-495`.
    - Resolver gets project: `src/cli/__tests__/plan-server.test.ts:72`, `:104`.
    - Payload asserts output dir/provider/run id: `src/cli/__tests__/plan-server.test.ts:74-86`, `:105-115`.
  - Legacy `foreman plan <description>` not broken.
    - Existing top-level action remains separate: `src/cli/commands/plan.ts:213-455`.
    - Legacy context tests passed.
  - Docs added.
    - User guide planning section: `docs/user-guide.md:98-107`.
    - CLI ref already documents server-backed subcmds/options: `docs/cli-reference.md:508-522`.
  - Provider simulation remains deferred.
    - Planning still emits worker protocol completion events directly: `packages/foreman_server/lib/foreman_server/planning_flow.ex:120-147`.
    - Acceptable per scope.

- Fixes worth doing now: none.

- Optional:
  - Add one test for parent-position opts: `foreman plan --project foreman --output-dir docs/X prd "..."`.
  - Not blocker; current trailing case is covered.

- Commands:
  - `npx vitest run src/cli/__tests__/plan-server.test.ts src/cli/__tests__/plan-command-context.test.ts --reporter=dot` → passed, 2 files / 4 tests.
  - `git status --short` → clean.
  - `progress.md` read failed: file absent.

Note: no file written to `subagent-outputs/review4-trd-022-cli.md` because task also said “Do not edit”; no-edit wins.