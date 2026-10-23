#!/usr/bin/env bash
# Extra real-GitHub stages (foreman-ksy0q): what stage 8 of claude_projects_flow.sh (github.sh) left open.
# Sourced after lib.sh and github.sh by scripts/e2e/github_live_extras.sh, never executed.
#
#   a   a run opens a PR (the title carries `e2e-skip`, which .coderabbit.yaml in the fixture uses to
#       keep the account-wide CodeRabbit app silent: its walkthrough comment would otherwise be
#       observed as a PR comment and its status as a check)
#   ui  the workspace UI buttons Fix CI / Address comments / Resolve conflicts clicked in a real
#       browser (Playwright, scripts/e2e/ui-a11y/pr_actions_live.mjs) on real PRs; no merge control
#   autofix  the pr_auto_fix policy: off (observed, not fixed) -> on (fixed automatically) -> a failure
#       no code can fix (an external commit status) stays bounded by max_attempts
#   createpr  the Create PR button after the run's own PR creation failed
#   postapproval  what a push AFTER merge approval does to the gate and the PR (observation only;
#       the fix is foreman-ehxy6)
#   protection  operator merge under GitHub branch protection (required status checks, a required
#       review, linear history). Branch protection does not exist on private repositories of a free
#       plan (HTTP 403), so this stage makes THE SCRATCH REPOSITORY public for its duration, after a
#       content safety scan, and restores it to private. It runs only with E2E_GH_ALLOW_PUBLIC=1.
#
# Every PR below is created by a real Foreman run (pi) from a bead; the harness only injects the
# GitHub-side events a real project meets (a failing commit, a review, a conflicting main).

GH_SHOTS=""
EVID=""
GH_UI=""
GH_OUT=""
GH_RC=0
GH_PR_FILE=""
GH_ORIGIN_URL=""
GH_FLIPPED=0
GH_PROTECTED=0
GH_FLIP_AT=""
GH_UNFLIP_AT=""
GH_EXT_CONTEXT="e2e/external-policy"
E2E_GH_QUIET_SECS=${E2E_GH_QUIET_SECS:-150}
E2E_GH_ALLOW_PUBLIC=${E2E_GH_ALLOW_PUBLIC:-0}
BROKEN=""

# Evidence (command output, events, UI JSON, screenshots) lives OUTSIDE the work dir: the cleanup removes that.
gh_extras_init() {
  GH_SHOTS="${E2E_EVIDENCE_DIR:-$ROOT/tmp/gx-evidence}/shots"
  EVID="${E2E_EVIDENCE_DIR:-$ROOT/tmp/gx-evidence}/files"
  mkdir -p "$GH_SHOTS" "$EVID"
}

# wait_thread <thread_id> <status-regex> <timeout> -> THREAD_STATUS (the helper claude_projects_flow.sh defines for itself)
wait_thread() {
  wt_start=$(date +%s); THREAD_STATUS=""
  while :; do
    THREAD_STATUS=$(api_get "/api/threads/$1" | jq -r '.thread.status // empty')
    if printf '%s' "$THREAD_STATUS" | grep -Eq "^($2)$"; then return 0; fi
    [ "$(elapsed "$wt_start")" -lt "$3" ] || return 1
    sleep "$E2E_POLL_SECS"
  done
}

# ---------------------------------------------------------------- PR bookkeeping

# gh_pr_save <prefix>: remember the current PR (thread, run, number, url, branch, file, bead) as <prefix>_*
gh_pr_save() {
  eval "$1_THREAD=\$GH_THREAD; $1_RUN=\$GH_RUN; $1_PR=\$GH_PR; $1_PR_URL=\$GH_PR_URL; $1_BRANCH=\$GH_BRANCH; $1_FILE=\$GH_PR_FILE; $1_BEAD=\${BEAD_ID:-}"
}

# gh_pr_use <prefix>: make the PR saved as <prefix> the current one
gh_pr_use() {
  eval "GH_THREAD=\${$1_THREAD:-}; GH_RUN=\${$1_RUN:-}; GH_PR=\${$1_PR:-}; GH_PR_URL=\${$1_PR_URL:-}; GH_BRANCH=\${$1_BRANCH:-}; GH_PR_FILE=\${$1_FILE:-}"
  if [ -z "$GH_PR" ]; then fail "PR '$1' does not exist yet: run the stage that creates it first"; return 1; fi
  return 0
}

# gh_new_pr <tag> <prefix>: a bead whose run adds note_<tag>.txt and (AutoPR) opens a PR; the PR is
# saved as <prefix> and left current. The `e2e-skip` marker in the title keeps CodeRabbit silent.
gh_new_pr() {
  np_tag=$1
  new_bead "e2e-skip gh-$SUFFIX note $np_tag" "Create a new file named note_$np_tag.txt in the repository root whose only content is the single line: note $np_tag. Do not modify any other file."
  [ -n "${BEAD_ID:-}" ] || { fail "br create produced no bead id for note $np_tag"; return 1; }
  thread_for_bead "$BEAD_ID" 240
  [ -n "$THREAD" ] || { fail "no thread appeared for bead $BEAD_ID"; return 1; }
  GH_THREAD=$THREAD; GH_RUN=${THREAD#run:}; GH_PR_FILE="note_$np_tag.txt"
  note "thread $GH_THREAD from bead $BEAD_ID (file $GH_PR_FILE)"
  if ! wait_thread "$GH_THREAD" "completed|ready_for_review|failed" "$E2E_RUN_TIMEOUT"; then
    fail "thread $GH_THREAD never finished (status $THREAD_STATUS)"; return 1
  fi
  [ "$THREAD_STATUS" = completed ] || { fail "run $GH_RUN ended '$THREAD_STATUS', not completed"; return 1; }
  gh_wait_card "$GH_THREAD" '.pr_url != null' 180 || true
  GH_PR_URL=$(printf '%s' "$GH_CARD" | jq -r '.pr_url // empty')
  GH_BRANCH=$(printf '%s' "$GH_CARD" | jq -r '.branch // empty')
  case "$GH_PR_URL" in
    "https://github.com/$GH_REPO/pull/"*) pass "run $GH_RUN opened a PR: $GH_PR_URL" ;;
    *) fail "no PR url on the card of $GH_THREAD: '$GH_PR_URL' ($(gh_card_line "$GH_CARD"))"; return 1 ;;
  esac
  GH_PR=${GH_PR_URL##*/}
  assert_has "the PR diff contains the run's file" "$(gh pr diff "$GH_PR" -R "$GH_REPO" 2>/dev/null)" "$GH_PR_FILE"
  gh_pr_save "$2"
  return 0
}

# gh_x_ready: the current PR is green on GitHub and Ready for review with the merge gate pending
gh_x_ready() {
  if gh_wait 300 "ci success" gh_ci_head_is success; then
    pass "GitHub reports the PR head green: $(gh_head)"
  else
    fail "CI never went green on $(gh_head) ($(gh_ci_state "$(gh_head)"))"; return 1
  fi
  if gh_wait_card "$GH_THREAD" '.group == "ready_for_review" and .merge_gate == "pending"' 420; then
    pass "Overview: Ready for review, merge gate pending: $(gh_card_line "$GH_CARD")"
  else
    fail "not Ready for review / gate pending: $(gh_card_line "$GH_CARD")"; return 1
  fi
  return 0
}

# ---------------------------------------------------------------- observation helpers

# gh_ci_state <sha> -> none | pending | failure | success  (all `test` check runs of that commit)
gh_ci_state() {
  gh api "repos/$GH_REPO/commits/$1/check-runs" 2>/dev/null | jq -r '[.check_runs[] | select(.name == "test")] | if length == 0 then "none" elif any(.[]; .status != "completed") then "pending" elif any(.[]; .conclusion != "success") then "failure" else "success" end' 2>/dev/null
}
gh_ci_head_is() { [ "$(gh_ci_state "$(gh_head)")" = "$1" ]; }

gh_prs() { api_get "/api/runs/${1:-$GH_RUN}/prs"; }
# gh_pr_field <jq filter over the watched-PR record of the current PR>
gh_pr_field() { gh_prs | jq -r --arg u "$GH_PR_URL" "[.prs[] | select(.pr_url == \$u)][0] | $1" 2>/dev/null; }
gh_pr_record() { gh_prs | jq -c --arg u "$GH_PR_URL" '[.prs[] | select(.pr_url == $u)][0] | {status, head_sha: (.head_sha[0:8]), checks_state, review_decision, comment_count, watching, merge_gate, fixes}' 2>/dev/null; }

gh_events() { # <run id> [first stream index]
  ge_code=$(cat "$ASSETS/run_events.exs")
  rpc "run_id = \"$1\"
$ge_code" 2>/dev/null | grep -E '^[0-9]+ ' | awk -v m="${2:-0}" '$1 + 0 >= m + 0'
}
gh_events_mark() { rpc "{:ok, e} = ForemanServer.EventStore.read_stream_forward(\"run:$1\", 0, 99_999_999); IO.puts(length(e))" 2>/dev/null | grep -E '^[0-9]+$' | tail -n 1; }
gh_events_note() { # <run id> <first stream index>
  gh_events "$1" "${2:-0}" > "$EVID/events-$1.txt"
  while IFS= read -r en_line; do note "  event $en_line"; done < "$EVID/events-$1.txt"
}
gh_events_count() { # <run id> <first index> <event type>
  gh_events "$1" "$2" | awk -v t="$3" '$3 == t' | wc -l | tr -d ' '
}

# gh_fm <label> <foreman args...>: run the CLI, keep stdout+stderr in GH_OUT / $EVID/<label>.out and the exit code in GH_RC
gh_fm() {
  gf_label=$1; shift
  GH_OUT=$(fm "$@" 2>&1); GH_RC=$?
  printf '%s\n' "$GH_OUT" > "$EVID/$gf_label.out"
}

# gh_approve_merge <label>: the operator approval of the current PR. `merge_approve` names the head the operator
# reviewed (foreman-ehxy6: `--head-sha` is required and the server checks it against GitHub), so this reads the
# PR's live head on GitHub and approves exactly that commit.
gh_approve_merge() {
  gam_head=$(gh_head)
  if [ -z "$gam_head" ]; then
    GH_RC=1; GH_OUT="could not read the head sha of PR $GH_PR from GitHub"
    printf '%s\n' "$GH_OUT" > "$EVID/$1.out"
    return 1
  fi
  gh_fm "$1" run approve-merge --id "$GH_RUN" --approver e2e-operator --identity "github:${GH_REPO%%/*}" --head-sha "$gam_head"
}

# gh_ui <thread> [driver flags]: the Playwright driver; one JSON object in GH_UI. Non-zero exit = the driver failed.
# The dev endpoint's check_origin accepts the LiveView websocket only from its configured host,
# `localhost`: a browser on 127.0.0.1 gets the page but its socket is refused and never mounts.
gh_ui() {
  gu_thread=$1; shift
  GH_UI=$(cd "$ROOT/scripts/e2e/ui-a11y" && node pr_actions_live.mjs --base "http://localhost:$E2E_PORT" --token "$E2E_API_TOKEN" --project "$PROJECT" --thread "$gu_thread" "$@" 2>"$WORK/ui-driver.err")
  gu_rc=$?
  printf '%s\n' "$GH_UI" > "$EVID/ui-last.json"
  return $gu_rc
}
gh_ui_get() { printf '%s' "$GH_UI" | jq -r "$1" 2>/dev/null; }
gh_ui_enabled() { gh_ui "$GH_THREAD" || return 1; [ "$(gh_ui_get ".buttons.$1.enabled")" = true ]; }
gh_ui_buttons_line() { gh_ui_get '[.buttons | to_entries[] | "\(.key)=\(if .value.present then (if .value.enabled then "enabled" else "disabled" end) else "absent" end)"] | join(" ")'; }

# ---------------------------------------------------------------- GitHub-side injectors

# gh_inject_failure <tag>: push a failing unit test to the current PR branch as the operator -> BROKEN
gh_inject_failure() {
  gh_clone_sync || return 1
  printf '\n\nclass InjectedFailure%s(unittest.TestCase):\n    def test_injected_failure(self):\n        self.assertEqual(1, 2, "injected by the e2e harness (%s)")\n' "$1" "$1" >> "$GH_OP/test_app.py"
  gh_push_as_operator commit -q -am "ci: inject a failing test ($1)" && gh_push_as_operator push -q origin "$GH_BRANCH" || return 1
  BROKEN=$(git -C "$GH_OP" rev-parse HEAD)
}

# gh_inject_conflict: main gets a different file at the path the PR adds (add/add conflict), proven with merge-tree
gh_inject_conflict() {
  gh_clone_sync || return 1
  git -C "$GH_OP" checkout -q -B conflict-main origin/main || return 1
  printf 'main wrote this file first (e2e conflict injector)\n' > "$GH_OP/$GH_PR_FILE"
  gh_push_as_operator add "$GH_PR_FILE" || return 1
  gh_push_as_operator commit -q -m "conflicting change on main: $GH_PR_FILE (e2e injector)" || return 1
  if git -C "$GH_OP" merge-tree --write-tree conflict-main "origin/$GH_BRANCH" >/dev/null 2>&1; then return 2; fi
  gh_push_as_operator push -q origin conflict-main:main
}

# gh_post_review: an inline review comment (one unresolved thread) on line 1 of the PR's file
gh_post_review() {
  gh_clone_sync || return 1
  gr_sha=$(gh_head)
  gr_payload=$(jq -n --arg sha "$gr_sha" --arg path "$GH_PR_FILE" '{commit_id: $sha, event: "COMMENT", body: "Review by the e2e harness.", comments: [{path: $path, line: 1, side: "RIGHT", body: "Please add a second line to this file that says exactly: reviewed"}]}')
  printf '%s' "$gr_payload" | gh api -X POST "repos/$GH_REPO/pulls/$GH_PR/reviews" --input - >"$EVID/review-post.out" 2>&1
}
gh_unresolved_threads() {
  gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:50){nodes{isResolved}}}}}' -f o="${GH_REPO%%/*}" -f r="${GH_REPO##*/}" -F n="$GH_PR" -q '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved|not)] | length' 2>/dev/null
}

# gh_status_post <sha> <state> <context>: a commit status (an external check no code change can fix)
gh_status_post() {
  gh api -X POST "repos/$GH_REPO/statuses/$1" -f state="$2" -f context="$3" -f description="e2e external check: $2" >/dev/null 2>&1
}

# ---------------------------------------------------------------- stages

gh_x_pr_a() {
  say "9a. PR-A: a Foreman run opens a real PR"
  gh_new_pr a PRA || return 1
  gh_x_ready
}

gh_x_ui_baseline() {
  say "9b. UI: the PR action buttons of a green PR (and no merge control anywhere)"
  gh_pr_use PRA || return 1
  gh_x_ready || return 1
  if ! gh_ui "$GH_THREAD" --shot "$GH_SHOTS/9b-green"; then fail "UI driver failed: $(gh_ui_get .error) $(cut -c1-300 "$WORK/ui-driver.err")"; return 1; fi
  note "buttons: $(gh_ui_buttons_line)"
  note "card: $(gh_ui_get '.card_title') | $(gh_ui_get '.card_status_line')"
  assert_eq "the card renders the PR action group" "$(gh_ui_get .pr_actions_aria)" "1"
  for bk in fix_ci address_comments resolve_conflicts create_pr; do
    assert_eq "$bk is present and disabled on a green PR" "$(gh_ui_get ".buttons.$bk | \"\\(.present)/\\(.enabled)\"")" "true/false"
    note "$bk reason: $(gh_ui_get ".buttons.$bk.reason")"
  done
  assert_eq "no merge control exists on the whole page" "$(gh_ui_get '.merge_controls | length')" "0"
  note "every button on the page: $(gh_ui_get '.page_buttons | join(" | ")')"
  return 0
}

# 9c: the failing PR with the policy OFF: observed, never fixed; then the Fix CI button
gh_x_policy_off_and_fix_ci() {
  say "9c. pr_auto_fix OFF: a failing check is observed and NOT fixed; then the Fix CI button"
  gh_pr_use PRA || return 1
  assert_eq "the project has no pr_auto_fix policy" "$(api_get "/api/projects/$PROJECT/settings" | jq -c '.settings.pr_auto_fix // null')" "null"
  gh_inject_failure off1 || { fail "could not push the failing commit"; return 1; }
  note "injected failing commit $BROKEN"
  if gh_wait 300 "ci failure" gh_ci_head_is failure; then pass "GitHub Actions reports the check FAILED on $BROKEN"; else fail "the injected failure never showed as failed ($(gh_ci_state "$BROKEN"))"; return 1; fi
  if gh_wait_card "$GH_THREAD" '.reason == "ci_failing"' 420; then pass "Foreman observed it: $(gh_card_line "$GH_CARD")"; else fail "Foreman never showed the failing check: $(gh_card_line "$GH_CARD")"; return 1; fi
  mark=$(gh_events_mark "$GH_RUN")
  note "quiet window: ${E2E_GH_QUIET_SECS}s with the policy off (PrMonitor polls every 30-60s; webhooks add check_run deliveries)"
  gh_quiet_wait "$E2E_GH_QUIET_SECS"
  assert_eq "the PR head did not move (nothing fixed it)" "$(gh_head)" "$BROKEN"
  assert_eq "no fix was requested while the policy was off (PrFixRequested events)" "$(gh_events_count "$GH_RUN" "$mark" PrFixRequested)" "0"
  assert_eq "fix attempts for ci" "$(gh_pr_field '.fixes.attempts.ci')" "0"
  assert_eq "no fix in flight" "$(gh_pr_field '.fixes.in_flight')" "null"
  note "PR record: $(gh_pr_record)"
  # the UI button
  mark=$(gh_events_mark "$GH_RUN")
  if ! gh_ui "$GH_THREAD" --click fix_ci --shot "$GH_SHOTS/9c-fix-ci"; then fail "UI click failed: $(gh_ui_get .error) $(cut -c1-300 "$WORK/ui-driver.err")"; return 1; fi
  note "buttons before the click: $(gh_ui_get '[.buttons | to_entries[] | "\(.key)=\(if .value.present then (if .value.enabled then "enabled" else "disabled" end) else "absent" end)"] | join(" ")')"
  note "notice after the click: $(gh_ui_get .notice)"
  assert_has "the UI notice names the dispatched command" "$(gh_ui_get .notice)" "run.pr.fix_ci"
  assert_eq "the notice is not an error" "$(gh_ui_get .notice_is_error)" "false"
  if gh_wait 900 "fix commit" gh_head_moved_from "$BROKEN"; then pass "the button's fix thread pushed a commit: $(gh_head)"; else fail "no fix commit within 900s of the click"; gh_events_note "$GH_RUN" "$mark"; return 1; fi
  if gh_wait 300 "ci green" gh_ci_head_is success; then pass "CI is green again on the fixed head"; else fail "CI not green after the UI fix ($(gh_ci_state "$(gh_head)"))"; fi
  if gh_wait_card "$GH_THREAD" '.group == "ready_for_review"' 420; then pass "Overview: back in Ready for review: $(gh_card_line "$GH_CARD")"; else fail "not back in Ready for review: $(gh_card_line "$GH_CARD")"; fi
  gh_events_note "$GH_RUN" "$mark"
  assert_eq "the fix was recorded as an operator request" "$(gh_events "$GH_RUN" "$mark" | awk '$3 == "PrFixRequested"' | grep -c 'trigger=operator')" "1"
  note "PR record: $(gh_pr_record)"
  return 0
}

gh_quiet_wait() { # <seconds>: sleep in slices, failing fast when the server died
  gq_end=$(( $(date +%s) + $1 ))
  while [ "$(date +%s)" -lt "$gq_end" ]; do
    gh_server_alive || return 1
    sleep 10
  done
}

gh_x_ui_address() {
  say "9d. UI: the Address comments button on a real unresolved review thread"
  gh_pr_use PRA || return 1
  before=$(gh_head)
  mark=$(gh_events_mark "$GH_RUN")
  gh_post_review && pass "inline review comment posted on $GH_PR_FILE:1" || { fail "posting the review failed: $(cut -c1-300 "$EVID/review-post.out")"; return 1; }
  assert_eq "GitHub shows one unresolved review thread" "$(gh_unresolved_threads)" "1"
  if gh_wait 420 "address-comments enabled" gh_ui_enabled address_comments; then
    pass "the Address comments button became enabled: $(gh_ui_buttons_line)"
  else
    fail "the Address comments button never became enabled: $(gh_ui_buttons_line) | $(gh_pr_record)"; return 1
  fi
  if ! gh_ui "$GH_THREAD" --click address_comments --shot "$GH_SHOTS/9d-address"; then fail "UI click failed: $(gh_ui_get .error) $(cut -c1-300 "$WORK/ui-driver.err")"; return 1; fi
  note "notice after the click: $(gh_ui_get .notice)"
  assert_has "the UI notice names the dispatched command" "$(gh_ui_get .notice)" "run.pr.address_comments"
  assert_eq "the notice is not an error" "$(gh_ui_get .notice_is_error)" "false"
  if gh_wait 900 "address commit" gh_head_moved_from "$before"; then
    pass "the agent pushed a commit addressing the comment: $(gh_head)"
    gh_clone_sync
    assert_has "the file now carries the requested line" "$(cat "$GH_OP/$GH_PR_FILE")" "reviewed"
  else
    fail "no commit addressing the review comment within 900s"; gh_events_note "$GH_RUN" "$mark"; return 1
  fi
  gh_wait 300 "ci green" gh_ci_head_is success && pass "CI green after addressing comments" || fail "CI not green after addressing comments ($(gh_ci_state "$(gh_head)"))"
  gh_events_note "$GH_RUN" "$mark"
  return 0
}

gh_x_ui_conflicts() {
  say "9e. UI: the Resolve conflicts button on a real merge conflict"
  gh_pr_use PRA || return 1
  mark=$(gh_events_mark "$GH_RUN")
  gh_inject_conflict
  gx_rc=$?
  [ "$gx_rc" = 0 ] || { fail "could not construct a conflicting commit against the PR head (rc=$gx_rc)"; return 1; }
  pass "pushed a conflicting commit to main of $GH_REPO (merge-tree proves it conflicts with the PR)"
  gh_wait 120 "github conflict" gh_pr_conflicting && pass "GitHub reports the PR as CONFLICTING" || fail "GitHub never reported CONFLICTING (mergeable=$(gh pr view "$GH_PR" -R "$GH_REPO" --json mergeable -q .mergeable))"
  if gh_wait_card "$GH_THREAD" '.reason == "conflict"' 420; then pass "Overview: Waiting on you for reason conflict: $(gh_card_line "$GH_CARD")"; else fail "Foreman never showed the conflict: $(gh_card_line "$GH_CARD")"; fi
  if gh_wait 300 "resolve-conflicts enabled" gh_ui_enabled resolve_conflicts; then pass "the Resolve conflicts button is enabled: $(gh_ui_buttons_line)"; else fail "the Resolve conflicts button never became enabled: $(gh_ui_buttons_line)"; return 1; fi
  if ! gh_ui "$GH_THREAD" --click resolve_conflicts --shot "$GH_SHOTS/9e-conflicts"; then fail "UI click failed: $(gh_ui_get .error) $(cut -c1-300 "$WORK/ui-driver.err")"; return 1; fi
  note "notice after the click: $(gh_ui_get .notice)"
  assert_has "the UI notice names the dispatched command" "$(gh_ui_get .notice)" "run.pr.resolve_conflicts"
  assert_eq "the notice is not an error" "$(gh_ui_get .notice_is_error)" "false"
  if gh_wait 900 "mergeable again" gh_pr_mergeable; then pass "the agent resolved the conflict: GitHub reports MERGEABLE (head $(gh_head))"; else fail "PR still not mergeable after 900s (mergeable=$(gh pr view "$GH_PR" -R "$GH_REPO" --json mergeable -q .mergeable))"; gh_events_note "$GH_RUN" "$mark"; return 1; fi
  gh_wait 300 "ci green" gh_ci_head_is success && pass "CI green on the conflict-resolved head" || fail "CI not green after resolving conflicts ($(gh_ci_state "$(gh_head)"))"
  gh_events_note "$GH_RUN" "$mark"
  return 0
}

# 9f: the policy on a fresh PR (attempts start at 0)
gh_x_autofix() {
  say "9f. pr_auto_fix: off -> observed -> on -> ONE automatic fix; an unfixable failure stays bounded"
  gh_new_pr x PRX || return 1
  gh_x_ready || return 1
  assert_eq "the project has no pr_auto_fix policy" "$(api_get "/api/projects/$PROJECT/settings" | jq -c '.settings.pr_auto_fix // null')" "null"
  gh_inject_failure auto1 || { fail "could not push the failing commit"; return 1; }
  note "injected failing commit $BROKEN"
  gh_wait 300 "ci failure" gh_ci_head_is failure && pass "GitHub Actions reports the check FAILED on $BROKEN" || { fail "the injected failure never showed as failed"; return 1; }
  gh_wait_card "$GH_THREAD" '.reason == "ci_failing"' 420 && pass "Foreman observed it: $(gh_card_line "$GH_CARD")" || { fail "Foreman never showed the failing check: $(gh_card_line "$GH_CARD")"; return 1; }
  note "policy still off: quiet window of 90s before it is enabled"
  mark=$(gh_events_mark "$GH_RUN")
  gh_quiet_wait 90
  assert_eq "nothing fixed the PR while the policy was off" "$(gh_head)" "$BROKEN"
  assert_eq "no PrFixRequested while the policy was off" "$(gh_events_count "$GH_RUN" "$mark" PrFixRequested)" "0"
  gh_fm autofix-on project update --pr-auto-fix '{"kinds":["ci"],"max_attempts":2,"cooldown_seconds":0}' "$PROJECT"
  [ "$GH_RC" = 0 ] && pass "pr_auto_fix enabled: kinds=[ci] max_attempts=2 cooldown=0" || { fail "enabling pr_auto_fix failed: $(printf '%s' "$GH_OUT" | cut -c1-300)"; return 1; }
  assert_eq "the policy reads back" "$(api_get "/api/projects/$PROJECT/settings" | jq -c '.settings.pr_auto_fix')" '{"cooldown_seconds":0,"kinds":["ci"],"max_attempts":2}'
  mark=$(gh_events_mark "$GH_RUN")
  note "waiting for the AUTOMATIC fix (no operator command is sent from here on)"
  if gh_wait 1200 "automatic fix commit" gh_head_moved_from "$BROKEN"; then pass "a fix commit landed on the PR branch with no operator command: $(gh_head)"; else fail "policy on but no automatic fix within 1200s"; gh_events_note "$GH_RUN" "$mark"; note "PR record: $(gh_pr_record)"; return 1; fi
  gh_wait 300 "ci green" gh_ci_head_is success && pass "CI is green on the automatically fixed head" || fail "CI not green after the automatic fix ($(gh_ci_state "$(gh_head)"))"
  gh_wait_card "$GH_THREAD" '.group == "ready_for_review"' 420 && pass "Overview: back in Ready for review: $(gh_card_line "$GH_CARD")" || fail "not back in Ready for review: $(gh_card_line "$GH_CARD")"
  gh_events_note "$GH_RUN" "$mark"
  assert_eq "the request was automatic (trigger=auto)" "$(gh_events "$GH_RUN" "$mark" | awk '$3 == "PrFixRequested"' | grep -c 'trigger=auto')" "1"
  assert_eq "no operator-triggered fix was recorded" "$(gh_events "$GH_RUN" "$mark" | awk '$3 == "PrFixRequested"' | grep -c 'trigger=operator')" "0"
  assert_eq "exactly one automatic attempt so far" "$(gh_pr_field '.fixes.attempts.ci')" "1"
  note "PR record: $(gh_pr_record)"

  # Bounded: a failing check no code change can fix (an external commit status).
  mark=$(gh_events_mark "$GH_RUN")
  seen=$(gh_head)
  gh_status_post "$seen" failure "$GH_EXT_CONTEXT" && pass "posted a FAILING external status '$GH_EXT_CONTEXT' on $seen (no code change can clear it)" || { fail "could not post the external status"; return 1; }
  gh_wait_card "$GH_THREAD" '.reason == "ci_failing"' 420 && pass "Foreman observed the external failure: $(gh_card_line "$GH_CARD")" || fail "Foreman never showed the external failure: $(gh_card_line "$GH_CARD")"
  gb_start=$(date +%s)
  while :; do
    gb_head=$(gh_head)
    if [ "$gb_head" != "$seen" ]; then
      gh_status_post "$gb_head" failure "$GH_EXT_CONTEXT" && note "head moved to $gb_head: the external failure re-posted on it"
      seen=$gb_head
    fi
    gb_ex=$(gh_pr_field '.fixes.exhausted.ci // empty')
    [ -n "$gb_ex" ] && break
    [ "$(elapsed "$gb_start")" -lt 1500 ] || break
    gh_server_alive || break
    sleep 10
  done
  gh_events_note "$GH_RUN" "$mark"
  note "PR record: $(gh_pr_record)"
  [ -n "$gb_ex" ] && pass "PrFixExhausted: the policy gave up on head ${gb_ex:0:8}" || fail "the policy never recorded PrFixExhausted within 1500s"
  gb_attempts=$(gh_pr_field '.fixes.attempts.ci')
  [ "${gb_attempts:-99}" -le 2 ] && pass "automatic attempts stayed within max_attempts=2 (attempts.ci = $gb_attempts)" || fail "attempts.ci = $gb_attempts exceeds max_attempts=2"
  mark=$(gh_events_mark "$GH_RUN")
  gh_quiet_wait 120
  assert_eq "no further fix was requested after the give-up (120s)" "$(gh_events_count "$GH_RUN" "$mark" PrFixRequested)" "0"
  assert_eq "attempts did not grow after the give-up" "$(gh_pr_field '.fixes.attempts.ci')" "$gb_attempts"
  gh_status_post "$(gh_head)" success "$GH_EXT_CONTEXT" && note "external status set to success on $(gh_head) (the PR is green again)"
  gh_fm autofix-off project update --clear pr_auto_fix "$PROJECT"
  [ "$GH_RC" = 0 ] && pass "pr_auto_fix cleared again" || fail "clearing pr_auto_fix failed: $(printf '%s' "$GH_OUT" | cut -c1-300)"
  return 0
}

# 9g: Create PR after the run's own PR creation failed (origin unreachable while the run finishes)
gh_x_createpr() {
  say "9g. UI: the Create PR button after the run's PR creation failed; the PR it opens is mergeable by the operator"
  gx_tag=${E2E_GH_CREATEPR_TAG:-b}
  GH_ORIGIN_URL=$(git -C "$GH_CLONE" remote get-url origin)
  git -C "$GH_CLONE" remote set-url origin "file://$WORK/no-such-remote.git"
  note "origin of the project checkout pointed at a nonexistent remote while the run finishes (restored right after)"
  new_bead "e2e-skip gh-$SUFFIX note $gx_tag" "Create a new file named note_$gx_tag.txt in the repository root whose only content is the single line: note $gx_tag. Do not modify any other file."
  thread_for_bead "$BEAD_ID" 240
  if [ -z "$THREAD" ]; then git -C "$GH_CLONE" remote set-url origin "$GH_ORIGIN_URL"; fail "no thread appeared for bead $BEAD_ID"; return 1; fi
  GH_THREAD=$THREAD; GH_RUN=${THREAD#run:}; GH_PR_FILE=note_$gx_tag.txt
  wait_thread "$GH_THREAD" "completed|ready_for_review|failed" "$E2E_RUN_TIMEOUT"
  git -C "$GH_CLONE" remote set-url origin "$GH_ORIGIN_URL"
  note "thread $GH_THREAD ended $THREAD_STATUS; origin restored to $GH_ORIGIN_URL"
  [ "$THREAD_STATUS" = completed ] || { fail "the run ended '$THREAD_STATUS', not completed"; return 1; }
  sleep 5
  gx_card=$(gh_card "$GH_THREAD")
  note "card: $(gh_card_line "$gx_card") pr_url=$(printf '%s' "$gx_card" | jq -r '.pr_url // "none"') branch=$(printf '%s' "$gx_card" | jq -r '.branch // "none"')"
  assert_eq "the run completed without a PR (AutoPR failed: unreachable origin)" "$(printf '%s' "$gx_card" | jq -r '.pr_url // "none"')" "none"
  GH_BRANCH=$(printf '%s' "$gx_card" | jq -r '.branch // empty')
  mark=0
  if ! gh_ui "$GH_THREAD" --shot "$GH_SHOTS/9g-before"; then fail "UI driver failed: $(gh_ui_get .error)"; return 1; fi
  note "buttons: $(gh_ui_buttons_line)"
  assert_eq "Create PR is enabled" "$(gh_ui_get '.buttons.create_pr.enabled')" "true"
  if ! gh_ui "$GH_THREAD" --click create_pr --shot "$GH_SHOTS/9g-create-pr"; then fail "UI click failed: $(gh_ui_get .error) $(cut -c1-300 "$WORK/ui-driver.err")"; return 1; fi
  note "notice after the click: $(gh_ui_get .notice)"
  assert_has "the UI notice names the dispatched command" "$(gh_ui_get .notice)" "run.pr.create"
  assert_eq "the notice is not an error" "$(gh_ui_get .notice_is_error)" "false"
  gx_url=""
  gx_n=0
  while [ -z "$gx_url" ] && [ "$gx_n" -lt 60 ]; do
    gx_url=$(gh pr list -R "$GH_REPO" --head "$GH_BRANCH" --state open --json url -q '.[0].url // empty' 2>/dev/null)
    [ -n "$gx_url" ] || { sleep 3; gx_n=$((gx_n + 3)); }
  done
  [ -n "$gx_url" ] && pass "GitHub has the PR the button opened: $gx_url" || { fail "no PR for branch $GH_BRANCH appeared on GitHub"; return 1; }
  GH_PR_URL=$gx_url; GH_PR=${gx_url##*/}
  gh_pr_save PRB
  assert_has "the PR diff contains the run's file" "$(gh pr diff "$GH_PR" -R "$GH_REPO" 2>/dev/null)" "$GH_PR_FILE"
  gh_wait_card "$GH_THREAD" '.pr_url != null' 120 && pass "the thread card carries the PR: $(gh_card_line "$GH_CARD")" || fail "the thread card never showed the new PR"
  gh_wait 300 "ci green" gh_ci_head_is success && pass "CI green on the new PR" || fail "CI not green on the new PR ($(gh_ci_state "$(gh_head)"))"
  sleep 20
  gh_events_note "$GH_RUN" 0
  note "PR record: $(gh_pr_record)"
  # The PR enters the merge gate like the PR of a run's own AutoPR (PrReady): without it the card is not
  # Ready for review, approve-merge answers merge_gate_not_found and the PR can never be merged by the operator.
  if gh_wait_card "$GH_THREAD" '.group == "ready_for_review" and .merge_gate == "pending"' 300; then
    pass "Overview: the PR the button opened is Ready for review, merge gate pending: $(gh_card_line "$GH_CARD")"
  else
    fail "the PR the button opened is not held at the merge gate: $(gh_card_line "$GH_CARD")"
  fi
  gh_approve_merge createpr-approve
  [ "$GH_RC" = 0 ] && pass "operator approve-merge accepted for the PR the button opened" || { fail "approve-merge refused: $(printf '%s' "$GH_OUT" | tr '\n' ' ' | cut -c1-300)"; return 1; }
  gh_fm createpr-merge run merge --id "$GH_RUN"
  [ "$GH_RC" = 0 ] && pass "operator merge accepted for the PR the button opened" || fail "merge refused: $(printf '%s' "$GH_OUT" | tr '\n' ' ' | cut -c1-300)"
  assert_eq "GitHub reports the PR MERGED" "$(gh pr view "$GH_PR" -R "$GH_REPO" --json state -q .state 2>/dev/null)" "MERGED"
  gh_wait_card "$GH_THREAD" '.group == "resolved"' 300 && pass "Overview: the thread is Resolved ($(gh_card_line "$GH_CARD"))" || fail "thread not Resolved after the merge: $(gh_card_line "$GH_CARD")"
  return 0
}

# 9h: a push AFTER merge approval. Written against the contract of foreman-ehxy6 (#650): the push voids the approval and the
# gate is held again. NOT yet run live (the scratch repository this harness was built against is archived); the build before
# #650 was observed to strand the PR instead, see docs/acceptance/live-github-protection-ui-autofix.md.
gh_x_postapproval() {
  say "9h. a push AFTER merge approval voids the approval: the gate is held again and only a fresh approval of the new head merges"
  gh_pr_use PRA || return 1
  gh_wait_card "$GH_THREAD" '.group == "ready_for_review"' 420 || true
  note "before approval: $(gh_card_line "$GH_CARD") head=$(gh_head | cut -c1-8) record=$(gh_pr_record)"
  mark=$(gh_events_mark "$GH_RUN")
  gh_approve_merge pa-approve
  [ "$GH_RC" = 0 ] && pass "operator approve-merge accepted" || { fail "approve-merge failed: $(printf '%s' "$GH_OUT" | cut -c1-300)"; return 1; }
  approved_head=$(gh_head)
  sleep 5
  note "after approval: card=$(gh_card_line "$(gh_card "$GH_THREAD")") merge_gate=$(gh_pr_field .merge_gate) head=${approved_head:0:8}"
  # (a) a plain push to the PR branch after approval
  gh_clone_sync
  printf '\npost-approval push (e2e)\n' >> "$GH_OP/$GH_PR_FILE"
  gh_push_as_operator commit -q -am "post-approval push (e2e)" && gh_push_as_operator push -q origin "$GH_BRANCH" || { fail "could not push after approval"; return 1; }
  pushed=$(git -C "$GH_OP" rev-parse HEAD)
  note "pushed ${pushed:0:8} to $GH_BRANCH after the gate was approved on ${approved_head:0:8}"
  gh_wait 300 "foreman records the new head" gh_pr_head_recorded "$pushed" && pass "Foreman's PR watch recorded the new head ${pushed:0:8}" || fail "Foreman never recorded the new head (record: $(gh_pr_record))"
  gh_wait 300 "ci green" gh_ci_head_is success || true
  sleep 30
  note "after the push: card=$(gh_card_line "$(gh_card "$GH_THREAD")") merge_gate=$(gh_pr_field .merge_gate) record=$(gh_pr_record)"
  gh_events_note "$GH_RUN" "$mark"
  assert_eq "no second PrReady was recorded by the push" "$(gh_events_count "$GH_RUN" "$mark" PrReady)" "0"
  assert_eq "the push voided the approval: the merge gate is pending again" "$(gh_pr_field .merge_gate)" "pending"
  gh_fm pa-stale run approve-merge --id "$GH_RUN" --approver e2e-operator --identity "github:${GH_REPO%%/*}" --head-sha "$approved_head"
  note "approve-merge naming the OLD head ${approved_head:0:8}: rc=$GH_RC: $(printf '%s' "$GH_OUT" | tr '\n' ' ' | cut -c1-400)"
  [ "$GH_RC" != 0 ] && pass "approving the old head is refused after the push" || fail "the old head was approved after a push moved the PR"
  gh_fm pa-merge run merge --id "$GH_RUN"
  note "merge: rc=$GH_RC: $(printf '%s' "$GH_OUT" | tr '\n' ' ' | cut -c1-400)"
  [ "$GH_RC" != 0 ] && pass "the merge was refused after the post-approval push" || fail "the merge succeeded after a post-approval push (the approval was not voided)"
  assert_eq "the PR is still OPEN on GitHub" "$(gh pr view "$GH_PR" -R "$GH_REPO" --json state -q .state 2>/dev/null)" "OPEN"
  # (b) the push of an operator-requested Fix CI after approval
  mark2=$(gh_events_mark "$GH_RUN")
  gh_inject_failure postapproval || { fail "could not push the failing commit"; return 1; }
  gh_wait 300 "ci failure" gh_ci_head_is failure && pass "CI failed on the post-approval push $BROKEN" || fail "post-approval failure never showed"
  gh_wait_card "$GH_THREAD" '.reason == "ci_failing"' 420 && note "card: $(gh_card_line "$GH_CARD")" || note "card did not show ci_failing: $(gh_card_line "$GH_CARD")"
  gh_fm pa-fixci run fix-ci "$GH_RUN" --pr "$GH_PR_URL"
  note "fix-ci after approval: rc=$GH_RC: $(printf '%s' "$GH_OUT" | tr '\n' ' ' | cut -c1-200)"
  gh_wait 900 "fix commit" gh_head_moved_from "$BROKEN" && pass "the fix pushed ${BROKEN:0:8} -> $(gh_head | cut -c1-8)" || fail "no fix commit after approval within 900s"
  gh_wait 300 "ci green" gh_ci_head_is success || true
  sleep 30
  note "after the post-approval fix: card=$(gh_card_line "$(gh_card "$GH_THREAD")") merge_gate=$(gh_pr_field .merge_gate) record=$(gh_pr_record)"
  gh_events_note "$GH_RUN" "$mark2"
  assert_eq "no PrReady after the fix push either" "$(gh_events_count "$GH_RUN" "$mark2" PrReady)" "0"
  gh_approve_merge pa-reapprove2
  note "approve-merge naming the fixed head: rc=$GH_RC: $(printf '%s' "$GH_OUT" | tr '\n' ' ' | cut -c1-400)"
  [ "$GH_RC" = 0 ] && pass "a fresh approval naming the fixed head is accepted" || fail "approve-merge of the fixed head refused: $(printf '%s' "$GH_OUT" | tr '\n' ' ' | cut -c1-300)"
  gh_fm pa-merge2 run merge --id "$GH_RUN"
  note "merge after the fix: rc=$GH_RC: $(printf '%s' "$GH_OUT" | tr '\n' ' ' | cut -c1-400)"
  [ "$GH_RC" = 0 ] && pass "the merge of the freshly approved head was accepted" || fail "merge of the freshly approved head refused: $(printf '%s' "$GH_OUT" | tr '\n' ' ' | cut -c1-300)"
  assert_eq "GitHub reports the PR MERGED" "$(gh pr view "$GH_PR" -R "$GH_REPO" --json state -q .state 2>/dev/null)" "MERGED"
  note "final: card=$(gh_card_line "$(gh_card "$GH_THREAD")") merge_gate=$(gh_pr_field .merge_gate) record=$(gh_pr_record)"
  return 0
}
gh_pr_head_recorded() { [ "$(gh_pr_field '.head_sha')" = "$1" ]; }

# ---------------------------------------------------------------- 9i: branch protection

# What a PUBLIC repository exposes outlives the flip: every commit of every branch and every refs/pull/* ref
# (a PR keeps its head ref after its branch is deleted, and GitHub offers no way to delete one) stays
# fetchable, and so do PR text, check output and Actions logs. The scan therefore reads the WHOLE history of
# EVERY ref, every path ever committed, commit metadata, PR/review/comment text, check output, Actions logs
# and the repository metadata. Any hit fails the stage BEFORE the flip; the repository stays private and the
# protection stage is UNVERIFIED. A hit is reported by class and location, never by value.
#
# Paths a commit may ever have touched: the seeded fixture and the one note file each bead's agent adds.
GH_PUBLIC_ALLOWED_FILES='^(\.github/workflows/(ci|approve)\.yml|\.gitignore|\.coderabbit\.yaml|README\.md|app\.py|test_app\.py|note_[a-z0-9_]+\.txt)$'
GH_RE_TOKEN='gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|BEGIN [A-Z ]*PRIVATE KEY|[Bb]earer [A-Za-z0-9._-]{16,}'
GH_RE_PATH='/Users/|/private/|/var/folders|/home/[a-z]|/Library/|/opt/homebrew|/nix/store|\.devbox|foreman-wt|/tmp/'
GH_RE_ENV='FOREMAN_[A-Z0-9_]+[=:]|FOREMAN_(API_TOKEN|GITHUB_WEBHOOK_SECRET)|GH_TOKEN=|GITHUB_TOKEN=|GIT_CONFIG_(KEY|VALUE)_[0-9]'
GH_RE_TRANSCRIPT='"role" *: *"(user|assistant|system|tool)"|tool_use|<thinking>|trycloudflare'
GH_PUBLIC_CLASSES="TOKEN PATH ENV TRANSCRIPT"

# gh_public_scan_file <label> <file>: every class, and this run's exact secrets/identity, over one text file
gh_public_scan_file() {
  gsf_bad=0
  gsf_text=$2
  # the GitHub runner's own paths are not the operator's
  if [ "$(basename "$2")" = actions-logs.txt ]; then
    gsf_text="$2.filtered"
    grep -v '/home/runner' "$2" > "$gsf_text"
  fi
  for gsf_c in $GH_PUBLIC_CLASSES; do
    eval "gsf_re=\$GH_RE_$gsf_c"
    gsf_lines=$(grep -nE -- "$gsf_re" "$gsf_text" 2>/dev/null | cut -d: -f1 | head -n 3 | tr '\n' ' ')
    if [ -n "$gsf_lines" ]; then fail "$1: the $gsf_c class matches (lines: $gsf_lines of $(basename "$2"))"; gsf_bad=1; fi
  done
  if [ -s "$EVID/secrets.txt" ] && grep -qF -f "$EVID/secrets.txt" "$gsf_text" 2>/dev/null; then fail "$1: an exact secret or identity of this run appears in $(basename "$2")"; gsf_bad=1; fi
  return $gsf_bad
}

gh_public_safety_check() {
  say "9i-0. content safety scan of $GH_REPO before it is made public (all refs, PR refs, whole history)"
  gps_bad=0
  # exact values that must never appear: this run's tokens and the operator's real git identity
  : > "$EVID/secrets.txt"
  for gps_s in "${GH_TOKEN:-}" "$E2E_API_TOKEN" "$GH_HOOK_SECRET" "$(git config --global user.email 2>/dev/null)" "$(git config --global user.name 2>/dev/null)" "$(gh api user -q '.email // empty' 2>/dev/null)"; do
    [ -n "$gps_s" ] && printf '%s\n' "$gps_s" >> "$EVID/secrets.txt"
  done

  # every ref the repository exposes: branches and the pull request refs (head and merge)
  git -C "$GH_OP" fetch -q origin '+refs/heads/*:refs/remotes/origin/*' '+refs/pull/*:refs/remotes/pull/*' || { fail "cannot fetch every branch and refs/pull/* of $GH_REPO"; return 1; }
  git -C "$GH_OP" for-each-ref --format='%(refname)' refs/remotes > "$EVID/refs.txt"
  gps_branches=$(grep -c '^refs/remotes/origin/' "$EVID/refs.txt")
  gps_prrefs=$(grep -c '^refs/remotes/pull/' "$EVID/refs.txt")
  note "refs scanned: $gps_branches branch(es), $gps_prrefs pull request ref(s): $(tr '\n' ' ' < "$EVID/refs.txt" | sed -e 's#refs/remotes/##g')"
  [ "$gps_branches" -gt 0 ] || { fail "no branch fetched from $GH_REPO"; return 1; }
  gps_revs=$(git -C "$GH_OP" rev-list --all)
  gps_ncommits=$(printf '%s\n' "$gps_revs" | grep -c .)

  # 1. every path ever committed on any ref must be part of the synthetic fixture
  git -C "$GH_OP" log --all -m --name-only --format= | grep -v '^$' | sort -u > "$EVID/paths-ever.txt"
  note "paths ever committed on any ref: $(tr '\n' ' ' < "$EVID/paths-ever.txt")"
  gps_extra=$(grep -Ev "$GH_PUBLIC_ALLOWED_FILES" "$EVID/paths-ever.txt")
  [ -z "$gps_extra" ] && pass "every path ever committed ($(wc -l < "$EVID/paths-ever.txt" | tr -d ' ') distinct) is part of the synthetic fixture" || { fail "paths outside the synthetic fixture in the history: $(printf '%s' "$gps_extra" | tr '\n' ' ')"; gps_bad=1; }

  # 2. file contents at EVERY commit of EVERY ref, and the whole patch history, by class
  gps_hit=0
  for gps_c in $GH_PUBLIC_CLASSES; do
    eval "gps_re=\$GH_RE_$gps_c"
    gps_where=$(git -C "$GH_OP" grep -IlE "$gps_re" $gps_revs -- 2>/dev/null | head -n 3 | cut -c1-60 | tr '\n' ' ')
    if [ -n "$gps_where" ]; then fail "the $gps_c class matches file contents in the history (rev:path): $gps_where"; gps_hit=1; gps_bad=1; fi
  done
  gps_where=$(git -C "$GH_OP" grep -IlF -f "$EVID/secrets.txt" $gps_revs -- 2>/dev/null | head -n 3 | cut -c1-60 | tr '\n' ' ')
  if [ -n "$gps_where" ]; then fail "an exact secret or identity of this run appears in file contents (rev:path): $gps_where"; gps_hit=1; gps_bad=1; fi
  [ "$gps_hit" = 0 ] && pass "no token, FOREMAN_* dump, transcript or local path in the contents of any file at any of $gps_ncommits commit(s) on any ref"
  git -C "$GH_OP" log --all -m -p --format='COMMIT %H%n%an <%ae>%n%cn <%ce>%n%B' > "$EVID/history-all.patch"
  gh_public_scan_file "git log --all -p" "$EVID/history-all.patch" && pass "the whole patch history ($(wc -c < "$EVID/history-all.patch" | tr -d ' ') bytes) is clean" || gps_bad=1
  # 3. commit identities: only synthetic ones (or GitHub's own for a squash merge)
  git -C "$GH_OP" log --all --format='%an <%ae>%n%cn <%ce>' | sort -u > "$EVID/identities.txt"
  note "commit identities: $(tr '\n' ';' < "$EVID/identities.txt")"
  gps_ident=$(grep -Ev '<[^>]*@example\.com>$|^GitHub <noreply@github\.com>$' "$EVID/identities.txt")
  [ -z "$gps_ident" ] && pass "every commit author and committer is synthetic (@example.com) or GitHub's own" || { fail "non-synthetic commit identity in the history: $(printf '%s' "$gps_ident" | tr '\n' ';')"; gps_bad=1; }

  # 4. PR text, comments, reviews, check output and statuses of every PR head, the repository metadata
  { gh api "repos/$GH_REPO/pulls?state=all&per_page=100" --paginate -q '.[] | .title, .body' 2>/dev/null
    gh api "repos/$GH_REPO/issues/comments?per_page=100" --paginate -q '.[].body' 2>/dev/null
    gh api "repos/$GH_REPO/pulls/comments?per_page=100" --paginate -q '.[].body' 2>/dev/null
    for gps_pr in $(gh api "repos/$GH_REPO/pulls?state=all&per_page=100" --paginate -q '.[].number' 2>/dev/null); do gh api "repos/$GH_REPO/pulls/$gps_pr/reviews" -q '.[].body' 2>/dev/null; done
    for gps_sha in $(git -C "$GH_OP" for-each-ref --format='%(objectname)' refs/remotes/pull refs/remotes/origin | sort -u); do
      gh api "repos/$GH_REPO/commits/$gps_sha/check-runs" -q '.check_runs[] | .name, .output.title, .output.summary, .output.text' 2>/dev/null
      gh api "repos/$GH_REPO/commits/$gps_sha/statuses" -q '.[] | .context, .description, .target_url' 2>/dev/null
    done
    gh repo view "$GH_REPO" --json description,homepageUrl,repositoryTopics 2>/dev/null; } > "$EVID/github-text.txt"
  gh_public_scan_file "PR text / check output / repository metadata" "$EVID/github-text.txt" && pass "PR titles, bodies, comments, reviews, check output, statuses and repository metadata are clean ($(wc -c < "$EVID/github-text.txt" | tr -d ' ') bytes)" || gps_bad=1

  # 5. every Actions log (public the moment the repository is)
  : > "$EVID/actions-logs.txt"
  gps_nruns=0
  for gps_run in $(gh run list -R "$GH_REPO" --limit 300 --json databaseId -q '.[].databaseId' 2>/dev/null); do
    gh run view "$gps_run" -R "$GH_REPO" --log >> "$EVID/actions-logs.txt" 2>/dev/null
    gps_nruns=$((gps_nruns + 1))
  done
  gh_public_scan_file "Actions logs" "$EVID/actions-logs.txt" && pass "$gps_nruns Actions run log(s) are clean ($(wc -c < "$EVID/actions-logs.txt" | tr -d ' ') bytes; the GitHub runner's own /home/runner paths excluded)" || gps_bad=1
  gps_hooks=$(gh api "repos/$GH_REPO/hooks" -q 'length' 2>/dev/null)
  note "webhooks configured on the repository (their config is never public): ${gps_hooks:-?}"
  [ "$gps_bad" = 0 ] || return 1
  # a clean pass is only meaningful if the scan can see what it is looking for: prove each class matches a planted value
  gps_probe="$EVID/probe.txt"
  printf 'ghp_%s\n/Users/someone/x\nFOREMAN_API_TOKEN=abc\n"role": "assistant"\n' "$(printf 'a%.0s' $(seq 1 24))" > "$gps_probe"
  gps_ok=1
  for gps_c in $GH_PUBLIC_CLASSES; do eval "gps_re=\$GH_RE_$gps_c"; grep -qE -- "$gps_re" "$gps_probe" || gps_ok=0; done
  [ "$gps_ok" = 1 ] && pass "the scan patterns detect a planted token, local path, FOREMAN_* dump and transcript line (the scan can fail)" || { fail "a scan pattern did not match its planted probe: the scan itself is broken"; return 1; }
  return 0
}

gh_set_visibility() { # <public|private>
  gh repo edit "$GH_REPO" --visibility "$1" --accept-visibility-change-consequences >"$EVID/visibility-$1.out" 2>&1
}
gh_visibility() { gh repo view "$GH_REPO" --json visibility -q .visibility 2>/dev/null; }

gh_unflip() {
  # GH_FLIPPED can be stale (a stage that died keeps its state only up to the last save): ask GitHub what is true
  gu_now=$(gh_visibility)
  [ "$GH_FLIPPED" = 1 ] || [ "$gu_now" = PUBLIC ] || return 0
  gh_set_visibility private
  GH_UNFLIP_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  gu_vis=$(gh_visibility)
  note "unflip at $GH_UNFLIP_AT: gh repo view --json visibility -> $gu_vis"
  if [ "$gu_vis" = PRIVATE ]; then GH_FLIPPED=0; else out "  WARNING     $GH_REPO is still $gu_vis: set it private by hand NOW"; fi
}

# gh_protect <enforce_admins true|false> <required contexts json array>
gh_protect() {
  gh api -X PUT "repos/$GH_REPO/branches/main/protection" --input - >"$EVID/protection-put.out" 2>&1 <<EOF
{"required_status_checks":{"strict":false,"contexts":$2},"enforce_admins":$1,"required_pull_request_reviews":{"required_approving_review_count":1},"restrictions":null,"required_linear_history":true}
EOF
  gp_rc=$?
  [ "$gp_rc" = 0 ] && { GH_PROTECTED=1; state_save 2>/dev/null; }
  return $gp_rc
}
gh_protection_line() {
  gh api "repos/$GH_REPO/branches/main/protection" 2>/dev/null | jq -c '{contexts: .required_status_checks.contexts, strict: .required_status_checks.strict, reviews: .required_pull_request_reviews.required_approving_review_count, linear_history: .required_linear_history.enabled, enforce_admins: .enforce_admins.enabled}'
}

# gh_bot_approve <pr number>: an approving review from github-actions[bot] (a second identity)
gh_bot_approve() {
  gba_before=$(gh run list -R "$GH_REPO" --workflow approve.yml --limit 1 --json databaseId -q '.[0].databaseId // 0' 2>/dev/null)
  gh workflow run approve.yml -R "$GH_REPO" -f pr="$1" >"$EVID/approve-dispatch.out" 2>&1 || return 1
  gba_n=0; gba_id=""
  while [ "$gba_n" -lt 60 ]; do
    gba_id=$(gh run list -R "$GH_REPO" --workflow approve.yml --limit 1 --json databaseId -q '.[0].databaseId // 0' 2>/dev/null)
    [ "${gba_id:-0}" != "${gba_before:-0}" ] && break
    sleep 3; gba_n=$((gba_n + 3))
  done
  [ "${gba_id:-0}" != "${gba_before:-0}" ] || return 1
  gba_n=0
  while [ "$gba_n" -lt 180 ]; do
    [ "$(gh run view "$gba_id" -R "$GH_REPO" --json status -q .status 2>/dev/null)" = completed ] && break
    sleep 4; gba_n=$((gba_n + 4))
  done
  [ "$(gh run view "$gba_id" -R "$GH_REPO" --json conclusion -q .conclusion 2>/dev/null)" = success ]
}
gh_review_decision() { gh pr view "$GH_PR" -R "$GH_REPO" --json reviewDecision -q '.reviewDecision' 2>/dev/null; }
gh_pr_gates_line() { gh pr view "$GH_PR" -R "$GH_REPO" --json state,mergeable,mergeStateStatus,reviewDecision -q '"state=\(.state) mergeable=\(.mergeable) mergeStateStatus=\(.mergeStateStatus) reviewDecision=\(.reviewDecision)"' 2>/dev/null; }
gh_review_is_approved() { [ "$(gh_review_decision)" = APPROVED ]; }

# One operator merge attempt on the current PR (gate already approved): the exact refusal or success.
gh_merge_attempt() { # <label>
  gh_fm "merge-$1" run merge --id "$GH_RUN"
  note "[$1] foreman run merge: rc=$GH_RC"
  printf '%s\n' "$GH_OUT" | while IFS= read -r gm_line; do note "[$1]   | $gm_line"; done
  note "[$1] GitHub: $(gh_pr_gates_line)"
}

# 9j: what the operator sees when GitHub refuses the merge. Branch protection needs a public repository on a
# free plan, but the repository's own merge-method setting works on a private one: Foreman only ever squashes.
gh_x_merge_refusal() {
  say "9j. operator merge refused by GitHub: the repository forbids squash merges (Foreman only squashes)"
  gh_new_pr p4 PRP4 || return 1
  gh_x_ready || return 1
  gh_approve_merge mr-approve
  [ "$GH_RC" = 0 ] && pass "operator approve-merge accepted" || { fail "approve-merge failed: $(printf '%s' "$GH_OUT" | cut -c1-300)"; return 1; }
  mark=$(gh_events_mark "$GH_RUN")
  gh api -X PATCH "repos/$GH_REPO" -F allow_squash_merge=false -F allow_rebase_merge=true >/dev/null 2>&1 && note "repository merge methods: squash DISABLED (rebase allowed)"
  gh_merge_attempt mr-squash-disabled
  assert_eq "refused: the PR is still OPEN" "$(gh pr view "$GH_PR" -R "$GH_REPO" --json state -q .state 2>/dev/null)" "OPEN"
  assert_eq "no PrMerged was recorded" "$(gh_events_count "$GH_RUN" "$mark" PrMerged)" "0"
  assert_eq "the gate is still approved (the operator can retry)" "$(gh_pr_field .merge_gate)" "approved"
  gh api -X PATCH "repos/$GH_REPO" -F allow_squash_merge=true >/dev/null 2>&1 && note "repository merge methods: squash allowed again"
  sleep 3
  gh_merge_attempt mr-final
  assert_eq "merged once squash merges are allowed again (same approval, same head pin)" "$(gh pr view "$GH_PR" -R "$GH_REPO" --json state -q .state 2>/dev/null)" "MERGED"
  gh_events_note "$GH_RUN" "$mark"
  return 0
}

# gh_x_safety: the content scan on its own (read-only), to run it any time before the protection stage
gh_x_safety() { gh_public_safety_check; }

gh_x_prot_prepare() {
  say "9i-1. three PRs prepared while the repository is still private"
  [ "$E2E_GH_ALLOW_PUBLIC" = 1 ] || { note "skipped: the protection stage is not allowed (E2E_GH_ALLOW_PUBLIC != 1)"; return 0; }
  gh_new_pr p1 PRP1 || return 1
  gh_x_ready || return 1
  gh_new_pr p2 PRP2 || return 1
  gh_x_ready || return 1
  gh_new_pr p3 PRP3 || return 1
  gh_x_ready || return 1
  return 0
}

gh_x_protection() {
  say "9i-2. operator merge under GitHub branch protection (the repository is PUBLIC only inside this stage)"
  if [ "$E2E_GH_ALLOW_PUBLIC" != 1 ]; then
    unverified "operator merge under GitHub branch protection" "protection needs the scratch repo public (HTTP 403 on private/free plan); set E2E_GH_ALLOW_PUBLIC=1 to allow the temporary flip"
    return 0
  fi
  for gp_pr in PRP1 PRP2 PRP3; do gh_pr_use "$gp_pr" || return 1; done
  gh_public_safety_check || { fail "the safety scan failed: the repository stays PRIVATE and the protection stage is not run"; return 1; }
  assert_eq "the repository is private before the flip" "$(gh_visibility)" "PRIVATE"

  GH_FLIP_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  gh_set_visibility public
  GH_FLIPPED=1
  state_save 2>/dev/null
  note "flip at $GH_FLIP_AT: gh repo view --json visibility -> $(gh_visibility)"
  assert_eq "the repository is public for the protection test" "$(gh_visibility)" "PUBLIC"

  # --- M1: protection with admins NOT enforced: required checks test + e2e/external-policy, 1 review, linear history
  say "9i-M1. protected main (admins not enforced), CI green, NO review"
  gh_protect false '["test","'"$GH_EXT_CONTEXT"'"]' && pass "protection applied: $(gh_protection_line)" || { fail "applying protection failed: $(cut -c1-300 "$EVID/protection-put.out")"; gh_unwind_protection; return 1; }
  gh_pr_use PRP1
  gh_status_post "$(gh_head)" success "$GH_EXT_CONTEXT"
  gh_pr_use PRP2
  gh_status_post "$(gh_head)" success "$GH_EXT_CONTEXT"
  gh_pr_use PRP1
  note "P1 before any merge attempt: $(gh_pr_gates_line)"
  gh_approve_merge m1-approve
  [ "$GH_RC" = 0 ] && pass "operator approve-merge accepted" || { fail "approve-merge failed: $(printf '%s' "$GH_OUT" | cut -c1-300)"; gh_unwind_protection; return 1; }
  mark=$(gh_events_mark "$GH_RUN")
  gh_merge_attempt m1
  m1_state=$(gh pr view "$GH_PR" -R "$GH_REPO" --json state -q .state 2>/dev/null)
  if [ "$m1_state" = MERGED ]; then
    note "M1 outcome: the merge SUCCEEDED with no review and admins not enforced (the token's admin rights bypassed the review requirement)"
  else
    assert_eq "M1: GitHub refused the merge: the PR is still OPEN" "$m1_state" "OPEN"
    assert_eq "M1: no PrMerged was recorded" "$(gh_events_count "$GH_RUN" "$mark" PrMerged)" "0"
  fi
  gh_events_note "$GH_RUN" "$mark"

  # --- M2: admins enforced
  say "9i-M2. protected main (admins ENFORCED): refusal without a review, then success after the bot's approval"
  gh api -X POST "repos/$GH_REPO/branches/main/protection/enforce_admins" >/dev/null 2>&1 && note "protection now: $(gh_protection_line)"
  if [ "$m1_state" = MERGED ]; then gh_pr_use PRP2; gh_approve_merge m2-approve; fi
  note "M2 PR ${GH_PR}: $(gh_pr_gates_line)"
  gh_merge_attempt m2-noreview
  assert_eq "M2: refused without a review: the PR is still OPEN" "$(gh pr view "$GH_PR" -R "$GH_REPO" --json state -q .state 2>/dev/null)" "OPEN"
  if gh_bot_approve "$GH_PR"; then pass "github-actions[bot] approved PR $GH_PR (workflow dispatch)"; else fail "the approve workflow did not complete successfully: $(cut -c1-200 "$EVID/approve-dispatch.out")"; fi
  gh_wait 120 "review decision" gh_review_is_approved && pass "GitHub reports reviewDecision APPROVED (the bot's review counts)" || note "reviewDecision after the bot approval: $(gh_review_decision)"
  gh_merge_attempt m2-approved
  gm2_state=$(gh pr view "$GH_PR" -R "$GH_REPO" --json state -q .state 2>/dev/null)
  assert_eq "M2: merged once protected, green, reviewed and gate-approved" "$gm2_state" "MERGED"
  if [ "$gm2_state" = MERGED ]; then
    git -C "$GH_OP" fetch -q origin
    gm2_parents=$(git -C "$GH_OP" rev-list --parents -n 1 origin/main | awk '{print NF - 1}')
    assert_eq "the commit that landed on main has exactly one parent (linear history, squash)" "$gm2_parents" "1"
    assert_eq "no merge commit exists on main" "$(git -C "$GH_OP" rev-list --merges origin/main | wc -l | tr -d ' ')" "0"
    gh_wait_card "$GH_THREAD" '.group == "resolved"' 300 && pass "Overview: the thread is Resolved ($(gh_card_line "$GH_CARD"))" || fail "thread not Resolved after the protected merge: $(gh_card_line "$GH_CARD")"
  fi

  # --- M3: required status check (external) absent / failing / success, then a merge method the repo forbids
  say "9i-M3. protected main: a REQUIRED status check that is absent, failing, then green"
  gh_pr_use PRP3
  gh_bot_approve "$GH_PR" && pass "github-actions[bot] approved PR $GH_PR" || fail "the approve workflow failed for PR $GH_PR"
  gh_wait 120 "review decision" gh_review_is_approved || true
  note "M3 PR ${GH_PR}: $(gh_pr_gates_line)"
  gh_approve_merge m3-approve
  [ "$GH_RC" = 0 ] && pass "operator approve-merge accepted" || fail "approve-merge failed: $(printf '%s' "$GH_OUT" | cut -c1-300)"
  gh_merge_attempt m3-status-absent
  assert_eq "M3: refused while the required status '$GH_EXT_CONTEXT' is absent" "$(gh pr view "$GH_PR" -R "$GH_REPO" --json state -q .state 2>/dev/null)" "OPEN"
  gh_status_post "$(gh_head)" failure "$GH_EXT_CONTEXT"
  sleep 5
  gh_merge_attempt m3-status-failing
  assert_eq "M3: refused while the required status '$GH_EXT_CONTEXT' is failing" "$(gh pr view "$GH_PR" -R "$GH_REPO" --json state -q .state 2>/dev/null)" "OPEN"
  gh_status_post "$(gh_head)" success "$GH_EXT_CONTEXT"
  sleep 5
  gh api -X PATCH "repos/$GH_REPO" -F allow_squash_merge=false -F allow_rebase_merge=true >/dev/null 2>&1 && note "repository merge methods: squash DISABLED (rebase allowed); Foreman only ever squashes"
  gh_merge_attempt m3-squash-disabled
  assert_eq "M3: refused while the repository forbids squash merges" "$(gh pr view "$GH_PR" -R "$GH_REPO" --json state -q .state 2>/dev/null)" "OPEN"
  gh api -X PATCH "repos/$GH_REPO" -F allow_squash_merge=true >/dev/null 2>&1
  sleep 3
  gh_merge_attempt m3-final
  assert_eq "M3: merged once every protection rule is satisfied" "$(gh pr view "$GH_PR" -R "$GH_REPO" --json state -q .state 2>/dev/null)" "MERGED"

  gh_unwind_protection
  return 0
}

# gh_unwind_protection: protection off, merge methods restored, repository private again
gh_unwind_protection() {
  # unconditional: the recorded flag can be stale, and deleting protection that does not exist is a harmless 404
  gh api -X DELETE "repos/$GH_REPO/branches/main/protection" >/dev/null 2>&1 && GH_PROTECTED=0 && note "branch protection removed from main"
  gh api -X PATCH "repos/$GH_REPO" -F allow_squash_merge=true -F allow_merge_commit=true -F allow_rebase_merge=true >/dev/null 2>&1
  gh_unflip
  if [ -n "$GH_FLIP_AT" ]; then
    assert_eq "the repository is PRIVATE again (gh repo view --json visibility; public from $GH_FLIP_AT to $GH_UNFLIP_AT)" "$(gh_visibility)" "PRIVATE"
  fi
}

# called by github_cleanup (github.sh) before the scratch repository's main is restored
github_extras_unwind() {
  gh_unwind_protection 2>/dev/null
  if [ -n "${GH_OP:-}" ] && [ -n "${GH_REPO:-}" ]; then
    for gu_ref in $(gh api "repos/$GH_REPO/git/matching-refs/heads/foreman" -q '.[].ref' 2>/dev/null); do
      gh api -X DELETE "repos/$GH_REPO/git/$gu_ref" >/dev/null 2>&1
    done
    git -C "$GH_OP" push -q origin --delete conflict-main 2>/dev/null
  fi
}
