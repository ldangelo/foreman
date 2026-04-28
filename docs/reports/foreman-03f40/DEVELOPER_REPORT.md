# Developer Report: Integrate Foreman with GitHub Issues (Epic)

## Approach

The implementation builds on the existing GitHub infrastructure already in the codebase (GhCli, webhook handler, postgres-adapter GitHub tables) to add a background polling daemon that:
1. Periodically fetches open GitHub issues for configured repos
2. Imports new issues as Foreman tasks (backlog by default, ready if labeled "foreman")
3. Updates already-imported tasks on re-poll (safe re-sync, no duplicates)
4. Auto-closes linked GitHub issues when the Foreman task is merged
5. Links created PRs back to the originating GitHub issue via comments

Key design decisions:
- **Idempotent polling**: external_id = "github:owner/repo#N" is used as the idempotency key — re-polling doesn't create duplicates
- **Non-fatal integration**: GitHub issue close and PR link operations are best-effort and logged, never blocking merge completion
- **Rate limit visibility**: GhRateLimitError propagates and is counted as a poll error, giving operators visibility via logs
- **gh-first auth**: checks gh availability before starting, silently disabling polling if gh is not installed

## Files Changed

- `src/daemon/github-poller.ts` — **new** — GitHubIssuesPoller class + closeLinkedGithubIssue/linkPrToGithubIssue helpers
- `src/daemon/__tests__/github-poller.test.ts` — **new** — 19 unit tests covering all polling behavior and close/link integration
- `src/daemon/index.ts` — added GitHubIssuesPoller lifecycle to ForemanDaemon (start/stop integrated into daemon start/stop)
- `src/daemon/webhook-handler.ts` — fixed 4 call sites of `updateTaskGitHubFields` to include `projectId` parameter
- `src/lib/db/postgres-adapter.ts` — added `projectId` parameter to `updateTaskGitHubFields(projectId, taskId, updates)` for data isolation
- `src/orchestrator/refinery.ts` — call `closeLinkedGithubIssue` after updating task to merged; call `#linkPrToGithubIssue` after PR creation

## Tests Added/Modified

- `src/daemon/__tests__/github-poller.test.ts` — 19 tests covering:
  - Poller lifecycle (start/stop/idempotent)
  - Import rules: new → backlog, "foreman" label → ready, "foreman:dispatch" → ready
  - Idempotency: no duplicate creation on re-poll matching existing task
  - Safe re-sync: existing task updated when title/body changed
  - Sync event recording on import and close
  - Non-active project skipping
  - closeLinkedGithubIssue: non-fatal behavior, correct close for linked tasks, no-op for unlinked tasks

## Decisions & Trade-offs

1. **Poller lives in the daemon, not a separate process**: Integration into ForemanDaemon leverages existing process management. The poller is started/stopped with the daemon alongside the dispatch loop.

2. **gh-first auth check on startup**: Rather than throwing if gh isn't authenticated, the poller silently skips starting if gh isn't installed. Operators can verify via `foreman doctor` or daemon logs.

3. **updateTaskGitHubFields projectId parameter**: All other PostgresAdapter methods take `projectId` as first arg for data isolation. The existing implementation was inconsistent (only took taskId). Fixed to include projectId.

4. **PR linking via comment, not PR body**: Adding a comment is simpler and less intrusive than modifying PR body templates. The comment format is: "Foreman work complete. PR: {url}"

5. **No separate tRPC procedures for poller**: The poller is controlled via start()/stop() lifecycle rather than RPC. On-demand re-sync could be added as a future procedure if needed.

6. **Auto-close only in Refinery's native task path**: The beads path in `syncBeadStatusAfterMerge` doesn't have access to the gh client in the same way. The close integration is implemented in `closeNativeTaskPostMerge()` which covers the native task path. Beads path would need a separate integration point in auto-merge.ts.

## Known Limitations

- **Beads path auto-close not implemented**: The `syncBeadStatusAfterMerge` in `auto-merge.ts` (beads path) doesn't call `closeLinkedGithubIssue`. This would require passing the gh client into that flow or refactoring how the beads path accesses GitHub integration.
- **No on-demand trigger via CLI yet**: The poller runs on interval. Could add `foreman issue sync --repo owner/repo` to trigger immediate re-sync as a future enhancement.
- **No polling interval CLI override**: Configured via FOREMAN_GITHUB_POLL_INTERVAL_MS env var only.
- **No webhook fallback when webhook is not configured**: If the user hasn't enabled webhooks, the poller is the only sync path. The existing webhook integration already handles webhooks for real-time events when configured.