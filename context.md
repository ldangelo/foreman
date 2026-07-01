# Code Context

## Files Retrieved
1. `src/orchestrator/agent-worker.ts` (lines 1094-1365) - current fused finalize post-processing: validates finalize, creates PR, enqueues merge queue, triggers immediate autoMerge.
2. `src/orchestrator/refinery.ts` (lines 431-690) - existing PR creation/reuse and PR merge entry points.
3. `src/orchestrator/auto-merge.ts` (lines 196-345) - merge queue drain chooses create-pr vs auto-merge and calls refinery.
4. `src/orchestrator/pipeline-executor.ts` (lines 927-1110) - generic workflow phase loop and phase/prompt/model seams.
5. `src/lib/workflow-loader.ts` (lines 109-183) - workflow phase schema; supports prompt/bash/command/builtin, retry, artifact, verdict.
6. `src/orchestrator/roles.ts` (lines 437-570) - generic prompt loader/buildPhasePrompt for custom phase prompts and template vars.
7. `src/lib/prompt-loader.ts` (lines 1-120) - runtime prompt resolution chain and required prompt context.
8. `src/defaults/workflows/feature.yaml` (lines 80-92) - current feature workflow ends at finalize.

## Key Code

Current key seam is `agent-worker.ts` `onPipelineComplete`, which is only called after workflow phases complete and is hard-gated to finalize:

```ts
// src/orchestrator/agent-worker.ts:1096-1101
async onPipelineComplete({ progress, success }) {
  if (progress.currentPhase !== "finalize") {
    log(`[FINALIZE] Skipping branch-ready: success=${String(success)}, currentPhase=${progress.currentPhase}`);
    return;
  }
```

It currently mixes four responsibilities after finalize success:

```ts
// src/orchestrator/agent-worker.ts:1235-1256
await updateTerminalRunStatus(... status: "completed" ...);
const refinery = new Refinery(...);
const pr = await refinery.ensurePullRequestForRun({
  runId,
  baseBranch: config.targetBranch,
  updateRunStatus: false,
  bodyNote: workflowConfig.merge === "auto"
    ? "Automatically published before refinery PR merge."
    : "Published by finalize for operator review.",
});
```

Then it enqueues and immediately drains merge:

```ts
// src/orchestrator/agent-worker.ts:1311-1345
const enqueueResult = await enqueueToMergeQueue({
  projectId: config.projectId,
  taskId,
  runId,
  operation: "auto_merge",
  worktreePath,
  getFilesModified: () => enqueueFiles,
});
...
const mergeResult = await autoMerge({ ... runId, overrideRun: currentRun });
```

Existing PR creation can be reused almost directly:

```ts
// src/orchestrator/refinery.ts:431-438
async ensurePullRequestForRun(opts: {
  runId: string;
  baseBranch?: string;
  draft?: boolean;
  updateRunStatus?: boolean;
  bodyNote?: string;
  existingOk?: boolean;
}): Promise<CreatedPr>
```

Existing merge can also be reused, but should stop creating PR itself once create-pr exists:

```ts
// src/orchestrator/refinery.ts:599-645
async mergePullRequest(opts: { runId: string; targetBranch?: string }): Promise<MergeReport> {
  ...
  const pr = await this.ensurePullRequestForRun({ runId: run.id, baseBranch: targetBranch });
  ...
  await gh(["pr", "merge", branchName, "--squash"], this.projectPath);
```

Workflow executor already supports arbitrary prompt phases and retry loops:

```ts
// src/orchestrator/pipeline-executor.ts:957-968
while (i < phases.length) {
  const phase = phases[i];
  const phaseName = phase.name;
  const phaseType = phase.bash ? "bash" : phase.command ? "command" : phase.builtin ? "builtin" : "prompt";
```

Prompt phase names are generic:

```ts
// src/orchestrator/roles.ts:479-525
export function buildPhasePrompt(phaseName: string, context: {...}, opts?: PromptLoaderOpts): string
```

## Architecture

Current data flow:

1. `dispatcher.ts` launches `agent-worker.ts`.
2. `agent-worker.ts` runs YAML phases through `pipeline-executor.ts`.
3. YAML currently ends at `finalize` for feature workflows.
4. `pipeline-executor.ts` calls `onPipelineComplete` after final phase.
5. `agent-worker.ts:onPipelineComplete` treats successful finalize as terminal, creates PR via `Refinery.ensurePullRequestForRun`, enqueues merge queue, then calls `autoMerge`.
6. `autoMerge` drains queue and calls `Refinery.mergePullRequest`.
7. `Refinery.mergePullRequest` creates/reuses PR again, then calls `gh pr merge`.

Smallest safe split:

- Keep `finalize` as current prompt phase: commit, validate, push, write `FINALIZE_VALIDATION.md` / `FINALIZE_REPORT.md`.
- Add built-in phase execution support for TypeScript builtins in `pipeline-executor.ts`.
- Add builtin `create-pr` that wraps `Refinery.ensurePullRequestForRun` and writes PR metadata to run.
- Add prompt phase `pr-review` after `create-pr`; it runs in the same worktree and may commit/push fixes.
- Move merge enqueue/drain out of finalize-specific `agent-worker.ts` and only do it after final workflow phase succeeds. Guard should become “pipeline success and merge strategy auto”, not `currentPhase === "finalize"`.
- Make `Refinery.mergePullRequest` optionally require existing PR (`ensurePullRequestForRun` can remain idempotent, but do not treat PR creation as merge responsibility conceptually).

Suggested workflow shape:

```yaml
- name: finalize
  prompt: finalize.md
  artifact: FINALIZE_VALIDATION.md
  verdict: true
  retryWith: developer
  retryOnFail: 1

- name: create-pr
  builtin: create-pr
  artifact: PR_METADATA.json

- name: pr-review
  prompt: pr-review.md
  models:
    default: MiniMax
  artifact: PR_REVIEW_REPORT.md
  verdict: true
  retryWith: developer
  retryOnFail: 1

# merge remains outside the agent phase list initially: onPipelineComplete enqueues/drains after pr-review success.
```

PR review implementation options:

1. Smallest: prompt-only `pr-review` phase. Prompt instructs agent to use `gh` commands to inspect CodeRabbit/checks, fix critical/high/medium and PR-caused failed checks, commit/push, then write PASS/FAIL report. No new GitHub parser in TS. Fastest, user-controllable, but less deterministic.
2. Safer deterministic helper: add `src/orchestrator/pr-review-context.ts` that collects CodeRabbit comments/checks before phase and injects findings into prompt or writes `PR_REVIEW_FINDINGS.md`. More testable and less agent guesswork.

Recommended smallest safe implementation: add deterministic collector + prompt agent.

Collector functions:

- `collectPrReviewContext(projectPath, prUrlOrNumber, headSha)`
- `collectCodeRabbitComments(...)` from:
  - `gh api repos/:owner/:repo/pulls/:number/comments`
  - `gh api repos/:owner/:repo/issues/:number/comments`
- `collectFailedChecks(...)` from:
  - `gh pr view <pr> --json statusCheckRollup,headRefOid`
  - or `gh api repos/:owner/:repo/commits/:sha/check-runs`
- `parseBlockingCodeRabbitFindings(text)` for `critical|high|medium` only.

`pr-review.md` should require:

- Read `PR_REVIEW_FINDINGS.md` / current PR metadata.
- Fix only CodeRabbit critical/high/medium and failed checks caused by PR.
- If failed checks are unrelated/pre-existing/unclear, stop and report FAIL with scope.
- Commit/push changes if any.
- Write `PR_REVIEW_REPORT.md` with `Verdict: PASS|FAIL`, remaining findings, checks reviewed, commits pushed.

Important guardrail: `pi-observability-extension.ts` currently blocks `git commit`/`git push` outside finalize (not retrieved fully here; grep showed `getForbiddenVcsAction` special-cases only `phase === "finalize"`). To allow `pr-review` to fix/push, update that guard to allow `phase === "finalize" || phase === "pr-review"` or add phase config flag like `allowVcsWrite: true`.

## Files likely to change

1. `src/orchestrator/agent-worker.ts`
   - Remove PR creation and merge enqueue/drain from finalize-only block.
   - Keep finalize failure/troubleshooter handling.
   - After pipeline success, if last phase is `create-pr`/`pr-review` or workflow merge auto, enqueue merge queue and call `autoMerge`.
   - Do not require `progress.currentPhase === "finalize"` for branch-ready/merge; require overall success and branch pushed.

2. `src/orchestrator/pipeline-executor.ts`
   - Add real builtin phase dispatch before prompt execution. Current code classifies `builtin` but does not execute a TS builtin separately.
   - Builtin result should populate same `PhaseResult`, artifact checks, mail, activity records.
   - Add builtin context hook in `PipelineContext`, e.g. `runBuiltinPhase?: (name, phase, progress) => Promise<PhaseResult>`.

3. `src/orchestrator/refinery.ts`
   - Reuse `ensurePullRequestForRun` for `create-pr` builtin.
   - Add helper to parse PR number from URL or return it in `CreatedPr` if tests can absorb type change.
   - Consider adding `mergeExistingPullRequestForRun` or option to `mergePullRequest({ requireExistingPr: true })` so merge phase doesn’t hide create-pr failures.

4. `src/orchestrator/pr-review-context.ts` (new)
   - Deterministic gh collection/parsing for CodeRabbit and failed checks.
   - Keep pure parsers exported for tests.

5. `src/defaults/prompts/default/pr-review.md` and/or `src/defaults/prompts/feature/pr-review.md` (new)
   - Agent instructions and report schema.

6. `src/defaults/workflows/feature.yaml` plus other desired workflows
   - Insert `create-pr` and `pr-review` after finalize.
   - Initially safest to enable only feature/default, not smoke/chore.

7. `src/lib/workflow-loader.ts`
   - If using `builtin: create-pr` string is preferred, schema currently has `builtin?: boolean`; smallest change can use `name: create-pr` + `builtin: true`.
   - If adding phase-level config like `allowVcsWrite` or `prReview`, extend type/validation.

8. `src/orchestrator/pi-observability-extension.ts`
   - Allow commit/push in `pr-review`, or use config-driven exception.

9. Tests:
   - `src/orchestrator/__tests__/pipeline-*.test.ts`
   - `src/orchestrator/__tests__/auto-merge.test.ts`
   - `src/orchestrator/__tests__/refinery.test.ts`
   - New `src/orchestrator/__tests__/pr-review-context.test.ts`

## Minimal implementation plan

1. Extract current post-finalize success code in `agent-worker.ts` into helpers:
   - `handleFinalizeOutcome(...)` returns `{ finalized: boolean, retryable, failureReason }`.
   - `publishPullRequestForRun(...)` calls `Refinery.ensurePullRequestForRun`.
   - `enqueueAndDrainMerge(...)` contains existing merge queue + `autoMerge` call.

2. Add builtin phase support in `pipeline-executor.ts`:
   - `PipelineContext.runBuiltinPhase`.
   - Builtin phase returns `PhaseResult` and can write artifacts.
   - First builtin: `create-pr`.

3. Implement `create-pr` builtin in `agent-worker.ts` or small new module:
   - Calls `ensurePullRequestForRun({ updateRunStatus: false })`.
   - Writes `PR_METADATA.json` in worktree: `{ prUrl, prNumber, branchName, headSha, baseBranch }`.
   - Sends `pr-created` mail.

4. Add `pr-review-context.ts`:
   - Pure parsers first.
   - Runtime gh collectors second.
   - Blocking severities hardcoded to `critical/high/medium` for first cut.
   - Failed checks are included; prompt decides if PR-caused.

5. Add `pr-review.md` prompt:
   - Agent reads metadata/findings.
   - Agent may run `gh pr view`, `gh api`, test commands as needed.
   - Fix only blocking CodeRabbit findings and PR-caused failed checks.
   - Commit/push if changed.
   - Report PASS only if no blocking findings and no PR-caused failed checks remain.

6. Change workflow:
   - `feature.yaml`: finalize → create-pr → pr-review.
   - Keep merge enqueue/drain after successful pipeline completion. This avoids adding a YAML `merge` builtin in first pass.

7. Adjust `agent-worker.ts:onPipelineComplete`:
   - Do not create PR there if `create-pr` phase exists.
   - Do not return when `currentPhase !== finalize`; instead require pipeline success and last phase success.
   - For workflows without `create-pr`, preserve old behavior for compatibility.

8. Later optional split: add `merge` builtin phase. Not needed for first safe implementation because merge is currently queue/refinery lifecycle, not agent work.

## Test strategy

Unit first:

1. `pr-review-context.test.ts`
   - Parses CodeRabbit comments with `critical`, `high`, `medium`; ignores low/nit.
   - Handles bot login variants (`coderabbitai[bot]`, maybe `coderabbitai`).
   - Parses/serializes failed check summaries.

2. `pipeline-builtin-phase.test.ts`
   - A workflow with `finalize`, `create-pr`, `pr-review` calls builtin at the right point.
   - Builtin artifact `PR_METADATA.json` participates in artifact checks and phase mail.
   - A failed builtin stops before `pr-review`.

3. `agent-worker` tests
   - Finalize success no longer always creates PR inside `onPipelineComplete` when workflow has `create-pr`.
   - Pipeline success after `pr-review` enqueues/drains merge.
   - Backward compatibility: workflow ending at finalize still creates PR/enqueues as today.

4. `refinery` tests
   - `ensurePullRequestForRun` returns/stores enough metadata for PR review.
   - `mergePullRequest` can merge existing PR and reports clean failure when no PR/dirty PR.

5. `pi-observability-extension.test.ts`
   - `git commit`/`git push` allowed in `pr-review` if chosen; still blocked in explorer/developer/qa/reviewer.

Integration-ish with mocked `gh`:

- Mock `gh api`/`gh pr view` with one high CodeRabbit comment and one failed check.
- `pr-review` report FAIL when blocking remains.
- If collector says no blocking and checks pass, report PASS and merge queue drain is called.

## Risks / constraints

- Current `builtin?: boolean` is misleading: builtins are classified but no separate TS builtin execution exists. Add minimal dispatch rather than overloading prompt path.
- Runtime prompt loader needs installed prompt files; adding `pr-review.md` to bundled defaults may require updating prompt install/doctor required phases if desired.
- CodeRabbit comment formats are not stable. Keep parser conservative; prompt can inspect raw comments for nuance.
- Failed checks can be flaky/unrelated. Do not auto-fix unless linked to changed files or obvious PR regression; otherwise `PR_REVIEW_REPORT.md` should fail with `Failure Scope: UNRELATED_FILES|UNKNOWN`.
- Allowing commit/push in `pr-review` changes guardrail semantics; make exception explicit and tested.

## Start Here

Start with `src/orchestrator/agent-worker.ts` lines 1094-1365. This is where finalize/create-pr/merge are currently fused. Split this first, then add `create-pr` builtin support in `src/orchestrator/pipeline-executor.ts`.
