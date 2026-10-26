#!/usr/bin/env bash
# scripts/e2e/fork_live.sh
#
# Live acceptance of the FORKED continue (bead foreman-kgqqz, `foreman project adopt --continue --fork`)
# with a REAL claude (haiku), driven through the real Go CLI and HTTP API of a throwaway Foreman server
# (private database, port, scratch repo with a local bare origin; nothing touches GitHub):
#
#   1. a claude run (workflow `claudeedit`) is told a random recall word and finishes; its provider
#      session is recorded (`provider_sessions`, WorkerSessionBound);
#   2. `project adopt --kind run --id <run> --into <project> --continue --fork --prompt "<what was the word?>"`
#      answers mode `forked`; the new thread's agent is asked for the word WITHOUT being told it and
#      writes it to answer.txt: the forked agent remembers the conversation;
#   3. the fork has a session of its own and the source is untouched: same session id and status on the
#      source run, and the source's claude session file (~/.claude/projects/<cwd>/<id>.jsonl) has the
#      same sha256 and line count before and after;
#   4. (bead foreman-kgqqz, `--from-source-branch`) a SECOND continue cuts the new worktree from the
#      source session's branch: the forked thread's branch descends from it and inherits recall.txt, the
#      thread's PR base is that branch, while the plain fork of step 2 (the control) was cut from the
#      project's current branch and has neither; the context-seeded continue honours the flag too; a
#      project whose repository lacks the branch is refused `source_branch_not_found` and starts nothing;
#   5. (bead foreman-kgqqz, `--add-repo`) the finished source run is moved into a SECOND project over
#      another repository: refused `repo_not_in_project` without the flag (nothing attached, the run stays),
#      with `--add-repo` its repository is attached to the target (id from the directory name, recorded
#      `added_by adoption:run:<run>`) and the run, with its thread, belongs to the target.
#
# Without a logged-in claude the scenario is recorded UNVERIFIED (never a FAIL). Exit: 0 all passed,
# 1 environment problem, 2 setup failed, 3 one or more assertions failed.
#
#     devbox run -- bash scripts/e2e/fork_live.sh
#
# Environment (optional): the claude_projects_flow.sh variables (E2E_WORK_DIR, E2E_DB_NAME, E2E_PORT,
# E2E_HOOK_PORT, E2E_KEEP, E2E_RUN_TIMEOUT ...).

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
E2E_NAME=fork
E2E_PORT=${E2E_PORT:-4850}
E2E_HOOK_PORT=${E2E_HOOK_PORT:-4950}
# shellcheck source=claude_projects/lib.sh
. "$HERE/claude_projects/lib.sh"

check_environment
install_traps

# task_run <task_id> <timeout> -> TASK_RUN (the run bound to the task, empty after the timeout)
task_run() {
  tr_n=0; TASK_RUN=""
  while [ -z "$TASK_RUN" ] && [ "$tr_n" -lt "$2" ]; do
    TASK_RUN=$(api_get "/api/tasks/$1" | jq -r '.task.run_id // empty' 2>/dev/null)
    [ -n "$TASK_RUN" ] || { sleep 2; tr_n=$((tr_n + 2)); }
  done
}

# run_done <run_id> <timeout> -> RUN_STATUS (terminal status, or the last one seen after the timeout)
run_done() {
  rd_start=$(date +%s); RUN_STATUS=""
  while :; do
    RUN_STATUS=$(api_get "/api/runs/$1" | jq -r '.run.status // empty')
    case "$RUN_STATUS" in completed|failed|cancelled) return 0 ;; esac
    [ "$(elapsed "$rd_start")" -lt "$2" ] || return 1
    sleep 3
  done
}

# run_session <run_id> -> "<provider> <session id>" of the run's LAST bound provider session
run_session() {
  api_get "/api/runs/$1" | jq -r '.run.provider_sessions // [] | map(select(.provider_session_id != null)) | last | "\(.provider) \(.provider_session_id)"' 2>/dev/null
}

# session_file <session id> -> path of claude's own transcript of that session (any project directory)
session_file() { ls "$REAL_HOME"/.claude/projects/*/"$1".jsonl 2>/dev/null | head -n 1; }

# thread_count <project> -> number of threads of that project
thread_count() { api_get "/api/projects/$1/threads" | jq '.threads | length'; }

# thread_listed <project> <thread id>: the project's thread list holds that thread
thread_listed() { api_get "/api/projects/$1/threads" | jq -e --arg id "$2" '[.threads[].id] | index($id) != null' >/dev/null; }

# descends <ancestor branch> <branch> -> 0 when <branch> contains <ancestor branch>'s tip (in the scratch repo)
descends() { git -C "$REPO" merge-base --is-ancestor "$1" "$2" 2>/dev/null; }

# adopt_refused <what> <expected tag> <fm project adopt args...>: the call must exit 1 and print the server's
# typed 422 carrying the tag, verbatim (the CLI prints `foreman: HTTP 422: {"error":"<tag>",...}`)
adopt_refused() {
  ar_what=$1; ar_tag=$2; shift 2
  fm project adopt "$@" >"$WORK/adopt-refused.out" 2>&1; ar_rc=$?
  assert_eq "$ar_what: exit code" "$ar_rc" "1"
  assert_has "$ar_what: the server's 422" "$(cat "$WORK/adopt-refused.out")" "HTTP 422"
  assert_has "$ar_what: the typed error" "$(cat "$WORK/adopt-refused.out")" "\"error\":\"$ar_tag\""
}

# continue_run <label> <fm project adopt args...> -> NEW_RUN, NEW_BRANCH (the continued thread's run and branch), after
# the run finished; returns 1 (after a FAIL) when no run started
continue_run() {
  cr_label=$1; shift
  fm project adopt --kind run --id "$SRC_RUN" --into "$PROJECT" --continue --format json "$@" \
    >"$WORK/adopt-$cr_label.out" 2>&1 || { fail "adopt ($cr_label): $(cut -c1-300 "$WORK/adopt-$cr_label.out")"; return 1; }
  cr_task=$(jq -r '.adoption.new_task_id' "$WORK/adopt-$cr_label.out")
  task_run "$cr_task" 180
  NEW_RUN=$TASK_RUN
  [ -n "$NEW_RUN" ] || { fail "no run was started for the $cr_label thread $cr_task"; return 1; }
  note "$cr_label thread: task $cr_task, run $NEW_RUN"
  run_done "$NEW_RUN" "$E2E_RUN_TIMEOUT" || true
  assert_eq "the $cr_label thread's run completed" "$RUN_STATUS" "completed"
  NEW_BRANCH=$(api_get "/api/threads/run:$NEW_RUN" | jq -r '.thread.branch // empty')
  return 0
}

# scenario_source_branch: `--from-source-branch` (needs the source run and the plain fork of scenario_fork)
scenario_source_branch() {
  say "scenario source branch (real claude)"
  note "EXPECTED: --from-source-branch cuts the new worktree from the source session's branch ($src_branch): the continued thread's branch descends from it and inherits recall.txt, its PR base is that branch; the plain fork was cut from the project's current branch (control)"

  # Control: the plain fork of scenario_fork asked for nothing, so it was cut from the project's current branch.
  if descends "$src_branch" "$fork_branch"; then
    fail "control: the plain fork's branch $fork_branch contains $src_branch, but it was cut from the project's current branch"
  else
    pass "control: the plain fork's branch is NOT built on the source branch"
  fi
  assert_eq "control: recall.txt (the source's file) is not on the plain fork's branch" "$(git -C "$REPO" show "$fork_branch:recall.txt" 2>/dev/null)" ""
  assert_eq "control: the plain fork's PR base is the project's current branch" "$(api_get "/api/runs/$FORK_RUN" | jq -r '.run.base_branch // empty')" "main"

  # Forked + from the source branch.
  continue_run fork-branch --fork --from-source-branch \
    --prompt "What was the recall word? Create a file named answer-branch.txt containing exactly that word and nothing else." || return 0
  assert_eq "adopt --fork --from-source-branch answers mode forked" "$(jq -r '.adoption.mode' "$WORK/adopt-fork-branch.out")" "forked"
  assert_eq "the answer names the branch the thread was cut from" "$(jq -r '.adoption.source_branch' "$WORK/adopt-fork-branch.out")" "$src_branch"
  FB_RUN=$NEW_RUN; FB_BRANCH=$NEW_BRANCH
  if [ -n "$FB_BRANCH" ] && descends "$src_branch" "$FB_BRANCH"; then
    pass "the forked thread's branch $FB_BRANCH contains the source branch $src_branch"
  else
    fail "the forked thread's branch '$FB_BRANCH' does not contain the source branch $src_branch"
  fi
  assert_content_exactly "recall.txt was INHERITED from the source branch (not written by this thread)" "$(git -C "$REPO" show "$FB_BRANCH:recall.txt" 2>/dev/null)" "$WORD"
  assert_content_exactly "the forked agent still remembered the word (answer-branch.txt)" "$(git -C "$REPO" show "$FB_BRANCH:answer-branch.txt" 2>/dev/null)" "$WORD"
  assert_eq "the thread's PR base branch is the source branch" "$(api_get "/api/runs/$FB_RUN" | jq -r '.run.base_branch // empty')" "$src_branch"
  assert_true "only this thread's own work sits on top of the source branch (>= 1 commit ahead, answer-branch.txt among them)" \
    test "$(git -C "$REPO" rev-list --count "$src_branch..$FB_BRANCH")" -ge 1
  assert_eq "the forked thread's session is its own, not the source's" "$([ "$(run_session "$FB_RUN")" != "claude $SRC_SID" ] && echo own)" "own"

  # Context-seeded (no fork) + from the source branch.
  continue_run seeded-branch --from-source-branch \
    --prompt "Create a file named seeded.txt containing exactly the word SEEDED and nothing else." || return 0
  assert_eq "adopt --from-source-branch (no fork) answers mode context_seeded" "$(jq -r '.adoption.mode' "$WORK/adopt-seeded-branch.out")" "context_seeded"
  assert_eq "... and names the source branch" "$(jq -r '.adoption.source_branch' "$WORK/adopt-seeded-branch.out")" "$src_branch"
  if [ -n "$NEW_BRANCH" ] && descends "$src_branch" "$NEW_BRANCH"; then
    pass "the context-seeded thread's branch $NEW_BRANCH contains the source branch"
  else
    fail "the context-seeded thread's branch '$NEW_BRANCH' does not contain the source branch $src_branch"
  fi
  assert_content_exactly "the context-seeded thread inherited recall.txt too" "$(git -C "$REPO" show "$NEW_BRANCH:recall.txt" 2>/dev/null)" "$WORD"
  assert_content_exactly "the context-seeded agent did its own work (seeded.txt)" "$(git -C "$REPO" show "$NEW_BRANCH:seeded.txt" 2>/dev/null)" "SEEDED"
  assert_eq "the context-seeded thread's PR base branch is the source branch" "$(api_get "/api/runs/$NEW_RUN" | jq -r '.run.base_branch // empty')" "$src_branch"
}

# scenario_add_repo: `--add-repo` and a project whose repository lacks the source branch (needs SRC_RUN)
scenario_add_repo() {
  say "scenario add repo: the session's repository is outside the target project"
  note "EXPECTED: a second project over another repository refuses the session's repository (repo_not_in_project, nothing attached); --add-repo attaches it and moves the run"
  OUTSIDE="$WORK/outside"
  make_repo "$OUTSIDE" "$WORK/outside-origin.git" || { fail "cannot create the second scratch repository"; return 0; }
  (cd "$OUTSIDE" && br init --prefix out >/dev/null 2>&1) || { fail "br init failed in $OUTSIDE"; return 0; }
  printf '.beads/\n' >> "$OUTSIDE/.git/info/exclude"
  OUT_PROJECT="$PROJECT-out"
  fm project create --id "$OUT_PROJECT" --path "$OUTSIDE" --task-provider beads \
    --task-provider-database-path "$OUTSIDE/.beads/beads.db" >"$WORK/project-out-create.out" 2>&1 \
    || { fail "project create (second project): $(cut -c1-300 "$WORK/project-out-create.out")"; return 0; }
  note "second project $OUT_PROJECT over $OUTSIDE"
  repo_canonical=$(cd "$REPO" && pwd -P)
  attached() { fm project repo list --format json "$OUT_PROJECT" | jq -r '[.repositories[] | select(.primary | not)] | length'; }

  # The branch lives in the first project's repository only.
  adopt_refused "continue --from-source-branch into a project whose repository lacks the branch" source_branch_not_found \
    --kind run --id "$SRC_RUN" --into "$OUT_PROJECT" --continue --from-source-branch --prompt "never started"
  assert_eq "that refusal started no thread in the second project" "$(thread_count "$OUT_PROJECT")" "0"

  # Without the flag the foreign repository is refused, and nothing is attached.
  adopt_refused "move into a project that does not own the session's repository" repo_not_in_project \
    --kind run --id "$SRC_RUN" --into "$OUT_PROJECT"
  assert_eq "the refused move attached no repository" "$(attached)" "0"
  assert_eq "the refused move left the run in its own project" "$(api_get "/api/runs/$SRC_RUN" | jq -r '.run.project_id')" "$PROJECT"

  # With the flag: the repository is attached, then the run moves.
  fm project adopt --kind run --id "$SRC_RUN" --into "$OUT_PROJECT" --add-repo --format json >"$WORK/adopt-add-repo.out" 2>&1 \
    || { fail "adopt --add-repo: $(cut -c1-300 "$WORK/adopt-add-repo.out")"; return 0; }
  assert_eq "adopt --add-repo answers mode move" "$(jq -r '.adoption.mode' "$WORK/adopt-add-repo.out")" "move"
  assert_eq "... into the second project" "$(jq -r '.adoption.project_id' "$WORK/adopt-add-repo.out")" "$OUT_PROJECT"
  assert_eq "... from the first" "$(jq -r '.adoption.from_project_id' "$WORK/adopt-add-repo.out")" "$PROJECT"
  repos_json=$(fm project repo list --format json "$OUT_PROJECT")
  assert_eq "the session's repository was attached to the second project (canonical path)" \
    "$(printf '%s' "$repos_json" | jq -r --arg p "$repo_canonical" '[.repositories[] | select(.primary | not) | select(.path == $p)] | length')" "1"
  assert_eq "... under the id derived from its directory name" \
    "$(printf '%s' "$repos_json" | jq -r --arg p "$repo_canonical" '[.repositories[] | select(.path == $p)][0].id')" "$(basename "$REPO" | tr 'A-Z' 'a-z')"
  assert_eq "... recorded as added by the adoption" \
    "$(printf '%s' "$repos_json" | jq -r --arg p "$repo_canonical" '[.repositories[] | select(.path == $p)][0].added_by')" "adoption:run:$SRC_RUN"
  assert_eq "the second project's own repository is untouched (the primary is still $OUTSIDE)" \
    "$(printf '%s' "$repos_json" | jq -r '[.repositories[] | select(.primary)][0].path')" "$OUTSIDE"
  assert_eq "the run now belongs to the second project" "$(api_get "/api/runs/$SRC_RUN" | jq -r '.run.project_id')" "$OUT_PROJECT"
  assert_true "its thread is listed under the second project" thread_listed "$OUT_PROJECT" "run:$SRC_RUN"
}

scenario_fork() {
  say "scenario fork (real claude)"
  note "EXPECTED: adopt --continue --fork answers mode forked; the forked agent knows a word it was never told in its own prompt; it has its own session; the source session is byte-identical afterwards"
  if ! claude_ready; then unverified "forked adopt with real claude" "$CLAUDE_UNAVAILABLE"; return 0; fi
  stop_server
  install_claude_workflow
  E2E_EXTRA_ENV="E2E_REVIEW_ANALYSIS=0" start_server
  WORD="RECALL-$$-$(date +%s)"

  src_task="fork-src-$SUFFIX"
  fm run submit --project-id "$PROJECT" --workflow claudeedit --work-id "$src_task" \
    --prompt "Remember the recall word $WORD. Then create a file named recall.txt containing exactly that word and nothing else." \
    >"$WORK/submit-src.out" 2>&1 || { fail "run submit: $(cut -c1-200 "$WORK/submit-src.out")"; return 0; }
  task_run "$src_task" 180
  SRC_RUN=$TASK_RUN
  [ -n "$SRC_RUN" ] || { fail "no run was started for the source task"; return 0; }
  note "source run $SRC_RUN"
  run_done "$SRC_RUN" "$E2E_RUN_TIMEOUT" || true
  assert_eq "the claude source run completed" "$RUN_STATUS" "completed"
  src_session=$(run_session "$SRC_RUN")
  SRC_SID=${src_session#* }
  assert_eq "the source run recorded a claude provider session" "${src_session%% *}" "claude"
  [ -n "$SRC_SID" ] && [ "$SRC_SID" != null ] || { fail "no provider session id on the source run"; return 0; }
  src_branch=$(api_get "/api/threads/run:$SRC_RUN" | jq -r '.thread.branch // empty')
  assert_content_exactly "the source agent wrote the word it was told (recall.txt on $src_branch)" "$(git -C "$REPO" show "$src_branch:recall.txt" 2>/dev/null)" "$WORD"

  src_file=$(session_file "$SRC_SID")
  [ -n "$src_file" ] || { fail "claude's session file of $SRC_SID not found under $REAL_HOME/.claude/projects"; return 0; }
  sha_before=$(shasum -a 256 "$src_file" | cut -d' ' -f1)
  lines_before=$(wc -l < "$src_file" | tr -d ' ')
  note "source session $SRC_SID: $src_file ($lines_before lines, sha256 $sha_before)"
  src_status_before=$(api_get "/api/runs/$SRC_RUN" | jq -c '{status: .run.status, sessions: .run.provider_sessions}')

  fm project adopt --kind run --id "$SRC_RUN" --into "$PROJECT" --continue --fork --format json \
    --prompt "What was the recall word? Create a file named answer.txt containing exactly that word and nothing else." \
    >"$WORK/adopt-fork.out" 2>&1 || { fail "adopt --fork: $(cut -c1-300 "$WORK/adopt-fork.out")"; return 0; }
  assert_eq "adopt --continue --fork answers mode forked" "$(jq -r '.adoption.mode' "$WORK/adopt-fork.out")" "forked"
  new_task=$(jq -r '.adoption.new_task_id' "$WORK/adopt-fork.out")
  task_run "$new_task" 180
  FORK_RUN=$TASK_RUN
  [ -n "$FORK_RUN" ] || { fail "no run was started for the forked thread $new_task"; return 0; }
  note "forked thread: task $new_task, run $FORK_RUN"
  run_done "$FORK_RUN" "$E2E_RUN_TIMEOUT" || true
  assert_eq "the forked thread's run completed" "$RUN_STATUS" "completed"
  fork_branch=$(api_get "/api/threads/run:$FORK_RUN" | jq -r '.thread.branch // empty')
  assert_content_exactly "the forked agent remembered the recall word (answer.txt on $fork_branch)" "$(git -C "$REPO" show "$fork_branch:answer.txt" 2>/dev/null)" "$WORD"

  fork_session=$(run_session "$FORK_RUN")
  FORK_SID=${fork_session#* }
  assert_eq "the fork ran on claude" "${fork_session%% *}" "claude"
  if [ -n "$FORK_SID" ] && [ "$FORK_SID" != null ] && [ "$FORK_SID" != "$SRC_SID" ]; then
    pass "the fork has a provider session of its own ($FORK_SID, not $SRC_SID)"
  else
    fail "the fork reports session '$FORK_SID' (source: $SRC_SID): a fork must get its own"
  fi

  assert_eq "the source session file has the same sha256 after the fork" "$(shasum -a 256 "$src_file" | cut -d' ' -f1)" "$sha_before"
  assert_eq "the source session file has the same line count after the fork" "$(wc -l < "$src_file" | tr -d ' ')" "$lines_before"
  assert_eq "the source run (status and provider sessions) is unchanged" "$(api_get "/api/runs/$SRC_RUN" | jq -c '{status: .run.status, sessions: .run.provider_sessions}')" "$src_status_before"
}

setup_stack
register_project || { cat "$WORK/project-create.out"; die "project create failed" 2; }
note "project $PROJECT registered"
scenario_fork
if [ -n "${FORK_RUN:-}" ]; then
  scenario_source_branch
  scenario_add_repo
else
  unverified "source-branch and add-repo scenarios" "they build on the source run and the plain fork of the scenario above, which did not complete"
fi
summary
exit $?
