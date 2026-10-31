#!/usr/bin/env bash
# Live acceptance of the question.answer length boundary through a REAL claude run and a real browser
# (bead foreman-7c191 part 2, audit row C7; docs/acceptance/question-answer-boundary-live-run.md).
#
#   devbox run -- bash scripts/e2e/question_answer_boundary.sh
#   QB_AGENT=none devbox run -- bash scripts/e2e/question_answer_boundary.sh   # no claude: a task with no run (a dry run of the harness)
#
# Needs a logged-in claude (otherwise UNVERIFIED) and the Playwright + Chromium of scripts/e2e/ui-a11y
# (`cd scripts/e2e/ui-a11y && npm ci`; otherwise UNVERIFIED). The server runs with a PRIVATE claude HOME
# (claude_projects/claude_home.sh): stock claude settings, sessions under $WORK/home/.claude/projects.
#
# One throwaway server (own port, database, scratch repo; claude_projects/lib.sh) and ONE real claude run (haiku, workflow
# claudeedit, approval_mode auto_approve). The agent is told to ask two questions by POSTing to Foreman's operator ingest, exactly
# as an agent does it (/webhooks/operator/ingest: the question is opened under the run of its task), to wait with 20 s tool
# calls (a live claude session takes a steer between tool calls) and to act on the last sentence of each answer:
#
#   Q-exact  answered in the BROWSER with exactly max_answer_chars(question_id) characters (8000, the run.steer cap, minus the
#            "Answer to your question <id>: " prefix). Accepted, delivered as ONE run.steer of exactly 8000 characters (SHA-256
#            equal to the text the harness built), RunSteerDelivered, and the agent obeys the sentence at the very END of it
#            (a file on the run's branch): the whole text arrived. The agent's own claude session file holds the message.
#   Q-over   the browser box carries maxlength = the limit for this question id; one more typed character is stopped by the
#            browser; a client that ignores the attribute (value set from script) submits limit+1 characters and the server
#            refuses it in the page; the CLI refusal (HTTP 422 text) is printed; after both, the question is still open and no
#            QuestionAnswered / run.steer exists; a shorter answer over the CLI then goes through and the agent acts on it.
#   ids      a question id of exactly 200 characters opens (its box carries the SMALLER limit, the prefix is longer); one of 201
#            is refused at question.open (no QuestionOpened; the typed error from a direct dispatch on the server node).
#
# The numbers (the steer cap, the prefix length, every expected hash) are computed HERE, not read from the code under test.
# Prints PASS / FAIL / UNVERIFIED per assertion; exit 3 on any FAIL. Environment (besides lib.sh's): QB_AGENT (claude|none),
# E2E_SHOT_DIR (screenshots, default <checkout>/tmp/question-boundary-shots), E2E_RUN_TIMEOUT.
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
QB_AGENT=${QB_AGENT:-claude}
E2E_NAME=${E2E_NAME:-qbound}
E2E_PORT=${E2E_PORT:-4850}
E2E_HOOK_PORT=${E2E_HOOK_PORT:-4950}
E2E_EXTRA_ENV="E2E_REVIEW_ANALYSIS=0"
# shellcheck source=claude_projects/lib.sh
. "$HERE/claude_projects/lib.sh"
# shellcheck source=claude_projects/claude_home.sh
. "$HERE/claude_projects/claude_home.sh"

UI="$HERE/ui-a11y"
QUI="$HERE/live_claude/questions_ui.mjs"
QB_ASSETS="$HERE/question_answer_boundary"
SHOT_DIR=${E2E_SHOT_DIR:-$ROOT/tmp/question-boundary-shots}

check_environment
command -v node >/dev/null 2>&1 || die "'node' is required on PATH" 1
install_traps

say "browser tooling"
if [ ! -d "$UI/node_modules/playwright" ]; then
  (cd "$UI" && npm ci --no-audit --no-fund >"$WORK.npm.log" 2>&1) \
    || { unverified "question.answer boundary in a browser" "npm ci in scripts/e2e/ui-a11y failed: $(tail -n 3 "$WORK.npm.log" 2>/dev/null | tr '\n' ' ')"; summary; exit $?; }
fi
note "playwright from $UI/node_modules"

# ---------------------------------------------------------------- the numbers, computed here and not by the code under test

STEER_CAP=8000   # the run.steer text cap, in characters
prefix_chars() { echo $((24 + ${#1} + 2)); }   # "Answer to your question " (24) + id + ": " (2)
max_for() { echo $((STEER_CAP - $(prefix_chars "$1"))); }
sha256_of() { printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1; }

# make_answer <total characters> <last sentence>: exactly <total> characters of single-line ASCII, ending with the sentence
make_answer() {
  python3 -c '
import sys
total = int(sys.argv[1]); tail = sys.argv[2]
head = "Background notes for this question, none of them needs any action: "
n = 0
while len(head) < total - len(tail) - 1:
    n += 1
    head += "note%05d " % n
head = head[: total - len(tail) - 1]
out = head + " " + tail
assert len(out) == total, (len(out), total)
sys.stdout.write(out)
' "$1" "$2"
}

TASK="qb-task-$SUFFIX"
QE="qb-$SUFFIX-exact"
QO="qb-$SUFFIX-over"
QLONG200=$(python3 -c "print('q' * 200, end='')")
QLONG201=$(python3 -c "print('q' * 201, end='')")
MAX_E=$(max_for "$QE")
MAX_O=$(max_for "$QO")
MAX_200=$(max_for "$QLONG200")
TAIL_E="FINAL INSTRUCTION: write the single word BOUNDARY-EXACT-OK into a new file named answer-exact.txt in the current directory."
TAIL_O="FINAL INSTRUCTION: write the single word BOUNDARY-OVER-BUG into a new file named answer-over.txt in the current directory."
ANS_E=$(make_answer "$MAX_E" "$TAIL_E")
ANS_OVER=$(make_answer $((MAX_O + 1)) "$TAIL_O")
ANS_SHORT="Second answer, a short one. FINAL INSTRUCTION: write the single word BOUNDARY-SHORT-OK into a new file named answer-short.txt in the current directory."
note "limits computed from the $STEER_CAP-character steer cap: $QE -> $MAX_E, $QO -> $MAX_O, a 200-character id -> $MAX_200"
assert_eq "the exact answer has exactly max_answer_chars($QE) characters" "${#ANS_E}" "$MAX_E"
assert_eq "the over-limit answer has max+1 characters" "${#ANS_OVER}" "$((MAX_O + 1))"

# ---------------------------------------------------------------- helpers

qlist() { api_get "/api/projects/$PROJECT/questions?status=all"; }
q_field() { # <question id> <field>
  qlist | jq -r --arg q "$1" --arg f "$2" '[.. | objects | select(.question_id? == $q)][0][$f] // empty' 2>/dev/null
}
wait_question() { # <question id> <timeout s>: until the question is listed
  wq=$(date +%s)
  while [ -z "$(q_field "$1" status)" ]; do
    [ "$(elapsed "$wq")" -lt "$2" ] || return 1
    sleep 2
  done
}
wait_status() { # <question id> <status> <timeout s>
  ws=$(date +%s)
  while [ "$(q_field "$1" status)" != "$2" ]; do
    [ "$(elapsed "$ws")" -lt "$3" ] || return 1
    sleep 1
  done
}
ingest() { # <question id> <text> -> the HTTP status; the body goes to $WORK/ingest.out
  curl -sS -o "$WORK/ingest.out" -w '%{http_code}' --max-time 30 -X POST "$API/webhooks/operator/ingest" -H 'content-type: application/json' \
    -d "$(jq -nc --arg q "$1" --arg t "$2" --arg a "$TASK" '{question_id: $q, question: $t, agent_id: $a}')" 2>/dev/null
}
qev() { # <question id>...: the QEV lines of those questions (lengths and hashes, never the text)
  qe_ids=$(printf '"%s",' "$@"); qe_ids="[${qe_ids%,}]"
  rpc "question_ids = $qe_ids
$(cat "$QB_ASSETS/question_events.exs")" 2>&1 | grep '^QEV ' | cut -c5-
}
qev_until() { # <event type> <timeout s> <question id>: QEV_OUT holds the events once one of that type exists (or when the time is up)
  qu=$(date +%s)
  while :; do
    QEV_OUT=$(qev "$3")
    if printf '%s\n' "$QEV_OUT" | jq -e --arg t "$1" 'select(.type == $t)' >/dev/null 2>&1; then return 0; fi
    [ "$(elapsed "$qu")" -lt "$2" ] || return 1
    sleep 2
  done
}
ev_count() { printf '%s\n' "$1" | jq -s --arg t "$2" '[.[] | select(.type == $t)] | length'; }
ev_first() { printf '%s\n' "$1" | jq -rs --arg t "$2" --arg f "$3" '[.[] | select(.type == $t)][0][$f] // empty'; }
ui() { # <action> <args...>: questions_ui.mjs against this stack
  FOREMAN_API_URL="$API" FOREMAN_API_TOKEN="$E2E_API_TOKEN" HOME="$REAL_HOME" \
    node "$QUI" "$1" --base "http://localhost:$E2E_PORT" --token "$E2E_API_TOKEN" --project "$PROJECT" --shot-dir "$SHOT_DIR" "${@:2}"
}
ui_jq() { jq -cR "fromjson? | $2" "$1" 2>/dev/null; }   # <file> <filter>: the file's JSON lines (anything else is skipped)
ui_event() { # <file> <event> <jq expression over that event>: the value from the first such event, "" when absent or null
  jq -rR --arg e "$2" "fromjson? | select(.event == \$e) | ($3) | if . == null then empty else . end" "$1" 2>/dev/null | head -n 1
}
ui_box_max() { # <state file> <question id>: the maxlength of that question's answer box
  jq -rR --arg q "$2" 'fromjson? | select(.event == "state") | .questions[]? | select(.id | endswith("-" + $q)) | .maxlength // empty' "$1" 2>/dev/null | head -n 1
}
wait_run_terminal() {
  wr=$(date +%s)
  while :; do
    RUN_STATUS=$(api_get "/api/runs/$RUN" | jq -r '.status // .run.status // empty' 2>/dev/null)
    case "$RUN_STATUS" in completed|failed|cancelled) return 0 ;; esac
    [ "$(elapsed "$wr")" -lt "$E2E_RUN_TIMEOUT" ] || return 1
    sleep "$E2E_POLL_SECS"
  done
}

# ---------------------------------------------------------------- setup

setup_stack
if [ "$QB_AGENT" = claude ]; then
  if claude_private_home && claude_ready; then
    note "claude is ready through the private HOME"
    install_claude_workflow
    stop_server; start_server   # the server's HOME carries the private claude home; the catalog sees claudeedit
  else
    unverified "question.answer boundary through a real claude run" "$CLAUDE_UNAVAILABLE"
    summary; exit $?
  fi
fi
register_project || { head -c 1500 "$WORK/project-create.out"; tail -n 20 "$SERVER_LOG" | cut -c1-240; die "cannot register the project" 2; }
note "project $PROJECT registered over $REPO"
mkdir -p "$SHOT_DIR"

# ---------------------------------------------------------------- the run and the questions

say "the agent asks two questions"
RUN=""
if [ "$QB_AGENT" = claude ]; then
  PROMPT="You need two decisions from the operator, so ask them with HTTP POST requests (these are not file operations).
Step 1. Run these two shell commands, one after the other:
curl -sS -X POST $API/webhooks/operator/ingest -H 'content-type: application/json' -d '{\"question_id\":\"$QE\",\"question\":\"Question A: what must the first file say?\",\"agent_id\":\"$TASK\"}'
curl -sS -X POST $API/webhooks/operator/ingest -H 'content-type: application/json' -d '{\"question_id\":\"$QO\",\"question\":\"Question B: what must the second file say?\",\"agent_id\":\"$TASK\"}'
Step 2. The operator's answers arrive later as new messages in this conversation, each starting with \"Answer to your question <question id>:\". Until BOTH have arrived, run this waiting command and nothing else, again and again (at most 40 times): python3 -c \"import time; time.sleep(20)\"
Step 3. When an answer arrives, read it to its very last sentence and do exactly what that last sentence says (it names a file to create and the word to put in it).
Step 4. When you have acted on both answers, reply with exactly: done"
  if fm run submit --project-id "$PROJECT" --work-id "$TASK" --backend claude --workflow claudeedit --prompt "$PROMPT" >"$WORK/run-submit.out" 2>&1; then
    pass "a real claude run was submitted (task $TASK)"
  else
    fail "run submit failed: $(head -c 400 "$WORK/run-submit.out")"; summary; exit $?
  fi
  rs=$(date +%s)
  while [ -z "$RUN" ] && [ "$(elapsed "$rs")" -lt 120 ]; do
    RUN=$(api_get "/api/runs?project_id=$PROJECT&limit=50" | jq -r --arg t "$TASK" '[.runs[]? | select(.task_id == $t)][0].run_id // empty' 2>/dev/null)
    [ -n "$RUN" ] || sleep 2
  done
  if [ -n "$RUN" ]; then note "run $RUN"; else fail "no run for task $TASK after 120 s"; summary; exit $?; fi
  if wait_question "$QE" 240 && wait_question "$QO" 60; then
    pass "the agent raised both questions itself (curl to /webhooks/operator/ingest from its own Bash tool)"
  else
    note "the agent did not raise both questions itself within the wait; the harness posts the missing one(s) the way the agent would"
    [ -n "$(q_field "$QE" status)" ] || note "harness ingest $QE: HTTP $(ingest "$QE" "Question A: what must the first file say?")"
    [ -n "$(q_field "$QO" status)" ] || note "harness ingest $QO: HTTP $(ingest "$QO" "Question B: what must the second file say?")"
    if wait_question "$QE" 30 && wait_question "$QO" 30; then
      unverified "the agent raising its own questions" "the harness had to post at least one of them"
    else
      fail "the questions did not open"; summary; exit $?
    fi
  fi
else
  # no agent: a task that never gets a run (not approved); its questions belong to the project and the run "global"
  code=$(curl -sS -o "$WORK/task-create.out" -w '%{http_code}' -X POST "$API/api/commands" -H "authorization: Bearer $E2E_API_TOKEN" -H 'content-type: application/json' \
    -d "$(jq -nc --arg t "$TASK" --arg p "$PROJECT" '{type: "task.create", payload: {task_id: $t, project_id: $p, task_type: "task", workflow_type: "edit", prompt: "no agent", title: "no agent", provider_tracked: false, auto_approve: false}}')" 2>&1)
  note "task.create without a run: HTTP $code $(head -c 200 "$WORK/task-create.out")"
  RUN=global
  note "harness ingest $QE: HTTP $(ingest "$QE" "Question A: what must the first file say?")"
  note "harness ingest $QO: HTTP $(ingest "$QO" "Question B: what must the second file say?")"
  if ! { wait_question "$QE" 30 && wait_question "$QO" 30; }; then fail "the questions did not open"; summary; exit $?; fi
  unverified "a real claude run asking, receiving and acting on the answers" "QB_AGENT=none: no run exists, the answers go to the signal bus"
fi
assert_eq "$QE is open" "$(q_field "$QE" status)" "open"
assert_eq "$QE belongs to the run $RUN" "$(q_field "$QE" run_id)" "$RUN"
assert_eq "$QE was asked by the task $TASK" "$(q_field "$QE" agent_id)" "$TASK"
assert_eq "$QO is open" "$(q_field "$QO" status)" "open"
assert_eq "$QO belongs to the run $RUN" "$(q_field "$QO" run_id)" "$RUN"

# ---------------------------------------------------------------- the question id bound (question.open)

say "question ids: 200 characters open, 201 are refused at question.open"
code200=$(ingest "$QLONG200" "Question C: a question with a 200-character id")
code201=$(ingest "$QLONG201" "Question D: a question with a 201-character id")
note "ingest of the 200-character id: HTTP $code200; of the 201-character id: HTTP $code201 (the inbox item exists either way; question.open is what refuses)"
wait_question "$QLONG200" 20
assert_eq "the 200-character id opened a question" "$(q_field "$QLONG200" status)" "open"
assert_eq "the 201-character id opened NO question" "$(q_field "$QLONG201" status)" ""
ev_ids=$(qev "$QLONG200" "$QLONG201")
printf '%s\n' "$ev_ids" > "$WORK/question-events-ids.jsonl"
assert_eq "QuestionOpened events for the 200-character id" "$(printf '%s\n' "$ev_ids" | jq -s --arg q "$QLONG200" '[.[] | select(.type == "QuestionOpened" and .question_id == $q)] | length')" "1"
assert_eq "QuestionOpened events for the 201-character id" "$(printf '%s\n' "$ev_ids" | jq -s --arg q "$QLONG201" '[.[] | select(.type == "QuestionOpened" and .question_id == $q)] | length')" "0"
log_refusal=$(grep -c 'question.open for' "$SERVER_LOG")
note "server log lines naming a failed question.open: $log_refusal: $(grep 'question.open for' "$SERVER_LOG" | tail -n 1 | sed -E 's/q{20,}/<q x N>/g' | cut -c1-300)"
assert_eq "the server logged the refused question.open" "$([ "$log_refusal" -ge 1 ] && echo yes || echo no)" "yes"
direct=$(rpc "id = String.duplicate(\"q\", 201)
IO.puts(\"DIRECT \" <> inspect(ForemanServer.Approvals.Dispatch.system(%{type: \"question.open\", command_id: \"qb-direct-201\", aggregate_id: ForemanServer.Aggregates.OperatorQuestion.stream_id(\"global\", id), payload: %{run_id: \"global\", question_id: id}}), limit: 12))" 2>&1 | grep '^DIRECT ')
note "direct question.open of a 201-character id on the server node: $direct"
assert_has "the typed refusal is question_id_too_long" "$direct" "question_id_too_long"
assert_has "...naming 201 and the bound 200" "$direct" "201, 200"

# the answer boxes in the browser: one maxlength per question id
ui state > "$WORK/ui-state.out" 2>&1
note "browser state: $(ui_jq "$WORK/ui-state.out" 'select(.event == "state") | [.questions[] | {id: (.id | .[-24:]), maxlength}]' | head -c 500)"
assert_eq "the answer box of $QE carries maxlength = max_answer_chars" "$(ui_box_max "$WORK/ui-state.out" "$QE")" "$MAX_E"
assert_eq "the answer box of the 200-character id carries the SMALLER limit (the prefix is longer)" "$(ui_box_max "$WORK/ui-state.out" "$QLONG200")" "$MAX_200"

# ---------------------------------------------------------------- Q-exact: exactly max_answer_chars, typed in the browser

say "$QE: an answer of exactly $MAX_E characters, typed in the browser"
ui answer --question "$QE" --text "$ANS_E" --label qe-exact > "$WORK/ui-answer-exact.out" 2>&1
ui_rc=$?
note "browser answer: exit $ui_rc; $(ui_jq "$WORK/ui-answer-exact.out" 'select(.event == "typed" or .event == "notice" or .event == "row-after") | del(.questions, .waiting_on_you, .working)' | head -c 700 | tr '\n' ' ')"
assert_eq "the box took all $MAX_E characters" "$(ui_event "$WORK/ui-answer-exact.out" typed .box_length)" "$MAX_E"
assert_has "the page said Done" "$(ui_event "$WORK/ui-answer-exact.out" notice .text)" "Done"
assert_eq "the question left the pane" "$(ui_event "$WORK/ui-answer-exact.out" row-after .still_present)" "false"
wait_status "$QE" answered 20
assert_eq "$QE is answered" "$(q_field "$QE" status)" "answered"
if [ "$QB_AGENT" = claude ]; then qev_until RunSteerDelivered 45 "$QE"; else QEV_OUT=$(qev "$QE"); fi
ev_e=$QEV_OUT; printf '%s\n' "$ev_e" > "$WORK/question-events-exact.jsonl"
exp_steer_sha=$(sha256_of "Answer to your question $QE: $ANS_E")
assert_eq "QuestionAnswered carries exactly $MAX_E characters" "$(ev_first "$ev_e" QuestionAnswered text_length)" "$MAX_E"
assert_eq "QuestionAnswered text is byte-identical to what was typed (SHA-256)" "$(ev_first "$ev_e" QuestionAnswered text_sha256)" "$(sha256_of "$ANS_E")"
assert_eq "the answer was recorded as answered_by dashboard" "$(ev_first "$ev_e" QuestionAnswered answered_by)" "dashboard"
if [ "$QB_AGENT" = claude ]; then
  assert_eq "ONE run.steer was queued for it (message id question:$QE)" "$(ev_count "$ev_e" RunSteerQueued)" "1"
  assert_eq "the steer is exactly $STEER_CAP characters (the cap, no more)" "$(ev_first "$ev_e" RunSteerQueued text_length)" "$STEER_CAP"
  assert_eq "the steer is the prefix plus the answer, byte for byte (SHA-256)" "$(ev_first "$ev_e" RunSteerQueued text_sha256)" "$exp_steer_sha"
  assert_eq "RunSteerDelivered was recorded for it" "$(ev_count "$ev_e" RunSteerDelivered)" "1"
  note "delivery mode: $(ev_first "$ev_e" RunSteerDelivered mode); consumed so far: $(ev_first "$ev_e" RunSteerConsumed delivery)"
else
  unverified "run.steer of the exact answer" "QB_AGENT=none: the task has no run"
fi

# ---------------------------------------------------------------- Q-over: one character more is refused, the question stays open

say "$QO: limit+1 is refused (browser and CLI), the question stays open, a shorter answer then goes through"
ui limit --question "$QO" --text "$ANS_OVER" --label qo-limit > "$WORK/ui-limit.out" 2>&1
ui_rc=$?
note "browser limit probe: exit $ui_rc; $(ui_jq "$WORK/ui-limit.out" 'select(.event != "question-visible" and .event != "screenshot" and .event != "connected") | del(.questions, .waiting_on_you, .working)' | head -c 900 | tr '\n' ' ')"
assert_eq "the box of $QO carries maxlength = $MAX_O" "$(ui_event "$WORK/ui-limit.out" limit-attribute .maxlength)" "$MAX_O"
assert_eq "exactly $MAX_O characters fit" "$(ui_event "$WORK/ui-limit.out" typed-exact-limit .length)" "$MAX_O"
assert_eq "one more typed character is stopped by the browser (the value stays $MAX_O)" "$(ui_event "$WORK/ui-limit.out" typed-one-more-character .length)" "$MAX_O"
assert_eq "a client that ignores the attribute can set $((MAX_O + 1)) characters" "$(ui_event "$WORK/ui-limit.out" value-set-past-limit .length)" "$((MAX_O + 1))"
ui_notice=$(ui_event "$WORK/ui-limit.out" notice .text)
assert_has "the page refuses it, naming the length" "$ui_notice" "$((MAX_O + 1)) characters"
assert_has "...and the limit" "$ui_notice" "at most $MAX_O"
assert_eq "the refusal is error-styled" "$(ui_event "$WORK/ui-limit.out" notice .error_styled)" "true"
assert_eq "the question stays in the pane" "$(ui_event "$WORK/ui-limit.out" notice .row_still_present)" "true"
assert_eq "$QO is still open (API)" "$(q_field "$QO" status)" "open"

cli_out=$(fm questions answer --run "$RUN" --question "$QO" --text "$ANS_OVER" --by e2e 2>&1); cli_rc=$?
printf '%s\n' "$cli_out" | cut -c1-600 > "$WORK/cli-over.out"
note "CLI answer of $((MAX_O + 1)) characters: exit $cli_rc: $(cut -c1-300 "$WORK/cli-over.out" | tr '\n' ' ')"
assert_eq "the CLI refuses it (non-zero exit)" "$([ "$cli_rc" -ne 0 ] && echo refused || echo accepted)" "refused"
assert_has "the CLI prints the HTTP 422" "$cli_out" "422"
assert_has "...with answer_too_long" "$cli_out" "answer_too_long"
assert_has "...and the limit $MAX_O" "$cli_out" "$MAX_O"
assert_eq "$QO is still open after the CLI refusal" "$(q_field "$QO" status)" "open"
ev_o1=$(qev "$QO"); printf '%s\n' "$ev_o1" > "$WORK/question-events-over-1.jsonl"
assert_eq "no QuestionAnswered exists for $QO" "$(ev_count "$ev_o1" QuestionAnswered)" "0"
assert_eq "no run.steer was queued for $QO" "$(ev_count "$ev_o1" RunSteerQueued)" "0"

cli_out=$(fm questions answer --run "$RUN" --question "$QO" --text "$ANS_SHORT" --by e2e 2>&1); cli_rc=$?
note "CLI short answer (${#ANS_SHORT} characters): exit $cli_rc: $(printf '%s' "$cli_out" | cut -c1-200 | tr '\n' ' ')"
assert_eq "the shorter answer is accepted (exit 0)" "$cli_rc" "0"
wait_status "$QO" answered 20
assert_eq "$QO is answered" "$(q_field "$QO" status)" "answered"
if [ "$QB_AGENT" = claude ]; then qev_until RunSteerDelivered 45 "$QO"; else QEV_OUT=$(qev "$QO"); fi
ev_o2=$QEV_OUT; printf '%s\n' "$ev_o2" > "$WORK/question-events-over-2.jsonl"
assert_eq "QuestionAnswered of $QO is the short answer (SHA-256)" "$(ev_first "$ev_o2" QuestionAnswered text_sha256)" "$(sha256_of "$ANS_SHORT")"
assert_eq "...answered_by e2e" "$(ev_first "$ev_o2" QuestionAnswered answered_by)" "e2e"
if [ "$QB_AGENT" = claude ]; then
  assert_eq "the short answer was steered into the run (SHA-256 of prefix + answer)" "$(ev_first "$ev_o2" RunSteerQueued text_sha256)" "$(sha256_of "Answer to your question $QO: $ANS_SHORT")"
  assert_eq "RunSteerDelivered was recorded for it" "$(ev_count "$ev_o2" RunSteerDelivered)" "1"
else
  unverified "run.steer of the short answer" "QB_AGENT=none: the task has no run"
fi

# ---------------------------------------------------------------- the agent acted on both answers

if [ "$QB_AGENT" = claude ]; then
  say "the agent acts on what it was told"
  if wait_run_terminal; then note "run $RUN is $RUN_STATUS"; else fail "run $RUN did not end within $E2E_RUN_TIMEOUT s (status $RUN_STATUS)"; fi
  assert_eq "the run completed" "$RUN_STATUS" "completed"
  BRANCH="foreman/$TASK/$RUN"
  note "branch $BRANCH: $(git -C "$REPO" ls-tree -r --name-only "$BRANCH" 2>&1 | tr '\n' ' ')"
  got_e=$(git -C "$REPO" show "$BRANCH:answer-exact.txt" 2>&1)
  got_s=$(git -C "$REPO" show "$BRANCH:answer-short.txt" 2>&1)
  assert_content_exactly "the agent obeyed the LAST sentence of the $MAX_E-character answer (answer-exact.txt on the run's branch)" "$got_e" "BOUNDARY-EXACT-OK"
  assert_content_exactly "the agent obeyed the shorter answer (answer-short.txt)" "$got_s" "BOUNDARY-SHORT-OK"
  assert_eq "answer-over.txt does not exist (the refused answer never reached the agent)" "$(git -C "$REPO" ls-tree -r --name-only "$BRANCH" 2>/dev/null | grep -c '^answer-over.txt$')" "0"
  # what the agent's own claude session shows it received: every string in a session file that contains the steer's prefix, from the prefix on
  sf=$(claude_session_files | tr '\n' ' ')
  seen=""; seen_file=""; seen_files=0
  for f in $sf; do
    got=$(jq -rs --arg p "Answer to your question $QE:" '[.[] | .. | strings | select(contains($p))] | map(. as $s | $s[($s | index($p)):]) | sort_by(length) | last // empty' "$f" 2>/dev/null)
    [ -n "$got" ] || continue
    seen_files=$((seen_files + 1))
    if [ ${#got} -gt ${#seen} ]; then seen=$got; seen_file=$f; fi
  done
  note "claude session files: $(echo $sf | wc -w | tr -d ' '); $seen_files of them hold the message starting 'Answer to your question $QE:' (the longest is $(printf '%s' "${#seen}") characters from the prefix on)"
  assert_eq "the agent's own claude session holds the whole $STEER_CAP-character steer (first $STEER_CAP characters, SHA-256)" "$(sha256_of "${seen:0:$STEER_CAP}")" "$exp_steer_sha"
  # claude may add text of its own AFTER the steer inside the same record (reminders): what it is gets recorded, it is not asserted away or on
  note "claude's record of that message has $((${#seen} - STEER_CAP)) characters after the steer; they begin: '$(printf '%s' "${seen:$STEER_CAP:200}" | tr '\n' ' ')'"
  if [ -n "$seen_file" ]; then
    cp "$seen_file" "$WORK/claude-session-with-steer.jsonl"
    note "where the record sits in the session file: $(jq -rs --arg p "Answer to your question $QE:" '[to_entries[] | .key as $l | .value as $o | [$o | paths(type == "string")] as $ps | $ps[] as $path | select(($o | getpath($path)) | contains($p)) | "line \($l + 1) \($path | map(tostring) | join("."))"] | first // empty' "$seen_file" 2>/dev/null)"
  fi
  calls=$(for f in $sf; do claude_tool_calls "$f"; done)
  note "the agent made $(printf '%s\n' "$calls" | grep -c .) tool calls: $(printf '%s\n' "$calls" | jq -r '.name' 2>/dev/null | sort | uniq -c | tr -s ' ' | tr '\n' ',')"
  writes=$(printf '%s\n' "$calls" | jq -c 'select((.input | tostring) | test("answer-(exact|short)")) | {name, what: ((.input.file_path // .input.command // "") | .[0:140])}' 2>/dev/null | head -n 6)
  note "tool calls naming the answer files: $(printf '%s' "$writes" | tr '\n' ' ')"
fi

note "screenshots: $(ls "$SHOT_DIR" 2>/dev/null | tr '\n' ' ')"
summary
exit $?
