
## Documentation Discipline

Every fix or feature must consider documentation before finalization. Update `CLAUDE.md`, `AGENTS.md`, `README.md`, the Foreman User Guide (`docs/user-guide.md`), and the CLI Reference (`docs/cli-reference.md`) when behavior, commands, workflows, prompts, setup, troubleshooting, or operator expectations change. Keep edits surgical; document only real behavior.

Runtime prompt/workflow safety: after editing bundled source workflows or prompts, run `foreman init --force`. Dispatch paths (`foreman run`, `foreman run --watch`, and direct worker startup) fail fast when installed runtime prompts/workflows are stale.

Local development uses the checked-in Devbox/direnv Docker Compose stack: `devbox run dev:up` starts shared pgvector Postgres plus Hindsight. `.envrc` sources `.env`; treat `.env`'s `DATABASE_URL` as the source of truth for Foreman. The compose stack's fresh/default Postgres port is `127.0.0.1:55432`, but local checkouts may intentionally point `DATABASE_URL` elsewhere.

**Startup recovery**: On every app boot, `Recovery` GenServer automatically scans `ProjectionStore` for interrupted runs and emits `RunRecoveryEvent` through `CommandRouter`. It also scans for pending scheduler fire intents whose pickup was never confirmed before restart — these are marked `SchedulerIntentStale` and either re-dispatched (with a fresh worker launch) or explicitly `ScheduledFireSkipped` if the work is terminal or abandoned. Repeated scans in the same application boot do not duplicate recovery effects (boot-scoped command IDs and the pre-boot timestamp cutoff dedupe effects). `ScheduledFireConfirmed` is emitted when a worker confirms pickup via `WorkerStarted`.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:

- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:

- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:

- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:

- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:

```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.

READ ./CLAUDE.md

Workflow note: PR/merge behavior is controlled by phase-level `checkpointPr: true` on mutating phases plus explicit `create-pr`, `pr-wait`, and `merge` phases. Do not add top-level workflow `merge:` or `pr:` tags.

Execution safety rules:

- Before rerunning a task to validate a fix, ensure the fix is durably committed and available on the active branch being tested.
- Treat "implemented" as meaning: relevant tests/build passed and the work has a concrete commit hash on the branch/workspace that will be used for the rerun.
- Do not benchmark or rerun tasks from a dirty or ambiguous controller workspace state.
- If a task reset, branch cleanup, or workspace cleanup is about to happen while important work is only in the working copy, checkpoint it first via commit or patch export.
## Webhook Intake

The Elixir server exposes `POST /webhooks/attach_bridge` for attach-bridge streaming metadata and connection lifecycle events (connected/disconnected). Auth via `Authorization: Bearer <FOREMAN_SERVER_AUTH_TOKEN>` when a server token is configured (unauthenticated requests are only accepted when no server token is configured). `AttachBridgeAdapter` normalizes payloads: explicit `correlation_id` or `event_id` is preferred as the dedupe key; the fallback composite key includes run_id:worker_id:phase_id:connection_id:session_id:lifecycle, preserving separate items for each lifecycle transition.
## VCS Lifecycle Events

The Elixir `VcsAdapter` behaviour (`ForemanServer.VcsAdapter`) provides VCS lifecycle events for the Foreman event store. The `Default` implementation calls the GitHub API using the `:github_token` application setting or `GITHUB_TOKEN` environment variable. It surfaces three operations: `clone/2` (validates `owner/name` format and returns clone metadata without materializing a workspace), `branch/2`, and `create_pr/2`. All operations emit `VcsOperationStarted`, then either `VcsOperationCompleted` or `VcsOperationFailed` through `CommandRouter`. Transient failures (e.g. network timeout, rate limiting, 5xx) retry up to 3 times with exponential backoff; non-transient failures (401/403 auth rejection, 404 not found, invalid repo format) fail immediately without retry.
