# CodeRabbit Review Report — coord-322b62d929d673ec

## Review engine

Command run from the worktree root:

```
coderabbit review --agent --base "main"
```

(`$FOREMAN_BASE_BRANCH` = `main`.) Completed, outcome `completed`, 2 findings.

## Rounds

- **Round 1** — findings received: 2 (1 minor, 1 trivial). Fixed: 2. Declined: 0.
  No `Critical`/`Major` findings. Both findings fixed were obviously safe and
  local, so no further round was needed (stop-early condition met).

## Fixed

- `packages/foreman_server/lib/foreman_server_web/workspace/project_view.ex:30`
  — **minor**. `blank_to_nil/1` had a catch-all `defp blank_to_nil(_), do: nil`
  that silently mapped a present-but-non-string goal to `nil`, presenting a
  malformed goal as "no goal". Narrowed the catch-all to `defp blank_to_nil(nil),
  do: nil`; a present goal of an unexpected type now raises instead of being
  silently dropped (§5.3 Absent ≠ malformed). Valid-string and blank-string
  behaviour unchanged.

- `packages/foreman_server/test/foreman_server_web/live/project_workspace_live_test.exs:1207`
  — **trivial**. The two `html =~` assertions passed even if
  `section.ws-panels` moved outside `aside.ws-side`. Replaced them with
  `assert has_element?(view, "aside.ws-side > section.ws-panels")`, which pins
  the parent-child contract (markup confirmed: `project_workspace_live.ex:685-686`).

## Declined

None.

## Verification

- `devbox run -- bash -c 'unset DATABASE_URL EVENTSTORE_URL; cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors test/foreman_server_web/workspace/project_view_test.exs test/foreman_server_web/live/project_workspace_live_test.exs'`
  — exit 0, **50 passed**. (The inherited `DATABASE_URL`/`EVENTSTORE_URL` point
  at the langfuse-stack Postgres on :55434; unset so the test config default
  foreman Postgres on :55432 is used.)
- `devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted <changed files>'`
  — exit 0.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
<!-- FOREMAN_REVIEW_FINDINGS_END -->
