#!/usr/bin/env bash
cd "$(dirname "$0")" || exit 1
cd packages/foreman_server || exit 1
export PATH="/Users/ldangelo/Development/Fortium/foreman/.devbox/nix/profile/default/bin:$PATH"
export MIX_ENV=test
export ERL_FLAGS="+S 4:4"
export DATABASE_URL="postgres://postgres:postgres@localhost:55432/foreman_test"
export TEST_DB_POOL_SIZE=12
F1=test/foreman_server/workflow/phase_pr_test.exs
F2=test/foreman_server/workflow/phase_pr_body_test.exs
L=/Users/ldangelo/.foreman/worktrees/foreman/foreman-gocpd/run-bf31fff2bba135166d4e4cc111d51be8/workspace/.gocpd_narrow.log
{
  echo "===== NARROW2 $(date) ====="
  echo "-- db verified: 55432/foreman_test reachable with postgres/postgres"
  time mix test --warnings-as-errors "$F1" "$F2" 2>&1
  echo "NARROW2 EXIT=${PIPESTATUS[0]}"
  echo "===== DONE2 ====="
} > "$L" 2>&1
