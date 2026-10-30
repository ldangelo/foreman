#!/usr/bin/env bash
# scripts/e2e/scheduled_tab_flow.sh
#
# The Scheduled tab of the project workspace (audit row C9, bead foreman-8vf0s) in a REAL browser: a
# real throwaway Foreman server (private database/port/scratch repo), two schedules created through the
# CLI (`foreman project schedule create`: an interval and a yearly cron, both far from firing, so no run
# starts), then scripts/e2e/scheduled_tab_ui.mjs drives headless Chromium: the tab lists both rows with
# their status and next fire (checked against the API and, for the cron, against an independently
# computed instant), Pause flips the row to paused (no next fire, Resume offered) AND the API/CLI to
# paused, Resume flips both back to active with a next fire. Screenshots go to $E2E_SHOT_DIR
# (default <checkout>/tmp/scheduled-tab-shots).
#
# foreman-l2ab7 adds (1) Delete -> Confirm delete / Cancel on the same tab (an active and a paused schedule, a negative
# control that simulates a build WITHOUT the confirm step and must FAIL the shared check, another project's schedules untouched,
# the ticker not firing a deleted schedule for 2 slots; E2E_TICK_SLOTS=0 skips that ~11 min wait) and (2) the project Settings page
# editors + proposal Decline (scripts/e2e/settings_page_ui.mjs).
#
# The tab shows name, status, next fire and the Pause/Resume buttons; the cron/interval SPEC is not
# rendered there, so it is asserted where it is shown: the CLI list's SPEC column and the API's `spec`.
#
# Exit: 0 all passed (UNVERIFIED lines are counted, never passes), 1 environment problem, 2 setup
# failed, 3 one or more assertions failed.
#
#     devbox run -- bash scripts/e2e/scheduled_tab_flow.sh
#
# Needs Playwright + a Chromium (`cd scripts/e2e/ui-a11y && npm ci`; the Chromium is the one
# `npx playwright install chromium` fetches); without them the run records UNVERIFIED. Environment
# (all optional): E2E_WORK_DIR, E2E_DB_NAME, E2E_PORT, E2E_HOOK_PORT, E2E_KEEP (as in claude_projects/lib.sh).
# The page is opened on `localhost`, not 127.0.0.1: the dev endpoint's origin check refuses the LiveView
# socket for the latter.

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
E2E_NAME=${E2E_NAME:-sched}
E2E_PORT=${E2E_PORT:-4870}
E2E_HOOK_PORT=${E2E_HOOK_PORT:-4970}
# shellcheck source=claude_projects/lib.sh
. "$HERE/claude_projects/lib.sh"

E2E_EXTRA_ENV="E2E_REVIEW_ANALYSIS=0"
SHOT_DIR=${E2E_SHOT_DIR:-$ROOT/tmp/scheduled-tab-shots}
UI="$HERE/ui-a11y"

check_environment
command -v node >/dev/null 2>&1 || die "'node' is required on PATH" 1
install_traps

say "browser tooling"
if [ ! -d "$UI/node_modules/playwright" ]; then
  (cd "$UI" && npm ci --no-audit --no-fund >"$WORK.npm.log" 2>&1) \
    || { unverified "Scheduled tab in a browser" "npm ci in scripts/e2e/ui-a11y failed: $(tail -n 3 "$WORK.npm.log" 2>/dev/null | tr '\n' ' ')"; summary; exit $?; }
fi
note "playwright from $UI/node_modules"

setup_stack
register_project || { head -c 1500 "$WORK/project-create.out"; tail -n 20 "$SERVER_LOG" | cut -c1-240; die "cannot register the project" 2; }
note "project $PROJECT registered over $REPO"

say "schedules through the CLI"
fm project schedule create --project-id "$PROJECT" --name interval-6h --every 6h --prompt "scheduled tab probe, never fires during the run" --workflow edit \
  >"$WORK/schedule-interval.out" 2>&1 || { cat "$WORK/schedule-interval.out"; die "schedule create (interval) failed" 2; }
fm project schedule create --project-id "$PROJECT" --name yearly-cron --cron "0 3 1 1 *" --prompt "scheduled tab probe, fires once a year" --workflow edit \
  >"$WORK/schedule-cron.out" 2>&1 || { cat "$WORK/schedule-cron.out"; die "schedule create (cron) failed" 2; }
fm project schedule create --project-id "$PROJECT" --name tick-5m --every 5m --prompt "deleted before its first slot" --workflow edit \
  >"$WORK/schedule-tick.out" 2>&1 || { cat "$WORK/schedule-tick.out"; die "schedule create (tick-5m) failed" 2; }
TICK_CREATED=$(date +%s)
fm project schedule create --project-id "$PROJECT" --name skipconfirm-probe --every 7h --prompt "negative control" --workflow edit \
  >"$WORK/schedule-probe.out" 2>&1 || { cat "$WORK/schedule-probe.out"; die "schedule create (probe) failed" 2; }
OTHER="$PROJECT-other"
make_repo "$WORK/other-repo" "$WORK/other-origin.git" || die "cannot make the second repository" 2
fm project create --id "$OTHER" --path "$WORK/other-repo" --task-provider github >"$WORK/other-create.out" 2>&1 || { cat "$WORK/other-create.out"; die "cannot register the second project" 2; }
fm project schedule create --project-id "$OTHER" --name other-keep --every 9h --prompt "another project's schedule" --workflow edit \
  >"$WORK/schedule-other.out" 2>&1 || { cat "$WORK/schedule-other.out"; die "schedule create (other project) failed" 2; }
fm project schedule list --project-id "$PROJECT" > "$WORK/schedule-list.txt" 2>&1
while IFS= read -r l; do note "$l"; done < "$WORK/schedule-list.txt"
assert_has "CLI list shows the interval spec" "$(cat "$WORK/schedule-list.txt")" "6h"
assert_has "CLI list shows the cron spec" "$(cat "$WORK/schedule-list.txt")" "0 3 1 1 *"
assert_eq "all four schedules are active" "$(fm project schedule list --project-id "$PROJECT" --json | jq -r '[.schedules[].status] | sort | join(",")')" "active,active,active,active"

# The cron's next fire, computed here and not by the server under test: the next Jan 1st 03:00 UTC.
EXPECT_CRON=$(python3 -c 'import datetime as d; n = d.datetime.now(d.timezone.utc); y = n.year if n < d.datetime(n.year, 1, 1, 3, tzinfo=d.timezone.utc) else n.year + 1; print("%d-01-01T03:00:00Z" % y)')
note "independent expectation: yearly-cron fires next at $EXPECT_CRON"

say "the Scheduled tab in headless Chromium (http://localhost:$E2E_PORT)"
mkdir -p "$SHOT_DIR"
FOREMAN_API_URL="$API" FOREMAN_API_TOKEN="$E2E_API_TOKEN" HOME="$REAL_HOME" \
  node "$HERE/scheduled_tab_ui.mjs" --base "http://localhost:$E2E_PORT" --token "$E2E_API_TOKEN" --project "$PROJECT" \
    --pause interval-6h --cancel-delete interval-6h --delete-active tick-5m --delete-paused yearly-cron --skip-confirm-probe skipconfirm-probe --other-project "$OTHER" --expect-next "yearly-cron=$EXPECT_CRON" --cli "$FOREMAN" --shot-dir "$SHOT_DIR" >"$WORK/scheduled-tab-ui.out" 2>&1
ui_rc=$?
if [ "$ui_rc" -ne 0 ]; then
  note "server log, errors while the driver ran:"
  grep -n -i -E '\[error\]|\*\* \(|crash|terminating|GenServer' "$SERVER_LOG" | tail -n 25 | cut -c1-320 | while IFS= read -r l; do note "  $l"; done
fi
if [ "$ui_rc" -eq 3 ]; then
  unverified "Scheduled tab in a browser" "$(grep '"event":"error"' "$WORK/scheduled-tab-ui.out" | head -n 1 | jq -r '.message' 2>/dev/null | cut -c1-200)"
else
  while IFS= read -r line; do
    case "$line" in
      *'"check"'*)
        c_name=$(printf '%s' "$line" | jq -r '.check')
        c_detail=$(printf '%s' "$line" | jq -c '.detail' | cut -c1-220)
        c_ok=$(printf '%s' "$line" | jq -r '.ok')
        case "$c_name" in
          NEGATIVE-CONTROL*)
            # a build without the confirm step MUST trip the shared check: the check failing is the pass
            if [ "$c_ok" = true ]; then fail "negative control did NOT detect the missing confirm step: $c_name -- $c_detail"; else pass "negative control detected the missing confirm step: $c_name -- $c_detail"; fi ;;
          *)
            if [ "$c_ok" = true ]; then pass "$c_name -- $c_detail"; else fail "$c_name -- $c_detail"; fi ;;
        esac ;;
      *) note "$(printf '%s' "$line" | cut -c1-260)" ;;
    esac
  done < "$WORK/scheduled-tab-ui.out"
  assert_true "the driver exited 0 (exit $ui_rc)" test "$ui_rc" -eq 0
fi
note "screenshots: $(ls "$SHOT_DIR" 2>/dev/null | tr '\n' ' ')"

say "final state through the CLI"
fm project schedule list --project-id "$PROJECT" > "$WORK/schedule-list-after.txt" 2>&1
while IFS= read -r l; do note "$l"; done < "$WORK/schedule-list-after.txt"
live_names() { fm project schedule list --project-id "$PROJECT" --json | jq -r '[.schedules[] | select(.status != "deleted") | .name] | sort | join(",")'; }
assert_eq "only interval-6h is left (tick-5m, yearly-cron, skipconfirm-probe deleted)" "$(live_names)" "interval-6h"
assert_eq "interval-6h is active again after pause + resume + cancelled delete" "$(fm project schedule list --project-id "$PROJECT" --json | jq -r '.schedules[] | select(.name == "interval-6h") | .status')" "active"
assert_eq "the other project still has its schedule, active" "$(fm project schedule list --project-id "$OTHER" --json | jq -r '[.schedules[] | select(.status != "deleted") | "\(.name):\(.status)"] | join(",")')" "other-keep:active"

TICK_SLOTS=${E2E_TICK_SLOTS:-2}
if [ "$TICK_SLOTS" -gt 0 ]; then
  say "the ticker does not fire the deleted tick-5m for $TICK_SLOTS slots (5 min each)"
  until_ts=$((TICK_CREATED + TICK_SLOTS * 300 + 20))
  while [ "$(date +%s)" -lt "$until_ts" ]; do sleep 10; done
  assert_eq "no run/thread started after $TICK_SLOTS slots of the deleted 5m schedule" "$(api_get "/api/projects/$PROJECT/threads" | jq '.threads | length')" 0
else
  unverified "ticker does not fire a deleted schedule" "E2E_TICK_SLOTS=0 skipped the ~$((2 * 5)) minute wait"
fi

say "Settings page editors and proposal Decline in headless Chromium"
PROP_TASK="t-prop-l2ab7"
seed_code=$(cat "$HERE/claude_projects/seed_proposal.exs")
seed_out=$(rpc "project_id = \"$PROJECT\"; task_id = \"$PROP_TASK\"
$seed_code")
assert_has "a coordinator proposal was seeded" "$seed_out" "SEEDED $PROP_TASK"
FOREMAN_API_URL="$API" FOREMAN_API_TOKEN="$E2E_API_TOKEN" HOME="$REAL_HOME" \
  node "$HERE/settings_page_ui.mjs" --base "http://localhost:$E2E_PORT" --token "$E2E_API_TOKEN" --project "$PROJECT" \
    --cli "$FOREMAN" --proposal "$PROP_TASK" --shot-dir "$SHOT_DIR" >"$WORK/settings-ui.out" 2>&1
set_rc=$?
if [ "$set_rc" -eq 3 ]; then
  unverified "Settings page in a browser" "$(grep '"event":"error"' "$WORK/settings-ui.out" | head -n 1 | jq -r '.message' 2>/dev/null | cut -c1-200)"
else
  while IFS= read -r line; do
    case "$line" in
      *'"check"'*)
        c_name=$(printf '%s' "$line" | jq -r '.check'); c_detail=$(printf '%s' "$line" | jq -c '.detail' | cut -c1-220)
        if [ "$(printf '%s' "$line" | jq -r '.ok')" = true ]; then pass "$c_name -- $c_detail"; else fail "$c_name -- $c_detail"; fi ;;
      *) note "$(printf '%s' "$line" | cut -c1-260)" ;;
    esac
  done < "$WORK/settings-ui.out"
  assert_true "the settings driver exited 0 (exit $set_rc)" test "$set_rc" -eq 0
fi
note "screenshots: $(ls "$SHOT_DIR" 2>/dev/null | tr '\n' ' ')"

summary
exit $?
