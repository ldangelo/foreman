#!/usr/bin/env bash
# Temporary local verification driver for foreman-gocpd (deleted before the phase ends).
# Runs the narrowest gate, then, if green, compiles the whole app for lint and runs the
# full test suite. All output goes into this worktree (.gocpd_*.log), never /tmp.
set -uo pipefail
ROOT=/Users/ldangelo/.foreman/worktrees/foreman/foreman-gocpd/run-bf31fff2bba135166d4e4cc111d51be8/workspace
cd "$ROOT/packages/foreman_server"

NARROW='test/foreman_server/workflow/phase_pr_test.exs test/foreman_server/workflow/phase_pr_body_test.exs'

echo "== narrow =="
MIX_ENV=test mix test $NARROW --warnings-as-errors > "$ROOT/.gocpd_narrow.log" 2>&1
narrow=$?
echo "narrow exit=$narrow"
tail -n 20 "$ROOT/.gocpd_narrow.log"
if [ $narrow -ne 0 ]; then
  echo "NARROW RED - stopping"
  exit $narrow
fi

echo "== compile all (warnings-as-errors) =="
MIX_ENV=test mix compile --warnings-as-errors > "$ROOT/.gocpd_compile.log" 2>&1
compile=$?
echo "compile exit=$compile"
tail -n 30 "$ROOT/.gocpd_compile.log"

echo "== full suite =="
MIX_ENV=test mix test --warnings-as-errors > "$ROOT/.gocpd_full.log" 2>&1
full=$?
echo "full exit=$full"
tail -n 40 "$ROOT/.gocpd_full.log"
echo "DONE narrow=$narrow compile=$compile full=$full"
