## Review
- Correct:
  - Auth + view validation present: `router.ex:67-80`, `217-221`.
  - `assistant_message.message` preserved: `worker_protocol.ex:73-74`; covered in `debug_views_test.exs:183-205`.
  - Post-purge restart/replay covered: `debug_views_test.exs:77-115`.
  - Focused tests pass: 14 tests, 0 failures.

- Fixed:
  - None. No edits per req.

- Blocker:
  - UTF-8 truncation can break HTTP JSON for long non-ASCII logs/reports/debug data.
    - Cause: byte slicing in `debug_views.ex:270-272`.
    - Affects sanitized values used by raw logs `debug_views.ex:132-133`, compact logs `147`, debug timeline `162-164`, report paths/failures `197`, `223`.
    - Repro: long emoji stdout produced `String.valid? == false`; `Jason.encode` returned `Jason.EncodeError`.
    - Fix now: truncate on valid UTF-8/grapheme boundaries, add regression for compact/raw HTTP endpoint.

- Note:
  - `progress.md` missing.
  - Did not write `subagent-outputs/review2-trd-020-correctness.md`; req said no edits.

## Commands
- `git status --short` — clean.
- `git show --stat 3125f93d`, `git diff d5ee5a82..3125f93d` — inspected fix.
- `cd packages/foreman_server && mix test test/debug_views_test.exs test/http_router_test.exs` — pass, 14 tests.
- `cd packages/foreman_server && mix run -e <utf8 trunc repro>` — failed JSON encode as above.