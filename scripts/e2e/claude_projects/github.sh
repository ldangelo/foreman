#!/usr/bin/env bash
# GitHub stage of scripts/e2e/claude_projects_flow.sh. Sourced after lib.sh, never executed.
#
# Real GitHub, guarded by FOREMAN_E2E_GITHUB_REPO=<owner>/foreman-scratch-<suffix>: an EXISTING,
# PRIVATE, NON-ARCHIVED scratch repository that was seeded from
# scripts/e2e/claude_projects/github-fixture/ (tiny app, unit tests, .github/workflows/ci.yml
# running `python3 -m unittest`). The harness never creates or deletes a repository. Unset, the
# stage prints an explicit SKIP and counts as UNVERIFIED (never as a pass).
#
# What it drives, through Foreman only (real server, real `gh`, real pi agent):
#   PR created by a run (AutoPR) -> check watching (PrMonitor + webhooks) -> a real webhook through
#   a cloudflared quick tunnel with signature verification -> a deterministic CI failure injected
#   by a git push -> the thread in 'Waiting on you' (ci_failing) -> Fix CI (run.pr.fix_ci) ->
#   a review comment posted with `gh api` -> Address comments -> a conflicting commit pushed to
#   main -> Resolve conflicts -> a force-push of the PR branch -> a check re-run -> 'Ready for
#   review' -> operator approve-merge + merge (the merge gate is never an agent path).
#
# Environment: FOREMAN_E2E_GITHUB_REPO (required to enable), E2E_GH_STAGE_TIMEOUT (s per wait,
# default 900), E2E_GH_ONLY=1 (skip the local steps; run only setup + this stage),
# E2E_GH_TUNNEL=0 (skip the cloudflared webhook part: UNVERIFIED).

E2E_GH_STAGE_TIMEOUT=${E2E_GH_STAGE_TIMEOUT:-900}
E2E_GH_TUNNEL=${E2E_GH_TUNNEL:-1}
GH_REPO=${FOREMAN_E2E_GITHUB_REPO:-}
GH_CLONE=""   # the project checkout Foreman owns: never touched by the harness
GH_OP=""      # the operator/injector clone: all harness git work happens here
GH_PROJECT=""
GH_HOOK_ID=""
GH_BASE_SHA=""
GH_HOOK_SECRET=""
TUNNEL_PID=""
TUNNEL_URL=""

github_enabled() { [ -n "$GH_REPO" ]; }

# github_prepare: validates the repository and exports what the SERVER needs (it runs with a
# redirected HOME, so credentials travel in the environment, never in a config file).
github_prepare() {
  github_enabled || return 0
  command -v gh >/dev/null 2>&1 || die "FOREMAN_E2E_GITHUB_REPO is set but 'gh' is not installed" 1
  case "$GH_REPO" in
    */foreman-scratch-*) ;;
    *) die "FOREMAN_E2E_GITHUB_REPO must look like <owner>/foreman-scratch-<suffix>; refusing '$GH_REPO'" 1 ;;
  esac
  gp=$(gh repo view "$GH_REPO" --json isPrivate,isArchived -q '(.isPrivate|tostring) + "/" + (.isArchived|tostring)' 2>/dev/null) \
    || die "cannot read $GH_REPO with gh" 1
  [ "$gp" = "true/false" ] || die "$GH_REPO must be private and not archived (isPrivate/isArchived = $gp)" 1
  GH_TOKEN=$(gh auth token) || die "gh auth token failed" 1
  export GH_TOKEN
  # The system gitconfig may name the macOS keychain helper, whose `store` hangs under the
  # server's redirected HOME. An empty helper resets that list; then only `gh` answers.
  export GIT_CONFIG_COUNT=2
  export GIT_CONFIG_KEY_0="credential.helper"
  export GIT_CONFIG_VALUE_0=""
  export GIT_CONFIG_KEY_1="credential.https://github.com.helper"
  export GIT_CONFIG_VALUE_1='!gh auth git-credential'
  GH_HOOK_SECRET="e2e-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
  export FOREMAN_GITHUB_WEBHOOK_SECRET="$GH_HOOK_SECRET"
  export FOREMAN_PR_MONITOR_ENABLED=true
  export FOREMAN_PR_FIX_SANDBOX=host
}

github_cleanup() {
  if [ -n "$GH_OP" ]; then gh_restore_repo; fi
  if [ -n "$GH_HOOK_ID" ] && [ -n "$GH_REPO" ]; then
    gh api -X DELETE "repos/$GH_REPO/hooks/$GH_HOOK_ID" >/dev/null 2>&1
  fi
  if [ -n "$TUNNEL_PID" ]; then stop_pid "$TUNNEL_PID"; fi
}

# ---------------------------------------------------------------- helpers

gh_card() { # <thread id> -> the thread's Overview card (JSON), including resolved
  api_get "/api/projects/$PROJECT/overview?include_resolved=true" \
    | jq -c --arg t "$1" '[.groups[]?[]? | select(.thread_id == $t)][0] // empty' 2>/dev/null
}

# gh_server_alive: a dead server turns every later wait into a long timeout; fail fast and say why
gh_server_alive() {
  if kill -0 "$SERVER_PID" 2>/dev/null; then return 0; fi
  if [ -z "${GH_SERVER_DEAD_NOTED:-}" ]; then
    GH_SERVER_DEAD_NOTED=1
    fail "the Foreman server (pid $SERVER_PID) died during the GitHub stage: $(grep -E 'SIGTERM|\*\* \(' "$SERVER_LOG" | tail -n 2 | tr '\n' ' ' | cut -c1-200)"
  fi
  return 1
}

# gh_wait_card <thread> <jq boolean over the card> <timeout> -> GH_CARD
gh_wait_card() {
  gw_start=$(date +%s); GH_CARD=""
  while :; do
    GH_CARD=$(gh_card "$1")
    if [ -n "$GH_CARD" ] && [ "$(printf '%s' "$GH_CARD" | jq -r "$2" 2>/dev/null)" = true ]; then
      note "Overview snapshot: counts=$(overview_counts) card=$(printf '%s' "$GH_CARD" | jq -c '{thread_id, group, reason, pr_state, merge_gate, pr_url}')"
      return 0
    fi
    [ "$(elapsed "$gw_start")" -lt "$3" ] || return 1
    gh_server_alive || return 1
    sleep "$E2E_POLL_SECS"
  done
}

gh_card_line() { printf '%s' "$1" | jq -c '{group, reason, pr_state, merge_gate, status}' 2>/dev/null; }

gh_head() { gh pr view "$GH_PR" -R "$GH_REPO" --json headRefOid -q .headRefOid 2>/dev/null; }

# gh_wait <timeout> <description> <command...>: poll a shell predicate
gh_wait() {
  gp_t=$1; shift 2
  gp_start=$(date +%s)
  while :; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    [ "$(elapsed "$gp_start")" -lt "$gp_t" ] || return 1
    gh_server_alive || return 1
    sleep 5
  done
}

# gh_ci <sha> -> conclusion of the `test` job's check run for that commit (empty while running)
gh_ci_conclusion() {
  gh api "repos/$GH_REPO/commits/$1/check-runs" -q '[.check_runs[] | select(.name == "test")][0] | .conclusion // empty' 2>/dev/null
}

gh_ci_is() { [ "$(gh_ci_conclusion "$(gh_head)")" = "$1" ]; }

gh_clone_sync() { # fetch everything and put the clone on the PR branch at origin's head
  git -C "$GH_OP" fetch -q origin || return 1
  git -C "$GH_OP" checkout -q -B "$GH_BRANCH" "origin/$GH_BRANCH"
}

gh_push_as_operator() { git -C "$GH_OP" -c user.name=operator -c user.email=operator@example.com "$@"; }

# ---------------------------------------------------------------- stages

gh_stage_setup() {
  say "8a. GitHub: project over a clone of $GH_REPO"
  GH_CLONE="$WORK/gh-clone"
  git clone -q "https://github.com/$GH_REPO.git" "$GH_CLONE" || die "clone of $GH_REPO failed" 2
  GH_OP="$WORK/gh-operator-clone"
  git clone -q "https://github.com/$GH_REPO.git" "$GH_OP" || die "operator clone of $GH_REPO failed" 2
  git -C "$GH_CLONE" config user.name "foreman-e2e"
  git -C "$GH_CLONE" config user.email "foreman-e2e@example.com"
  git -C "$GH_CLONE" config commit.gpgsign false
  (cd "$GH_CLONE" && br init --prefix gh >/dev/null 2>&1) || die "br init failed in $GH_CLONE" 2
  printf '.beads/\n' >> "$GH_CLONE/.git/info/exclude"
  GH_BASE_SHA=$(git -C "$GH_OP" rev-parse origin/main)
  open_prs=$(gh pr list -R "$GH_REPO" --state open --json number -q length 2>/dev/null)
  [ "${open_prs:-0}" = 0 ] || die "$GH_REPO has $open_prs open PR(s): the stage needs a clean scratch repo" 1
  GH_PROJECT="e2e-gh-$SUFFIX"
  SAVE_PROJECT=$PROJECT; SAVE_REPO=$REPO
  PROJECT=$GH_PROJECT; REPO=$GH_CLONE
  fm project create --id "$PROJECT" --path "$REPO" --task-provider beads \
    --task-provider-database-path "$REPO/.beads/beads.db" >"$WORK/gh-project-create.out" 2>&1 \
    && pass "project $PROJECT registered over the clone of $GH_REPO" \
    || { fail "project create: $(cut -c1-300 "$WORK/gh-project-create.out")"; return 1; }
  fm project update --thread-model "$E2E_MODEL" --coordinator-provider pi --coordinator-model "$E2E_MODEL" \
    --max-concurrent-runs 2 "$PROJECT" >/dev/null 2>&1
  return 0
}

gh_stage_pr_create() {
  say "8b. GitHub: a run opens a real PR"
  new_bead "gh-$SUFFIX subtract" "In app.py add a function subtract(a, b) that returns a - b, and add a test named test_subtract to test_app.py that checks subtract(5, 3) == 2. Keep the existing tests passing."
  thread_for_bead "$BEAD_ID" 240
  if [ -z "$THREAD" ]; then fail "no thread appeared for bead $BEAD_ID"; return 1; fi
  GH_THREAD=$THREAD; GH_RUN=${THREAD#run:}
  note "thread $GH_THREAD from bead $BEAD_ID"
  if ! wait_thread "$GH_THREAD" "completed|ready_for_review|failed" "$E2E_RUN_TIMEOUT"; then
    fail "thread $GH_THREAD never finished (status $THREAD_STATUS)"; return 1
  fi
  assert_eq "run finished" "$THREAD_STATUS" "completed"
  gh_wait_card "$GH_THREAD" '.pr_url != null' 180 || true
  GH_PR_URL=$(printf '%s' "$GH_CARD" | jq -r '.pr_url // empty')
  GH_BRANCH=$(printf '%s' "$GH_CARD" | jq -r '.branch // empty')
  case "$GH_PR_URL" in "https://github.com/$GH_REPO/pull/"*) pass "the run opened a PR: $GH_PR_URL" ;; *) fail "no PR url on the card: '$GH_PR_URL' ($(gh_card_line "$GH_CARD"))"; return 1 ;; esac
  GH_PR=${GH_PR_URL##*/}
  assert_eq "GitHub reports the PR open" "$(gh pr view "$GH_PR" -R "$GH_REPO" --json state -q .state 2>/dev/null)" "OPEN"
  assert_eq "PR head is the run's branch" "$(gh pr view "$GH_PR" -R "$GH_REPO" --json headRefName -q .headRefName 2>/dev/null)" "$GH_BRANCH"
  assert_eq "PR base is main" "$(gh pr view "$GH_PR" -R "$GH_REPO" --json baseRefName -q .baseRefName 2>/dev/null)" "main"
  assert_has "the PR diff contains the run's change" "$(gh pr diff "$GH_PR" -R "$GH_REPO" 2>/dev/null)" "subtract"
  note "card: $(gh_card_line "$GH_CARD")"
  return 0
}

gh_stage_ci_green() {
  say "8c. GitHub: Foreman watches the real checks (green)"
  if gh_wait 300 "ci success" gh_ci_is success; then
    pass "GitHub Actions reports the PR head green: $(gh_head)"
  else
    fail "CI never went green on $(gh_head) (conclusion '$(gh_ci_conclusion "$(gh_head)")')"; return 1
  fi
  if gh_wait_card "$GH_THREAD" '.group == "ready_for_review"' 420; then
    pass "Overview: thread is Ready for review once checks pass ($(gh_card_line "$GH_CARD"))"
  else
    fail "thread never reached Ready for review with green checks: $(gh_card_line "$GH_CARD")"
  fi
  prs=$(api_get "/api/runs/$GH_RUN/prs")
  note "GET /api/runs/$GH_RUN/prs: $(printf '%s' "$prs" | jq -c . | cut -c1-600)"
  assert_has "the run's PR association carries the real PR url" "$prs" "$GH_PR_URL"
  return 0
}

# gh_tunnel: cloudflared quick tunnel to the server, then webhook registration + assertions
gh_stage_webhook() {
  say "8d. GitHub: a REAL webhook through a cloudflared tunnel"
  if [ "$E2E_GH_TUNNEL" != 1 ] || ! command -v cloudflared >/dev/null 2>&1; then
    unverified "real GitHub webhook deliveries" "cloudflared missing or E2E_GH_TUNNEL=0"; return 0
  fi
  cloudflared tunnel --no-autoupdate --url "http://127.0.0.1:$E2E_PORT" >"$WORK/cloudflared.log" 2>&1 &
  TUNNEL_PID=$!
  tw=0
  while [ "$tw" -lt 90 ]; do
    TUNNEL_URL=$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$WORK/cloudflared.log" | head -n 1)
    [ -n "$TUNNEL_URL" ] && break
    sleep 2; tw=$((tw + 2))
  done
  if [ -z "$TUNNEL_URL" ]; then fail "cloudflared did not print a tunnel url (see $WORK/cloudflared.log)"; return 0; fi
  note "tunnel $TUNNEL_URL -> 127.0.0.1:$E2E_PORT (pid $TUNNEL_PID)"
  # Wait until the edge routes to the server: an unsigned POST must reach Foreman and be refused 401.
  tw=0; code=""
  while [ "$tw" -lt 120 ]; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d '{}' --max-time 10 "$TUNNEL_URL/webhooks/github" 2>/dev/null)
    [ "$code" = 401 ] && break
    sleep 3; tw=$((tw + 3))
  done
  assert_eq "unsigned delivery through the tunnel is rejected" "$code" "401"

  body='{"zen":"e2e forged ping"}'
  bad=$(curl -s -w ' %{http_code}' -X POST -H 'content-type: application/json' -H 'x-hub-signature-256: sha256=0000000000000000000000000000000000000000000000000000000000000000' -d "$body" --max-time 20 "$TUNNEL_URL/webhooks/github")
  assert_has "a wrong signature is rejected as signature_mismatch (401)" "$bad" "signature_mismatch"
  assert_has "...with HTTP 401" "$bad" " 401"
  mal=$(curl -s -w ' %{http_code}' -X POST -H 'content-type: application/json' -H 'x-hub-signature-256: md5=abc' -d "$body" --max-time 20 "$TUNNEL_URL/webhooks/github")
  assert_has "a malformed signature header is rejected (401 signature_malformed)" "$mal" "signature_malformed"
  sig="sha256=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$GH_HOOK_SECRET" -hex | sed 's/^.* //')"
  good=$(curl -s -w ' %{http_code}' -X POST -H 'content-type: application/json' -H "x-hub-signature-256: $sig" -d "$body" --max-time 20 "$TUNNEL_URL/webhooks/github")
  assert_has "a correctly signed delivery is accepted (202 ignored: not a PR event)" "$good" " 202"
  note "good delivery body: $good"

  GH_HOOK_ID=$(gh api -X POST "repos/$GH_REPO/hooks" \
    -f name=web -F active=true \
    -f "config[url]=$TUNNEL_URL/webhooks/github" -f "config[content_type]=json" -f "config[secret]=$GH_HOOK_SECRET" -f "config[insecure_ssl]=0" \
    -f 'events[]=check_run' -f 'events[]=check_suite' -f 'events[]=pull_request' -f 'events[]=pull_request_review' \
    -f 'events[]=pull_request_review_comment' -f 'events[]=pull_request_review_thread' -f 'events[]=issue_comment' \
    -q .id 2>"$WORK/hook-create.err")
  if [ -z "$GH_HOOK_ID" ]; then fail "webhook registration failed: $(cut -c1-300 "$WORK/hook-create.err")"; return 0; fi
  pass "webhook $GH_HOOK_ID registered on $GH_REPO -> $TUNNEL_URL/webhooks/github"
  gh api -X POST "repos/$GH_REPO/hooks/$GH_HOOK_ID/pings" >/dev/null 2>&1
  if gh_wait 90 "ping delivery" gh_hook_delivered ping; then
    pass "GitHub's ping delivery was answered $(gh_hook_status ping) (signature verified by Foreman)"
  else
    fail "no 2xx ping delivery recorded by GitHub: $(gh_hook_status ping)"
  fi
  return 0
}

gh_hook_status() { # <event> -> status codes of that event's deliveries
  gh api "repos/$GH_REPO/hooks/$GH_HOOK_ID/deliveries" -q "[.[] | select(.event == \"$1\") | .status_code] | join(\",\")" 2>/dev/null
}
gh_hook_delivered() { case ",$(gh_hook_status "$1")," in *,202,*) return 0 ;; *) return 1 ;; esac; }

gh_stage_ci_fail_fix() {
  say "8e. GitHub: a FAILING check -> Waiting on you -> Fix CI"
  gh_clone_sync || { fail "cannot sync the clone to $GH_BRANCH"; return 1; }
  printf '\n\nclass InjectedFailure(unittest.TestCase):\n    def test_injected_failure(self):\n        self.assertEqual(1, 2, "injected by the e2e harness")\n' >> "$GH_OP/test_app.py"
  gh_push_as_operator commit -q -am "ci: inject a failing test (e2e)" && gh_push_as_operator push -q origin "$GH_BRANCH" \
    || { fail "could not push the failing commit"; return 1; }
  BROKEN=$(git -C "$GH_OP" rev-parse HEAD)
  note "injected failing commit $BROKEN (deterministic injector: a git push of a failing test, not an agent mistake)"
  if gh_wait 300 "ci failure" gh_ci_is failure; then
    pass "GitHub Actions reports the check FAILED on $BROKEN"
  else
    fail "the injected failure never showed as failed (conclusion '$(gh_ci_conclusion "$BROKEN")')"; return 1
  fi
  if gh_wait_card "$GH_THREAD" '.group == "waiting_on_you"' 420; then
    pass "Overview: the thread is in Waiting on you: $(gh_card_line "$GH_CARD")"
    assert_eq "...for reason ci_failing" "$(printf '%s' "$GH_CARD" | jq -r .reason)" "ci_failing"
    assert_has "...and Fix CI is offered by the PR actions" "$(api_get "/api/runs/$GH_RUN/prs" | jq -c .)" "failing"
  else
    fail "thread never moved to Waiting on you after the failing check: $(gh_card_line "$GH_CARD")"
  fi
  fm run fix-ci "$GH_RUN" --pr "$GH_PR_URL" >"$WORK/fix-ci.out" 2>&1 && pass "run.pr.fix_ci accepted: $(tr '\n' ' ' < "$WORK/fix-ci.out" | cut -c1-200)" || { fail "run.pr.fix_ci: $(cut -c1-300 "$WORK/fix-ci.out")"; return 1; }
  if gh_wait 900 "fix commit" gh_head_moved_from "$BROKEN"; then
    pass "a fix commit landed on the PR branch: $(gh_head)"
  else
    fail "no fix commit appeared on $GH_BRANCH within 900s"; tail -n 15 "$SERVER_LOG" | cut -c1-240 | while IFS= read -r l; do note "$l"; done; return 1
  fi
  if gh_wait 300 "ci green after fix" gh_ci_is success; then
    pass "CI is green again on the fixed head"
  else
    fail "CI not green after the fix (conclusion '$(gh_ci_conclusion "$(gh_head)")')"
  fi
  if gh_wait_card "$GH_THREAD" '.group == "ready_for_review"' 420; then
    pass "Overview: back in Ready for review after the fix: $(gh_card_line "$GH_CARD")"
  else
    fail "thread did not return to Ready for review: $(gh_card_line "$GH_CARD")"
  fi
  return 0
}

gh_head_moved_from() { [ "$(gh_head)" != "$1" ]; }
gh_head_is() { [ "$(gh_head)" = "$1" ]; }
gh_run_attempt_is() { [ "$(gh run view "$1" -R "$GH_REPO" --json attempt -q .attempt 2>/dev/null)" = "$2" ]; }

gh_stage_review() {
  say "8f. GitHub: a review-thread comment -> Address comments"
  gh_clone_sync || { fail "cannot sync clone"; return 1; }
  before=$(gh_head)
  line=$(grep -n 'def subtract' "$GH_OP/app.py" | head -n 1 | cut -d: -f1)
  [ -n "$line" ] || line=1
  payload=$(jq -n --arg sha "$before" --argjson line "$line" '{commit_id: $sha, event: "COMMENT", body: "Review by the e2e harness.", comments: [{path: "app.py", line: $line, side: "RIGHT", body: "Please add a one-line docstring to subtract() saying it returns a minus b."}]}')
  printf '%s' "$payload" | gh api -X POST "repos/$GH_REPO/pulls/$GH_PR/reviews" --input - >"$WORK/review-post.out" 2>&1 \
    && pass "review comment posted on app.py:$line via gh api" || { fail "posting the review failed: $(cut -c1-300 "$WORK/review-post.out")"; return 1; }
  threads=$(gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:20){nodes{isResolved}}}}}' -f o="${GH_REPO%%/*}" -f r="${GH_REPO##*/}" -F n="$GH_PR" -q '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved|not)] | length' 2>/dev/null)
  assert_eq "GitHub shows one unresolved review thread" "$threads" "1"
  sleep 45
  note "card after the review comment (Foreman observation): $(gh_card_line "$(gh_card "$GH_THREAD")")"
  note "run prs: $(api_get "/api/runs/$GH_RUN/prs" | jq -c . | cut -c1-500)"
  fm run address-comments "$GH_RUN" --pr "$GH_PR_URL" >"$WORK/address.out" 2>&1 && pass "run.pr.address_comments accepted" || { fail "run.pr.address_comments: $(cut -c1-300 "$WORK/address.out")"; return 1; }
  if gh_wait 900 "address commit" gh_head_moved_from "$before"; then
    pass "the agent pushed a commit addressing the comment: $(gh_head)"
    gh_clone_sync
    assert_has "app.py now documents subtract()" "$(sed -n '/def subtract/,/^$/p' "$GH_OP/app.py")" '"""'
  else
    fail "no commit addressing the review comment within 900s"; return 1
  fi
  gh_wait 300 "ci green" gh_ci_is success && pass "CI green after addressing comments" || fail "CI not green after addressing comments"
  return 0
}

gh_stage_conflict() {
  say "8g. GitHub: merge conflict -> Resolve conflicts"
  gh_clone_sync || { fail "cannot sync clone"; return 1; }
  before=$(gh_head)
  git -C "$GH_OP" checkout -q -B conflict-main origin/main
  conflicted=0
  # Deterministic injector: edit main at exactly the place the PR's first app.py hunk edits
  # (an insertion at the same point, or a rewrite of the same line), then let `git merge-tree`
  # prove the result conflicts with the PR head before anything is pushed.
  hunk=$(git -C "$GH_OP" diff -U0 origin/main "origin/$GH_BRANCH" -- app.py | grep -m1 '^@@' | sed -E 's/^@@ -([0-9]+)(,([0-9]+))? .*/\1 \3/')
  hs=${hunk% *}; hc=${hunk#* }; [ "$hc" = "$hunk" ] && hc=1
  git -C "$GH_OP" checkout -q -B conflict-main origin/main
  if [ "${hc:-1}" = 0 ]; then
    sed -i.bak "${hs}a\\
# main inserted this line at the same place as the PR (e2e conflict injector)" "$GH_OP/app.py"
  else
    sed -i.bak "${hs}s/\$/  # main rewrote this line (e2e conflict injector)/" "$GH_OP/app.py"
  fi
  rm -f "$GH_OP/app.py.bak"
  gh_push_as_operator commit -q -am "conflicting change on main (e2e injector at base line $hs)" && \
    ! git -C "$GH_OP" merge-tree --write-tree conflict-main "origin/$GH_BRANCH" >/dev/null 2>&1 && conflicted=1
  [ "$conflicted" = 1 ] || { fail "could not construct a conflicting commit against the PR head"; return 1; }
  gh_push_as_operator push -q origin conflict-main:main && pass "pushed a conflicting commit to main of $GH_REPO (merge-tree proves it conflicts with the PR)" || { fail "push to main failed"; return 1; }
  gh_wait 120 "github conflict" gh_pr_conflicting && pass "GitHub reports the PR as CONFLICTING" || fail "GitHub never reported CONFLICTING (mergeable=$(gh pr view "$GH_PR" -R "$GH_REPO" --json mergeable -q .mergeable))"
  if gh_wait_card "$GH_THREAD" '.reason == "conflict"' 420; then
    pass "Overview: Waiting on you for reason conflict: $(gh_card_line "$GH_CARD")"
  else
    fail "Foreman never showed the conflict: $(gh_card_line "$GH_CARD")"
  fi
  fm run resolve-conflicts "$GH_RUN" --pr "$GH_PR_URL" >"$WORK/resolve.out" 2>&1 && pass "run.pr.resolve_conflicts accepted" || { fail "run.pr.resolve_conflicts: $(cut -c1-300 "$WORK/resolve.out")"; return 1; }
  if gh_wait 900 "mergeable again" gh_pr_mergeable; then
    pass "the agent resolved the conflict: GitHub reports the PR MERGEABLE (head $(gh_head))"
  else
    fail "PR still not mergeable after 900s (mergeable=$(gh pr view "$GH_PR" -R "$GH_REPO" --json mergeable -q .mergeable))"; return 1
  fi
  gh_wait 300 "ci green" gh_ci_is success && pass "CI green on the conflict-resolved head" || fail "CI not green after resolving conflicts"
  return 0
}

gh_pr_conflicting() { [ "$(gh pr view "$GH_PR" -R "$GH_REPO" --json mergeable -q .mergeable 2>/dev/null)" = CONFLICTING ]; }
gh_pr_mergeable() { [ "$(gh pr view "$GH_PR" -R "$GH_REPO" --json mergeable -q .mergeable 2>/dev/null)" = MERGEABLE ]; }

gh_stage_force_push_rerun() {
  say "8h. GitHub: force-push of the PR branch and a check re-run"
  gh_clone_sync || { fail "cannot sync clone"; return 1; }
  before=$(gh_head)
  gh_push_as_operator commit -q --amend -m "$(git -C "$GH_OP" log -1 --format=%s) (force-pushed by e2e)" \
    && gh_push_as_operator push -q --force-with-lease origin "$GH_BRANCH" || { fail "force-push failed"; return 1; }
  after=$(git -C "$GH_OP" rev-parse HEAD)
  [ "$after" != "$before" ] && pass "force-pushed the PR branch: $before -> $after" || fail "force-push did not change the head"
  gh_wait 120 "pr head updated" gh_head_is "$after" || true
  # Foreman must track the NEW head (observation reads the head sha) and keep the PR consistent.
  fw=0; seen=""
  while [ "$fw" -lt 300 ]; do
    seen=$(api_get "/api/runs/$GH_RUN/prs" | jq -r '.. | .head_sha? // empty' 2>/dev/null | sort -u | tr '\n' ' ')
    case "$seen" in *"$after"*) break ;; esac
    sleep 10; fw=$((fw + 10))
  done
  case "$seen" in *"$after"*) pass "Foreman's PR observation tracks the force-pushed head $after" ;; *) fail "Foreman never recorded the new head (saw: ${seen:-none})"; note "run prs: $(api_get "/api/runs/$GH_RUN/prs" | jq -c . | cut -c1-500)" ;; esac
  gh_wait 300 "ci green after force-push" gh_ci_is success && pass "CI ran and passed on the force-pushed head" || fail "CI not green on the force-pushed head"
  # Re-run the latest check.
  rid=$(gh run list -R "$GH_REPO" --branch "$GH_BRANCH" --limit 1 --json databaseId -q '.[0].databaseId')
  gh run rerun "$rid" -R "$GH_REPO" >"$WORK/rerun.out" 2>&1 && pass "re-run of check run $rid requested" || { fail "gh run rerun: $(cut -c1-200 "$WORK/rerun.out")"; return 0; }
  gh_wait 90 "attempt 2" gh_run_attempt_is "$rid" 2 && pass "GitHub started attempt 2 of run $rid"
  gh_wait 300 "rerun green" gh_ci_is success && pass "the re-run finished green" || fail "the re-run did not finish green"
  return 0
}

gh_stage_ready_and_merge() {
  say "8i. GitHub: Ready for review, then the OPERATOR merge path"
  if gh_wait_card "$GH_THREAD" '.group == "ready_for_review" and .merge_gate == "pending"' 420; then
    pass "Overview: Ready for review: $(gh_card_line "$GH_CARD")"
  else
    fail "thread not Ready for review before merge: $(gh_card_line "$GH_CARD")"
  fi
  assert_not_has "the card offers no merge action (the gate is operator-only CLI/HTTP)" "$(printf '%s' "$GH_CARD" | jq -c '.actions // []')" "merge"
  # The approval names the exact head the operator reviewed; the server checks it against GitHub.
  gh_head=$(gh pr view "$GH_PR" -R "$GH_REPO" --json headRefOid -q .headRefOid 2>/dev/null)
  [ -n "$gh_head" ] || { fail "could not read the head sha of PR $GH_PR from GitHub"; return 1; }
  fm run approve-merge --id "$GH_RUN" --approver "e2e-operator" --identity "github:${GH_REPO%%/*}" --head-sha "$gh_head" >"$WORK/approve.out" 2>&1 \
    && pass "operator approve-merge accepted (head $gh_head): $(tr '\n' ' ' < "$WORK/approve.out" | cut -c1-160)" || { fail "approve-merge: $(cut -c1-300 "$WORK/approve.out")"; return 1; }
  fm run merge --id "$GH_RUN" >"$WORK/merge.out" 2>&1 \
    && pass "operator run merge accepted: $(tr '\n' ' ' < "$WORK/merge.out" | cut -c1-160)" || { fail "run merge: $(cut -c1-300 "$WORK/merge.out")"; return 1; }
  assert_eq "GitHub reports the PR MERGED" "$(gh pr view "$GH_PR" -R "$GH_REPO" --json state -q .state 2>/dev/null)" "MERGED"
  if gh_wait_card "$GH_THREAD" '.group == "resolved"' 300; then
    pass "Overview: the thread is Resolved ($(gh_card_line "$GH_CARD"))"
  else
    fail "thread not Resolved after the merge: $(gh_card_line "$GH_CARD")"
  fi
  return 0
}

gh_stage_webhook_summary() {
  [ -n "$GH_HOOK_ID" ] || return 0
  say "8j. GitHub: webhook delivery handling over the whole stage"
  d=$(gh api "repos/$GH_REPO/hooks/$GH_HOOK_ID/deliveries?per_page=100" -q '[.[] | {event, status_code}] | group_by(.event + "/" + (.status_code|tostring)) | map({k: (.[0].event + " -> " + (.[0].status_code|tostring)), n: length}) | map("\(.k) x\(.n)") | join("; ")' 2>/dev/null)
  note "GitHub's delivery log: $d"
  assert_has "GitHub delivered check_run events that Foreman answered 202" "$d" "check_run -> 202"
  non2xx=$(gh api "repos/$GH_REPO/hooks/$GH_HOOK_ID/deliveries?per_page=100" -q '[.[] | select(.status_code >= 300)] | length' 2>/dev/null)
  assert_eq "no delivery was refused or failed (a 401/5xx would mean a signature or handling problem)" "$non2xx" "0"
  assert_not_has "no server-side handling crash is logged for webhook deliveries" "$(grep -E 'GithubWebhookController|VerifyGithubSignature' "$SERVER_LOG" | grep -Ei 'error|exception|\(.*Error\)' | head -n 3)" "Error"
}

# gh_restore_repo: the stage merges a PR into the scratch repo's main; put main back to where it
# started and drop the run's branch so the repository is reusable (it is a throwaway scratch repo,
# guarded by the foreman-scratch-* name check).
gh_restore_repo() {
  [ -n "$GH_BASE_SHA" ] || return 0
  git -C "$GH_OP" push -q --force origin "$GH_BASE_SHA:refs/heads/main" 2>/dev/null \
    && note "scratch repo main restored to $GH_BASE_SHA" || note "WARNING: could not restore main of $GH_REPO"
  GH_BASE_SHA=""
  if [ -n "${GH_BRANCH:-}" ]; then gh api -X DELETE "repos/$GH_REPO/git/refs/heads/$GH_BRANCH" >/dev/null 2>&1; fi
}

step_github() {
  if github_enabled; then say "8. GitHub (real repository $GH_REPO)"; else say "8. GitHub"; fi
  if ! github_enabled; then
    out "  SKIP        GitHub stage: FOREMAN_E2E_GITHUB_REPO is not set (set it to a private <owner>/foreman-scratch-<suffix> repo to run it)"
    unverified "real GitHub paths (PR create, CI/review watching, webhook, Fix CI, conflicts, force-push, re-run, merge)" "FOREMAN_E2E_GITHUB_REPO not set"
    return 0
  fi
  gh_stage_setup || return 0
  gh_stage_pr_create || { PROJECT=$SAVE_PROJECT; REPO=$SAVE_REPO; return 0; }
  gh_stage_ci_green
  gh_stage_webhook
  gh_stage_ci_fail_fix
  gh_stage_review
  gh_stage_conflict
  gh_stage_force_push_rerun
  gh_stage_ready_and_merge
  gh_stage_webhook_summary
  gh_restore_repo
  PROJECT=$SAVE_PROJECT; REPO=$SAVE_REPO
}
