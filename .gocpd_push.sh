#!/usr/bin/env bash
cd "$(dirname "$0")" || exit 1
L=.gocpd_push.log
{
  echo "===== PUSH $(date) ====="
  echo "-- env override DATABASE_URL=$TEST_URL"
  export DATABASE_URL="$TEST_URL"
  # 1. commit the implementation
  git add packages/foreman_server/lib/foreman_server/workflow/phase_pr.ex \
          packages/foreman_server/lib/foreman_server/workflow/run_executor.ex
  git commit -q -F .gocpd_msg.txt || { echo "GIT COMMIT FAILED"; exit 1; }
  echo "COMMITTED: $(git log --oneline -1)"
  # 2. push branch + checkpoint
  git push -q origin HEAD 2>&1 | tail -5
  echo "PUSH EXIT ${PIPESTATUS[0]}"
  git log --oneline -1
  echo "===== DONE ====="
} > "$L" 2>&1
