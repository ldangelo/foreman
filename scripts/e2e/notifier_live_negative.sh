#!/usr/bin/env bash
# scripts/e2e/notifier_live_negative.sh
#
# Live NEGATIVE-path proof (bead foreman-mivo7, audit capability C12) that the Telegram and Slack notification providers
# talk to the REAL hosts, classify what comes back and keep their secrets out of every durable surface, using
# DELIBERATELY FAKE credentials. It runs a real, throwaway Foreman server (own port, own database, own HOME) twice:
#
#   telegram   FOREMAN_NOTIFY_TELEGRAM_BOT_TOKEN=<random 10 digits>:<random 35 characters>
#              FOREMAN_NOTIFY_TELEGRAM_CHAT_ID=<random fake chat id>      -> https://api.telegram.org/bot<token>/sendMessage
#   slack      FOREMAN_NOTIFY_SLACK_WEBHOOK_URL=https://hooks.slack.com/services/T00000000/B00000000/<random 24 characters>
#
# WHAT IT DOES NOT PROVE: a delivery. No message is ever delivered to anyone: no Telegram bot, chat, Slack workspace or
# webhook of the owner is involved, and every value above is invented per run. The happy path (a 200 from Telegram, "ok"
# from Slack, the text arriving in a real chat) still needs the owner's credentials and stays open under foreman-mivo7;
# the audit row C12 does not become DONE on this evidence.
#
# WHAT IT PROVES (real TLS, real DNS, real status classification, real redaction; each lettered check prints PASS/FAIL):
#   (a) boot refusals: a half-set Telegram pair (token only, chat id only) and a mix of two providers abort `mix run` with
#       the documented message, which names the variables and never a value; the full pair boots config-wise (control).
#   (b) per provider, one event that maps to a notification is forced WITHOUT any model or agent call: a run of the
#       scratch workflow `broken-model` (a pi phase whose model does not exist) fails at the kickoff preflight, which only
#       lists pi's local model catalogue, and records `RunFailed` (mapping row `RunFailed` -> class failure). The event store
#       then holds NotificationEnqueued, NotificationDeliveryAttempted and NotificationDeliveryFailed for that run, with
#       `retryable?` false and a reason `telegram_http_401: ...` (the real api.telegram.org answers a fake token 401
#       Unauthorized) or `slack_http_404: ...` (the real hooks.slack.com answers a fake webhook 404, observed `no_team`), and
#       never a NotificationDeliverySucceeded and no retry.
#   (c) the secrets: the fake token / webhook URL (and the chat id, the secret path segment) occur ZERO times in the whole
#       events table, the server stdout log, the server's file logs, every other file of the work dir, a whole-database
#       pg_dump and the `/api/doctor` answer. Positive controls prove the searches can see: the run id MUST be found in the
#       events table and the server log, the readiness marker in the log.
#   (d) `/api/doctor` shows the notifier row naming the provider ("Notifications are on (telegram)") and no destination
#       (no secret, no host name).
#   (e) the local webhook sink the shared harness starts stays empty (the notifier has ONE provider; the harness's own
#       webhook variables are blanked for this script).
#
# A reason other than the two above (for example a network that cannot reach the hosts: `{:failed_connect, ...}`, which is
# retryable) is a FAIL printed with the reason, not an UNVERIFIED: the script needs outbound HTTPS to api.telegram.org and
# hooks.slack.com. Statuses are the REAL hosts' answers at run time: if Telegram or Slack change what a fake credential
# gets, this script reports the new answer as a FAIL with the reason text.
#
# Run (devbox shell, like the other live harnesses):   devbox run -- bash scripts/e2e/notifier_live_negative.sh
# Needs: git jq curl psql go elixir mix python3 br pi on PATH (lib.sh check_environment), pg_dump (else the whole-database
#   sweep is UNVERIFIED), Postgres on E2E_PG_HOST:E2E_PG_PORT (default localhost:55432, postgres/postgres), outbound HTTPS.
# Environment (all optional): E2E_PORT (4860), E2E_HOOK_PORT (4960), E2E_WORK_DIR (default
#   <repo>/tmp/e2e-notifier-live-negative, never /tmp), E2E_DB_NAME (foreman_e2e_notifier_live_negative), E2E_API_TOKEN,
#   E2E_RUN_TIMEOUT (seconds for the run to fail, default 180), E2E_DELIVERY_WAIT (seconds to wait for the delivery
#   outcome, default 90), E2E_KEEP=1 (keep stack for a post-mortem), E2E_EVIDENCE=always|0, E2E_TRANSCRIPT=<file>.
# Expected runtime: 3-6 minutes warm (go build, DB migrate, two server boots, two failing runs, byte searches).
# Exit: 0 all passed, 1 environment problem, 2 setup failed, 3 one or more assertions FAILED.
#   PASS        observed and as expected.
#   FAIL        observed and wrong (the evidence is printed, with every secret value replaced by <fake ...>).
#   UNVERIFIED  could not be observed on this run (a missing pg_dump, an unreadable events dump); never a pass.
# A failing run's kept evidence (tmp/e2e-evidence/nln-*/) is scrubbed by nothing: the secrets in it are fakes, but if a
# leak is the failure, the fake sits in that evidence too. Never put a real credential into this script's environment.

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
E2E_NAME=${E2E_NAME:-nln}
E2E_WORK_DIR=${E2E_WORK_DIR:-$ROOT/tmp/e2e-notifier-live-negative}
E2E_DB_NAME=${E2E_DB_NAME:-foreman_e2e_notifier_live_negative}
E2E_PORT=${E2E_PORT:-4860}
E2E_HOOK_PORT=${E2E_HOOK_PORT:-4960}
E2E_RUN_TIMEOUT=${E2E_RUN_TIMEOUT:-180}
E2E_DELIVERY_WAIT=${E2E_DELIVERY_WAIT:-90}

# The harness blanks its own webhook (one provider per node) and never runs a reviewer agent.
BASE_EXTRA="E2E_REVIEW_ANALYSIS=0 FOREMAN_NOTIFY_WEBHOOK_URL= FOREMAN_NOTIFY_WEBHOOK_ALLOW_INSECURE_HTTP= FOREMAN_NOTIFY_WEBHOOK_ALLOW_PRIVATE_HOSTS="

# The fake credentials, random per run (never a value that could be real, never written into the repository).
rand_alnum() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1"; }
rand_digits() { LC_ALL=C tr -dc '0-9' </dev/urandom | head -c "$1"; }
TG_ID_PART="9$(rand_digits 9)"
TG_SECRET_PART=$(rand_alnum 35)
TG_TOKEN="$TG_ID_PART:$TG_SECRET_PART"
TG_CHAT="-100$(rand_digits 10)"
SL_SECRET=$(rand_alnum 24)
SL_IDS="T00000000/B00000000"
SL_URL="https://hooks.slack.com/services/$SL_IDS/$SL_SECRET"
[ "${#TG_SECRET_PART}" -eq 35 ] && [ "${#SL_SECRET}" -eq 24 ] && [ "${#TG_ID_PART}" -eq 10 ] && [ "${#TG_CHAT}" -eq 14 ] \
  || { echo "fatal: could not generate the fake credentials" >&2; exit 2; }
export TG_TOKEN TG_CHAT SL_URL

# shellcheck source=claude_projects/lib.sh
. "$HERE/claude_projects/lib.sh"

OUT="$WORK/out"
SERVER_FILE_LOGS="$WORK/home/.foreman/logs"
EVENTS_FILE=""

# scrub <text>: every fake value replaced by a label, so no line printed or kept here repeats a secret
scrub() {
  printf '%s' "$1" | sed -e "s|$SL_URL|<fake slack url>|g" -e "s|$TG_TOKEN|<fake telegram token>|g" \
    -e "s|$TG_SECRET_PART|<fake token secret>|g" -e "s|$SL_SECRET|<fake slack secret>|g" -e "s|$TG_CHAT|<fake chat id>|g"
}

check_environment
install_traps

# ---------------------------------------------------------------- helpers

# text_count <value> <text>: occurrences of the value in the text
text_count() { printf '%s' "$2" | grep -aoF -- "$1" | wc -l | tr -d ' '; }

# file_count <value> <file...>: occurrences in the files (0 for one that does not exist)
file_count() {
  fc_v=$1; shift; fc_t=0
  for fc_f in "$@"; do
    [ -f "$fc_f" ] || continue
    fc_n=$(grep -aoF -- "$fc_v" "$fc_f" 2>/dev/null | wc -l | tr -d ' ')
    fc_t=$((fc_t + ${fc_n:-0}))
  done
  echo "$fc_t"
}

# tree_count <value> <exclude dir>: occurrences in every file under the work dir except the exclude dir; HIT_LINES = file: count
tree_count() {
  tc_t=0; HIT_LINES=""
  while IFS= read -r -d '' tc_f; do
    tc_n=$(grep -aoF -- "$1" "$tc_f" 2>/dev/null | wc -l | tr -d ' ')
    if [ "${tc_n:-0}" -gt 0 ]; then
      tc_t=$((tc_t + tc_n))
      HIT_LINES="$HIT_LINES $tc_f:$tc_n"
    fi
  done < <(find "$WORK" -path "$2" -prune -o -type f -print0)
  echo "$tc_t"
}

# events_dump <file>: every event of the event store, decoded, one JSON object per line (event_store_dump.exs on the server node)
events_dump() {
  rpc "$(cat "$ASSETS/event_store_dump.exs")" | grep '^EVIDENCE ' | cut -c10- > "$1"
  [ -s "$1" ]
}

# psql_db <args...>: psql against the harness database
psql_db() { psql -X -q -At -v ON_ERROR_STOP=1 -h "$E2E_PG_HOST" -p "$E2E_PG_PORT" -U "$E2E_PG_USER" -d "$E2E_DB_NAME" "$@"; }

DB_DATA_TYPE=""
# db_events_count <value>: rows of the events table whose data or metadata bytes contain the value (empty when the query fails)
db_events_count() {
  if [ -z "$DB_DATA_TYPE" ]; then
    DB_DATA_TYPE=$(psql_db -c "select data_type from information_schema.columns where table_name = 'events' and column_name = 'data'" 2>"$OUT/psql.err")
  fi
  [ -n "$DB_DATA_TYPE" ] || return 1
  if [ "$DB_DATA_TYPE" = bytea ]; then
    dec_sql="select count(*) from events where position(convert_to(:'v', 'UTF8') in data) > 0 or position(convert_to(:'v', 'UTF8') in metadata) > 0;"
  else
    dec_sql="select count(*) from events where data::text like '%' || :'v' || '%' or metadata::text like '%' || :'v' || '%';"
  fi
  printf '%s\n' "$dec_sql" | psql_db -v "v=$1" 2>"$OUT/psql.err"
}

# api_doctor -> DOCTOR_JSON ($WORK/out/doctor-<label>.json), the HTTP status in DOCTOR_CODE
api_doctor() {
  DOCTOR_FILE="$OUT/doctor-$1.json"
  DOCTOR_CODE=$(curl -sS -o "$DOCTOR_FILE" -w '%{http_code}' --max-time 30 -H "authorization: Bearer $E2E_API_TOKEN" "$API/api/doctor" 2>"$OUT/doctor.err")
}

# server_boot_env <var=value ...> -> runs `mix run --no-start -e ':ok'` the way start_server boots, BUT never starts the app
# or a port: runtime.exs is read and raises (or not) before anything runs. Output in $OUT/boot.out, status in BOOT_RC.
boot_probe() {
  (
    cd "$SERVER_DIR" || exit 2
    env -u CLAUDECODE -u CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS -u MY_ANTHROPIC_API_KEY -u ANTHROPIC_API_KEY \
      MIX_ENV=dev DATABASE_URL="$DATABASE_URL" SHELL=/bin/sh \
      HOME="$WORK/home" MIX_HOME="${MIX_HOME:-$REAL_HOME/.mix}" HEX_HOME="${HEX_HOME:-$REAL_HOME/.hex}" \
      PATH="$PATH" FOREMAN_API_TOKEN="$E2E_API_TOKEN" "$@" \
      mix run --no-start -e ':ok'
  ) >"$OUT/boot.out" 2>&1
  BOOT_RC=$?
}

# boot_refusal <what> <expected text> <forbidden values, '|'-separated> <var=value ...>: the boot must fail with the text
boot_refusal() {
  br_what=$1; br_text=$2; br_forbidden=$3; shift 3
  boot_probe "$@"
  br_head=$(scrub "$(grep -E '\*\* \(|must be set together|more than one provider' "$OUT/boot.out" | head -n 3 | cut -c1-400)")
  note "$br_what: exit status $BOOT_RC; error text: ${br_head:-<none>}"
  if [ "$BOOT_RC" -ne 0 ]; then pass "$br_what: boot aborted (exit $BOOT_RC)"; else fail "$br_what: boot did NOT abort"; fi
  if grep -qF -- "$br_text" "$OUT/boot.out"; then pass "$br_what: the documented error text is printed ('$br_text')"; else fail "$br_what: error text '$br_text' not found; output: $(scrub "$(head -c 600 "$OUT/boot.out")")"; fi
  IFS='|' read -r -a br_list <<< "$br_forbidden"
  for br_v in "${br_list[@]}"; do
    br_n=$(file_count "$br_v" "$OUT/boot.out")
    if [ "$br_n" -eq 0 ]; then pass "$br_what: no secret value in the error output"; else fail "$br_what: a secret value occurs $br_n time(s) in the error output"; fi
  done
}

# run_failed_run <label> -> RUN: submits a broken-model run (no model call) and waits for it to FAIL
failing_run() {
  FR_TASK="nln-$1-$SUFFIX"
  if ! fm run submit --project-id "$PROJECT" --workflow broken-model --work-id "$FR_TASK" --prompt "notifier live negative probe: no model is ever called" >"$OUT/submit-$1.out" 2>&1; then
    fail "$1: run submit refused: $(cut -c1-300 "$OUT/submit-$1.out")"
    RUN=""
    return 1
  fi
  fr_n=0; RUN=""
  while [ -z "$RUN" ] && [ "$fr_n" -lt 120 ]; do
    RUN=$(api_get "/api/runs?project_id=$PROJECT" | jq -r --arg t "$FR_TASK" '[.runs[]? | select(.task_id == $t)][0].run_id // empty' 2>/dev/null)
    [ -n "$RUN" ] || { sleep 2; fr_n=$((fr_n + 2)); }
  done
  if [ -z "$RUN" ]; then fail "$1: no run appeared for task $FR_TASK within 120s"; return 1; fi
  note "$1: run $RUN (task $FR_TASK)"
  fr_start=$(date +%s); RUN_STATUS=""
  while :; do
    RUN_STATUS=$(api_get "/api/runs/$RUN" | jq -r '.run.status // empty' 2>/dev/null)
    case "$RUN_STATUS" in completed|failed|cancelled) break ;; esac
    [ "$(elapsed "$fr_start")" -lt "$E2E_RUN_TIMEOUT" ] || break
    sleep "$E2E_POLL_SECS"
  done
  note "$1: run $RUN ended '$RUN_STATUS' after $(elapsed "$fr_start")s; failure_reason: $(api_get "/api/runs/$RUN" | jq -c '.run.failure_reason // null' 2>/dev/null | cut -c1-300)"
  if [ "$RUN_STATUS" = failed ]; then pass "$1: the broken-model run FAILED (no model call: kickoff preflight)"; else fail "$1: the run ended '$RUN_STATUS', expected failed"; return 1; fi
}

# wait_delivery_outcome <run id> <provider>: bounded poll of the event store for the run's terminal notification event
# -> EVENTS_FILE (the last dump). 0 once a NotificationDeliveryFailed or ...Succeeded of the run exists.
wait_delivery_outcome() {
  wd_start=$(date +%s)
  while :; do
    if events_dump "$EVENTS_FILE"; then
      wd_n=$(jq -s --arg r "$1" '[.[] | select((.type == "NotificationDeliveryFailed" or .type == "NotificationDeliverySucceeded") and .data.run_id == $r)] | length' "$EVENTS_FILE" 2>/dev/null)
      [ "${wd_n:-0}" -ge 1 ] && return 0
    fi
    [ "$(elapsed "$wd_start")" -lt "$E2E_DELIVERY_WAIT" ] || return 1
    sleep 2
  done
}

# ---------------------------------------------------------------- the per-provider stage

# provider_stage <label: telegram|slack> <reason prefix: telegram_http_401|slack_http_404> <values to hunt, '|'-separated>
provider_stage() {
  ps_label=$1; ps_reason=$2; ps_values=$3
  say "stage $ps_label: real host, fake credentials, one forced RunFailed"
  EVENTS_FILE="$OUT/events-$ps_label.jsonl"

  api_doctor "$ps_label-before"
  ps_title=$(jq -r '[.checks[]? | select(.id == "notifier")][0].title // empty' "$DOCTOR_FILE" 2>/dev/null)
  note "doctor notifier row before: $(scrub "$(jq -c '[.checks[]? | select(.id == "notifier")][0] // null' "$DOCTOR_FILE" 2>/dev/null)")"
  assert_eq "$ps_label: /api/doctor answers HTTP 200" "$DOCTOR_CODE" "200"
  assert_eq "$ps_label: doctor notifier row names the provider" "$ps_title" "Notifications are on ($ps_label)"

  if ! failing_run "$ps_label"; then return 0; fi
  ps_run=$RUN

  if ! wait_delivery_outcome "$ps_run" "$ps_label"; then
    fail "$ps_label: no NotificationDeliveryFailed/Succeeded for run $ps_run within ${E2E_DELIVERY_WAIT}s; the run's notification events: $(jq -c --arg r "$ps_run" 'select((.type | startswith("Notification")) and .data.run_id == $r) | {type, provider: .data.provider}' "$EVENTS_FILE" 2>/dev/null | tr '\n' ' ' | cut -c1-400)"
    return 0
  fi
  # a retryable failure would be retried: leave room for one (and for a stray second delivery), then take the final dump
  sleep 12
  events_dump "$EVENTS_FILE" || { unverified "$ps_label: events" "the event store dump failed"; return 0; }

  ps_ev() { jq -c --arg r "$ps_run" --arg t "$1" 'select(.type == $t and .data.run_id == $r)' "$EVENTS_FILE"; }
  ps_enq=$(ps_ev NotificationEnqueued | wc -l | tr -d ' ')
  ps_att=$(ps_ev NotificationDeliveryAttempted | wc -l | tr -d ' ')
  ps_fail=$(ps_ev NotificationDeliveryFailed | wc -l | tr -d ' ')
  ps_ok=$(ps_ev NotificationDeliverySucceeded | wc -l | tr -d ' ')
  note "$ps_label run $ps_run: enqueued=$ps_enq attempted=$ps_att failed=$ps_fail succeeded=$ps_ok"
  ps_ev NotificationEnqueued | jq -c '{event_class: .data.event_class, provider: .data.provider, subject: .data.subject}' 2>/dev/null | head -n 3 | while IFS= read -r l; do note "enqueued: $(scrub "$l")"; done
  ps_ev NotificationDeliveryFailed | jq -c '{provider: .data.provider, retryable: .data["retryable?"], reason: .data.reason}' 2>/dev/null | head -n 3 | while IFS= read -r l; do note "failed:   $(scrub "$l" | cut -c1-400)"; done

  assert_eq "$ps_label: the RunFailed became exactly one NotificationEnqueued (class failure)" "$ps_enq/$(ps_ev NotificationEnqueued | jq -r '.data.event_class' | sort -u | tr '\n' ',')" "1/failure,"
  assert_eq "$ps_label: one delivery attempt reached the provider" "$ps_att" "1"
  assert_eq "$ps_label: one NotificationDeliveryFailed" "$ps_fail" "1"
  assert_eq "$ps_label: no NotificationDeliverySucceeded (no delivery happened)" "$ps_ok" "0"
  assert_eq "$ps_label: the failed event carries provider $ps_label" "$(ps_ev NotificationDeliveryFailed | jq -r '.data.provider' | head -n 1)" "$ps_label"
  assert_eq "$ps_label: retryable? is false (no redelivery)" "$(ps_ev NotificationDeliveryFailed | jq -r '.data["retryable?"]' | head -n 1)" "false"
  ps_reason_text=$(ps_ev NotificationDeliveryFailed | jq -r '.data.reason' | head -n 1)
  case "$ps_reason_text" in
    "$ps_reason"*) pass "$ps_label: reason is classified '$ps_reason' (real host answered; reason text: $(scrub "$ps_reason_text" | cut -c1-200))" ;;
    *) fail "$ps_label: reason is '$(scrub "$ps_reason_text" | cut -c1-300)', expected it to start with $ps_reason" ;;
  esac

  # ---- (d) doctor after the failed delivery
  api_doctor "$ps_label-after"
  note "doctor notifier row after: $(scrub "$(jq -c '[.checks[]? | select(.id == "notifier")][0] // null' "$DOCTOR_FILE" 2>/dev/null)")"
  assert_eq "$ps_label: doctor notifier row still names the provider" "$(jq -r '[.checks[]? | select(.id == "notifier")][0].title // empty' "$DOCTOR_FILE" 2>/dev/null)" "Notifications are on ($ps_label)"
  for dv in api.telegram.org hooks.slack.com; do
    assert_eq "$ps_label: doctor answer holds no destination host '$dv'" "$(file_count "$dv" "$DOCTOR_FILE")" "0"
  done

  # ---- (e) the sink stayed empty
  assert_eq "$ps_label: the local webhook sink received nothing (one provider per node)" "$([ -s "$HOOK_CAPTURE" ] && wc -l < "$HOOK_CAPTURE" | tr -d ' ' || echo 0)" "0"

  # ---- (c) byte search of every durable surface
  say "$ps_label: byte search for the fake secrets (positive controls first)"
  ctl=$(db_events_count "$ps_run")
  if [ -n "$ctl" ] && [ "$ctl" -ge 1 ]; then pass "control: the run id is found in the events table ($ctl rows): the SQL search can see"
  else fail "control: the run id $ps_run is NOT found in the events table (result '${ctl:-query failed: $(head -c 200 "$OUT/psql.err" | tr '\n' ' ')}'): the search cannot be trusted"; fi
  ctl=$(file_count "$ps_run" "$SERVER_LOG")
  if [ "$ctl" -ge 1 ]; then pass "control: the run id is found in the server stdout log ($ctl hits): the log search can see"
  else fail "control: the run id is NOT found in the server stdout log: the log search cannot be trusted"; fi
  ctl=$(file_count "E2E-SERVER-READY" "$SERVER_LOG")
  [ "$ctl" -ge 1 ] && pass "control: readiness marker found in the server log" || fail "control: no readiness marker in the server log"
  note "server stdout log: $SERVER_LOG ($(wc -c < "$SERVER_LOG" | tr -d ' ') bytes); file logs under $SERVER_FILE_LOGS: $(find "$SERVER_FILE_LOGS" -type f 2>/dev/null | wc -l | tr -d ' ') file(s)"

  IFS='|' read -r -a ps_list <<< "$ps_values"
  for sv in "${ps_list[@]}"; do
    case "$sv" in
      "$TG_TOKEN") tag="fake telegram token" ;;
      "$TG_SECRET_PART") tag="fake telegram token secret part" ;;
      "$TG_CHAT") tag="fake telegram chat id" ;;
      "$SL_URL") tag="fake slack webhook URL" ;;
      "$SL_SECRET") tag="fake slack webhook secret segment" ;;
      "$SL_IDS") tag="fake slack team/bot ids" ;;
      *) tag="fake value" ;;
    esac
    n=$(db_events_count "$sv")
    if [ -z "$n" ]; then unverified "$tag in the events table" "query failed: $(head -c 200 "$OUT/psql.err" | tr '\n' ' ')"
    elif [ "$n" -eq 0 ]; then pass "$tag: 0 rows of the events table (data and metadata bytes of every event)"
    else fail "$tag LEAKED into $n row(s) of the events table: $(printf '%s\n' "select e.event_type || ' x' || count(*) from events e where position(convert_to(:'v', 'UTF8') in e.data) > 0 or position(convert_to(:'v', 'UTF8') in e.metadata) > 0 group by 1;" | psql_db -v "v=$sv" 2>/dev/null | tr '\n' ' ')"; fi
    n=$(file_count "$sv" "$SERVER_LOG")
    if [ "$n" -eq 0 ]; then pass "$tag: 0 hits in the server stdout log"; else fail "$tag LEAKED into the server stdout log: $n hit(s)"; fi
    n=$(tree_count "$sv" "$OUT")
    if [ "$n" -eq 0 ]; then pass "$tag: 0 hits in every file under the work dir (server logs, file logs, webhook capture, repo, ...; harness out/ excluded)"
    else fail "$tag LEAKED into the work dir: $n hit(s):$HIT_LINES"; fi
    n=$(file_count "$sv" "$DOCTOR_FILE" "$OUT/doctor-$ps_label-before.json")
    if [ "$n" -eq 0 ]; then pass "$tag: 0 hits in the /api/doctor answers"; else fail "$tag LEAKED into /api/doctor: $n hit(s)"; fi
  done

  if command -v pg_dump >/dev/null 2>&1; then
    PGPASSWORD=$E2E_PG_PASSWORD pg_dump -h "$E2E_PG_HOST" -p "$E2E_PG_PORT" -U "$E2E_PG_USER" -d "$E2E_DB_NAME" --format=plain --no-owner >"$OUT/dump-$ps_label.sql" 2>"$OUT/pg_dump.err"
    if [ -s "$OUT/dump-$ps_label.sql" ]; then
      for sv in "${ps_list[@]}"; do
        # bytea columns dump as \x hex: search the value's hex too
        hexv=$(printf '%s' "$sv" | od -An -v -tx1 | tr -d ' \n')
        n=$(file_count "$sv" "$OUT/dump-$ps_label.sql"); nh=$(file_count "$hexv" "$OUT/dump-$ps_label.sql")
        if [ "$n" -eq 0 ] && [ "$nh" -eq 0 ]; then pass "$ps_label: a $(printf '%s' "$sv" | wc -c | tr -d ' ')-character fake value: 0 hits (text and hex) in a whole-database pg_dump ($(wc -c < "$OUT/dump-$ps_label.sql" | tr -d ' ') bytes)"
        else fail "$ps_label: a fake value LEAKED into the whole-database dump: $n text hit(s), $nh hex hit(s)"; fi
      done
      ctl=$(file_count "$ps_run" "$OUT/dump-$ps_label.sql")
      [ "$ctl" -ge 1 ] && pass "control: the run id is found in the dump ($ctl hits)" || fail "control: the run id is NOT found in the whole-database dump"
      rm -f "$OUT/dump-$ps_label.sql"
    else
      unverified "$ps_label: whole-database dump" "pg_dump produced nothing: $(head -c 200 "$OUT/pg_dump.err" | tr '\n' ' ')"
    fi
  else
    unverified "$ps_label: whole-database dump" "pg_dump is not on PATH"
  fi
}

# ---------------------------------------------------------------- stack + telegram stage

say "setup: scratch repo, database, server with FAKE Telegram credentials (webhook blanked)"
E2E_EXTRA_ENV="$BASE_EXTRA FOREMAN_NOTIFY_TELEGRAM_BOT_TOKEN=$TG_TOKEN FOREMAN_NOTIFY_TELEGRAM_CHAT_ID=$TG_CHAT"
setup_stack
mkdir -p "$OUT"
register_project || { cat "$WORK/project-create.out"; die "project create failed" 2; }
note "project $PROJECT registered; API $API; the Telegram and Slack values are random fakes (never printed)"

provider_stage telegram telegram_http_401 "$TG_TOKEN|$TG_SECRET_PART|$TG_CHAT"

# ---------------------------------------------------------------- slack stage (same database, server restarted)

say "restart: server with a FAKE Slack webhook URL (Telegram variables removed)"
stop_server
E2E_EXTRA_ENV="$BASE_EXTRA FOREMAN_NOTIFY_SLACK_WEBHOOK_URL=$SL_URL"
start_server
provider_stage slack slack_http_404 "$SL_URL|$SL_SECRET|$SL_IDS"
# a Telegram value must not have followed the restart into the Slack stage's surfaces either
n=$(db_events_count "$TG_SECRET_PART")
if [ -n "$n" ] && [ "$n" -eq 0 ]; then pass "the telegram secret is still 0 rows of the events table after the slack stage"; else fail "telegram secret in the events table after the slack stage: '${n:-query failed}'"; fi

# ---------------------------------------------------------------- (a) boot refusals

say "(a) boot refusals: half-set Telegram pair, two providers; the full pair as the control"
stop_server
boot_refusal "token without chat id" "FOREMAN_NOTIFY_TELEGRAM_BOT_TOKEN and FOREMAN_NOTIFY_TELEGRAM_CHAT_ID must be set together" "$TG_TOKEN|$TG_SECRET_PART" \
  "FOREMAN_NOTIFY_TELEGRAM_BOT_TOKEN=$TG_TOKEN"
boot_refusal "chat id without token" "FOREMAN_NOTIFY_TELEGRAM_BOT_TOKEN and FOREMAN_NOTIFY_TELEGRAM_CHAT_ID must be set together" "$TG_CHAT" \
  "FOREMAN_NOTIFY_TELEGRAM_CHAT_ID=$TG_CHAT"
boot_refusal "telegram pair plus slack URL" "notification variables for more than one provider are set" "$TG_TOKEN|$TG_SECRET_PART|$TG_CHAT|$SL_URL|$SL_SECRET" \
  "FOREMAN_NOTIFY_TELEGRAM_BOT_TOKEN=$TG_TOKEN" "FOREMAN_NOTIFY_TELEGRAM_CHAT_ID=$TG_CHAT" "FOREMAN_NOTIFY_SLACK_WEBHOOK_URL=$SL_URL"
boot_probe "FOREMAN_NOTIFY_TELEGRAM_BOT_TOKEN=$TG_TOKEN" "FOREMAN_NOTIFY_TELEGRAM_CHAT_ID=$TG_CHAT"
if [ "$BOOT_RC" -eq 0 ]; then pass "control: the full Telegram pair loads (exit 0): the refusals above are about the missing half, not the harness"
else fail "control: the full Telegram pair did not load (exit $BOOT_RC): $(scrub "$(head -c 400 "$OUT/boot.out")")"; fi

summary
exit $?
