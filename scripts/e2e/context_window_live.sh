#!/usr/bin/env bash
# Live acceptance of the claude CLI's context window for a GATEWAY model, through real Foreman workflow runs
# (bead foreman-gppjx, docs/acceptance/context-window-live-run.md; the zero-spend half is scripts/e2e/context_window_probe.sh).
#
#   CW_LITELLM_FILE=<file> devbox run -- bash scripts/e2e/context_window_live.sh
#   CW_GATEWAY=standin devbox run -- bash scripts/e2e/context_window_live.sh       # zero spend: a scripted stand-in gateway, no key
#
# THIS SPENDS MONEY in its default mode: it sends real requests to the model behind the LiteLLM proxy named in CW_LITELLM_FILE.
# CW_ABORT_TOKENS (4000000) is the ceiling for the tokens the proxy has processed for ALL real runs together, across invocations (a
# ledger, CW_LEDGER, records every run); a run is cancelled when it would cross it, and a run is not started when its expected size
# does not fit. CW_MAX_SPEND_USD (1.5) is the same ceiling for the proxy's own spend figure.
#
# CW_LITELLM_FILE (no default) is a file with two lines, `url: <proxy base url>` and `key: <key>`. The key is read INSIDE this
# process (a shell variable) and inside litellm_tool.py; it reaches Foreman on STDIN of `foreman project secret set`, never in a
# flag or in an environment variable. The script prints no value from that file. Before anything leaves the work dir the evidence is
# scanned for the key (raw, hex, URL-encoded) and a file that has it is deleted; at the end the work dir, the database dump and the
# server's process list are counted too. It refuses to run under `set -x`.
#
# One throwaway server (own port, database, scratch repo and work dir; claude_projects/lib.sh), a project whose environment carries
# ANTHROPIC_BASE_URL (plain variable) and ANTHROPIC_API_KEY (project secret), and a workflow with ONE claude phase on the gateway's alias
# (CW_MODEL, default Minimax-M3; `provider: claude`, auto_approve). The server runs with a PRIVATE HOME (stock claude settings, sessions
# under $WORK/home/.claude/projects) and context_window_live/bin/claude first on its PATH: a transparent recorder in front of the real
# CLI (what the CLI was given, and what it printed). The repository holds ballast/part-01..03.txt (context_window_live/make_ballast.py:
# about 80 KB, about 21k tokens each when read) and every run asks the agent to read the parts in order, one per tool call, and to write
# the CHECKSUM lines of the first and of the last part it read into report.txt.
#
#   smoke  one tiny POST /v1/messages with the alias spelled as the workflow spells it (the endpoint exists, the alias is accepted verbatim,
#          the reply is Anthropic-shaped, usage reports input tokens): any failure stops the script before anything is built or spent.
#   A      canary and baseline: 2 parts, CLAUDE_CODE_MAX_CONTEXT_TOKENS unset. Proves the path works for pennies and measures the base
#          request and the tokens one part adds (they size run B's hard cap).
#   B      the acceptance, ADAPTIVE: the variable is set in the PROJECT environment (`foreman project env set`) to CW_WINDOW (512000) and
#          the harness ADDS parts to the run's worktree while the agent reads, always CW_LEAD_PARTS ahead of the part being read, until the
#          claude session file (or the proxy's per-request log) shows a request above 200000 tokens: from then on it adds none, the next Read
#          answers "does not exist" and the agent finishes. The crossing is OBSERVED, not assumed from a file count; a hard cap of parts (and so of
#          bytes) keeps the context near 300000 tokens. Asserts: requests above 200000 in the session file AND in the proxy's own log, no
#          compaction record, the CLI's own result record says contextWindow=CW_WINDOW, the recorder saw the variable in the CLI's environment.
#   C      OPTIONAL (CW_STAGES="A B C" or "C"; run it only when B's outcome is ambiguous): the same corpus as B (CW_LARGE_FILES parts) with
#          the variable unset. The zero-spend probe measured that contrast for nothing; this is the same measurement through a real run.
#
# Evidence per run (claude session files as the run proceeds, recorder logs, the CLI's own result record, the proxy's per-request log,
# Foreman's UsageRecorded event, the per-request series) goes to CW_EVIDENCE_DIR (default <checkout>/tmp/context-window-live/<UTC time>)
# BEFORE any cleanup. Prints PASS / FAIL / UNVERIFIED per assertion and `passed= failed= unverified= wall=`; exit 0 all passed, 1 environment
# problem, 2 setup failed, 3 a FAIL.
#
# Environment: CW_LITELLM_FILE, CW_GATEWAY (litellm|standin), CW_PREFLIGHT_ONLY=1 (the gateway checks and the one smoke request, nothing
# else), CW_MODEL, CW_WINDOW, CW_STAGES ("A B"), CW_LARGE_FILES (C's part count), CW_PART_CAP (B's hard cap; default sized from run A for about
# 300000 tokens), CW_SMALL_FILES (2), CW_SEED_PARTS (3), CW_LEAD_PARTS (2), CW_CROSS_TOKENS (200000), CW_BALLAST_BYTES (80000),
# CW_ABORT_TOKENS, CW_MAX_SPEND_USD, CW_LEDGER, CW_RUN_TIMEOUT (2700 s), CW_GW_PORT (4975), CW_EVIDENCE_DIR, and lib.sh's (E2E_WORK_DIR,
# E2E_PORT 4835, E2E_HOOK_PORT 4935, E2E_KEEP, E2E_TRANSCRIPT, ...). Needs claude, jq, curl, python3, psql, pg_dump, br, pi, go (devbox).
#
# A rehearsal that spends nothing: CW_GATEWAY=standin starts context_window_live/fake_agent_gateway.py (a scripted "model" that reads the
# parts, writes report.txt and says done, and tells the CLI how many tokens each request "used": the CLI's compaction decision is the
# real one). The same script against a stand-in you started yourself (CW_LITELLM_FILE with `url: http://127.0.0.1:<port>` and a made-up
# key) also exercises the ledger and the bounds.
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
LIVE="$HERE/context_window_live"

case $- in *x*) echo "refusing to run with xtrace on: it would print the gateway key" >&2; exit 1 ;; esac

# the credentials file is named once and then removed from the environment, so neither the server nor any agent inherits its location
CRED_FILE=${CW_LITELLM_FILE:-}
unset CW_LITELLM_FILE
CW_GATEWAY=${CW_GATEWAY:-litellm}
CW_MODEL=${CW_MODEL:-Minimax-M3}
CW_WINDOW=${CW_WINDOW:-512000}
CW_STAGES=${CW_STAGES:-A B}
CW_SMALL_FILES=${CW_SMALL_FILES:-2}
CW_SEED_PARTS=${CW_SEED_PARTS:-3}
CW_LEAD_PARTS=${CW_LEAD_PARTS:-2}
CW_CROSS_TOKENS=${CW_CROSS_TOKENS:-200000}
CW_CAP_TOKENS=${CW_CAP_TOKENS:-300000}
CW_PART_CAP=${CW_PART_CAP:-}
CW_LARGE_FILES=${CW_LARGE_FILES:-}
CW_BALLAST_BYTES=${CW_BALLAST_BYTES:-80000}
CW_ABORT_TOKENS=${CW_ABORT_TOKENS:-4000000}
CW_MAX_SPEND_USD=${CW_MAX_SPEND_USD:-1.5}
CW_RUN_TIMEOUT=${CW_RUN_TIMEOUT:-2700}
CW_GW_PORT=${CW_GW_PORT:-4975}
CW_GW_DELAY=${CW_GW_DELAY:-3}
CW_EVIDENCE_DIR=${CW_EVIDENCE_DIR:-$ROOT/tmp/context-window-live/$(date -u +%Y%m%dT%H%M%SZ)}
CW_LEDGER=${CW_LEDGER:-$ROOT/tmp/context-window-live/spend-ledger.jsonl}
E2E_NAME=${E2E_NAME:-cwlive}
E2E_PORT=${E2E_PORT:-4835}
E2E_HOOK_PORT=${E2E_HOOK_PORT:-4935}
E2E_RUN_TIMEOUT=${E2E_RUN_TIMEOUT:-$CW_RUN_TIMEOUT}
# shellcheck source=claude_projects/lib.sh
. "$HERE/claude_projects/lib.sh"
# shellcheck source=claude_projects/claude_home.sh
. "$HERE/claude_projects/claude_home.sh"

# a variable the operator's shell exports must not decide what the runs "without the variable" do
for cw_v in ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL \
  ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL CLAUDE_CODE_MAX_CONTEXT_TOKENS CLAUDE_CODE_AUTO_COMPACT_WINDOW \
  CLAUDE_AUTOCOMPACT_PCT_OVERRIDE DISABLE_AUTO_COMPACT DISABLE_COMPACT CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT \
  CLAUDE_CONFIG_DIR CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX; do unset "$cw_v"; done

CW_TEE_DIR="$WORK/cli-tee"
CW_REAL_CLAUDE=$(command -v claude 2>/dev/null)
E2E_PATH_PREFIX="$LIVE/bin"
E2E_EXTRA_ENV="E2E_REVIEW_ANALYSIS=0 CW_REAL_CLAUDE=$CW_REAL_CLAUDE CW_TEE_DIR=$CW_TEE_DIR"
GW_PID=""
GW_URL=""
GW_KEY=""
GW_PRICE_IN=0
GW_PRICE_OUT=0
STAGE_OPEN=""       # the label of the run in flight (its tokens are ledgered even when the script dies)
STAGE_T0=""

# ---------------------------------------------------------------- helpers

# llm <litellm_tool.py arguments>: the file with the key is handed to this one child only
llm() { env CW_LITELLM_FILE="$CRED_FILE" python3 "$LIVE/litellm_tool.py" "$@"; }
jqs() { printf '%s' "$1" | jq -r "$2" 2>/dev/null; } # <json> <filter>
num() { printf '%s' "${1:-0}" | awk '{printf "%d", $1}'; }

read_credentials() { # sets GW_URL and GW_KEY; the key stays in this shell variable
  GW_URL=$(sed -n 's/^url:[[:space:]]*//p' "$CRED_FILE" | head -n 1 | tr -d '\r')
  GW_KEY=$(sed -n 's/^key:[[:space:]]*//p' "$CRED_FILE" | head -n 1 | tr -d '\r')
  [ -n "$GW_URL" ] && [ -n "$GW_KEY" ]
}

# ---- the ledger: what the real provider has been asked to process, across invocations
ledger_tokens() { if [ -s "$CW_LEDGER" ]; then jq -s '[.[] | (.prompt_tokens // 0) + (.completion_tokens // 0)] | add // 0' "$CW_LEDGER" 2>/dev/null || echo 0; else echo 0; fi; }
ledger_spend() { if [ -s "$CW_LEDGER" ]; then jq -s '[.[] | .spend // 0] | add // 0' "$CW_LEDGER" 2>/dev/null || echo 0; else echo 0; fi; }
ledger_add() { # <stage> <run> <prompt tokens> <completion tokens> <spend> <how counted>
  mkdir -p "$(dirname "$CW_LEDGER")"
  jq -nc --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg stage "$1" --arg run "$2" --argjson p "${3:-0}" --argjson c "${4:-0}" --argjson s "${5:-0}" \
    --arg how "$6" --arg evidence "$CW_EVIDENCE_DIR" \
    '{at: $at, stage: $stage, run: $run, prompt_tokens: $p, completion_tokens: $c, spend: $s, counted_from: $how, evidence: $evidence}' >> "$CW_LEDGER"
}
# ledger_stage <label> <run> <stage t0> <stage t1 or ""> <session analysis json file>: the proxy's own figures, else the session file's
ledger_stage() {
  ls_json="$CW_EVIDENCE_DIR/$1/proxy.json"
  [ -n "$4" ] || ls_json="$CW_EVIDENCE_DIR/$1/proxy-final.json"
  proxy_rows "$3" "$4" "$ls_json"
  if [ -n "$(jq -r '.count // empty' "$ls_json" 2>/dev/null)" ]; then
    ledger_add "$1" "$2" "$(num "$(jq -r '.sum_prompt_tokens' "$ls_json")")" "$(num "$(jq -r '.sum_completion_tokens' "$ls_json")")" "$(jq -r '.sum_spend' "$ls_json")" "proxy spend log"
  else
    ledger_add "$1" "$2" "$(num "$(jq -r '.sum_context // 0' "$5" 2>/dev/null)")" "$(num "$(jq -r '.sum_output // 0' "$5" 2>/dev/null)")" 0 "session file (the proxy log was unreadable)"
  fi
}

# scrub_evidence: the evidence leaves the work dir only without the key: a file that has it is deleted
scrub_evidence() {
  se_out=$(llm scan --delete "$CW_EVIDENCE_DIR" 2>&1)
  se_n=$(printf '%s\n' "$se_out" | sed -n 's/^scan total: \([0-9]*\) file.*/\1/p')
  if [ "${se_n:-0}" != 0 ]; then fail "the evidence held the key in ${se_n} file(s): $(printf '%s\n' "$se_out" | head -n 1 | cut -c1-300) (deleted)"; fi
}

# final_evidence: everything the numbers need, copied out of the work dir before the stack is torn down
final_evidence() {
  [ -d "$WORK" ] || return 0
  mkdir -p "$CW_EVIDENCE_DIR/final"
  if [ -d "$WORK/home/.claude/projects" ]; then rm -rf "$CW_EVIDENCE_DIR/final/claude-projects"; cp -R "$WORK/home/.claude/projects" "$CW_EVIDENCE_DIR/final/claude-projects" 2>/dev/null; fi
  if [ -d "$CW_TEE_DIR" ]; then rm -rf "$CW_EVIDENCE_DIR/final/cli-tee"; cp -R "$CW_TEE_DIR" "$CW_EVIDENCE_DIR/final/cli-tee" 2>/dev/null; fi
  [ -f "$SERVER_LOG" ] && cp "$SERVER_LOG" "$CW_EVIDENCE_DIR/final/server.log" 2>/dev/null
  [ -f "$WORK/gateway-requests.jsonl" ] && cp "$WORK/gateway-requests.jsonl" "$CW_EVIDENCE_DIR/final/" 2>/dev/null
  [ -n "$CRED_FILE" ] && scrub_evidence
}

cw_cleanup() { # lib.sh's cleanup, after the numbers are saved and the stand-in gateway is stopped
  cw_rc=$?
  trap - EXIT INT TERM HUP
  if [ -n "$STAGE_OPEN" ] && [ "$CW_GATEWAY" = litellm ] && [ -n "$STAGE_T0" ]; then
    # a run was in flight when the script ended: the ledger must still know what it processed
    mkdir -p "$CW_EVIDENCE_DIR/$STAGE_OPEN"
    ledger_stage "$STAGE_OPEN" "${RUN:-unknown}" "$STAGE_T0" "" "$CW_EVIDENCE_DIR/$STAGE_OPEN/analysis.json"
  fi
  final_evidence
  stop_pid "$GW_PID"
  (exit "$cw_rc")
  cleanup
}

# the gateway the runs talk to: the proxy named in CRED_FILE, or the scripted stand-in of the zero-spend rehearsal
start_standin() {
  printf '{"files": 2, "until_missing": false}\n' > "$WORK/gateway-control.json"
  python3 "$LIVE/fake_agent_gateway.py" --port "$CW_GW_PORT" --log "$WORK/gateway-requests.jsonl" --control "$WORK/gateway-control.json" \
    --window "$CW_WINDOW" --model "$CW_MODEL" --delay "$CW_GW_DELAY" >"$WORK/gateway.log" 2>&1 &
  GW_PID=$!
  for _ in $(seq 1 40); do
    curl -s -m 1 -o /dev/null "http://127.0.0.1:$CW_GW_PORT/health/liveliness" && break
    sleep 0.25
  done
  printf 'url: http://127.0.0.1:%s\nkey: standin-%s-%s\n' "$CW_GW_PORT" "$SUFFIX" "$RANDOM$RANDOM" > "$WORK/standin-credentials.txt"
  chmod 600 "$WORK/standin-credentials.txt"
  CRED_FILE="$WORK/standin-credentials.txt"
  CW_LEDGER="$WORK/ledger.jsonl"
  note "scripted stand-in gateway pid $GW_PID on 127.0.0.1:$CW_GW_PORT, answers after ${CW_GW_DELAY}s (NO provider is contacted, nothing is spent)"
}

# gateway_preflight: the proxy is up, serves the alias, declares a window big enough for the run to mean something, and takes one tiny request
gateway_preflight() {
  say "the gateway"
  gp_check=$(llm check 2>&1); gp_rc=$?
  note "health: $(jqs "$gp_check" '"liveliness \(.liveliness[0]), readiness \(.readiness[0]), \(.models | length) model aliases"')"
  assert_eq "the gateway answers /health and /v1/models (exit status of the check)" "$gp_rc" "0"
  [ "$gp_rc" = 0 ] || return 1
  gp_has=$(printf '%s' "$gp_check" | jq -r --arg m "$CW_MODEL" '.models | index($m) != null' 2>/dev/null)
  assert_eq "the gateway serves the alias $CW_MODEL" "$gp_has" "true"
  GW_INFO=$(llm model-info "$CW_MODEL" 2>&1)
  note "declared by the gateway for $CW_MODEL: $(jqs "$GW_INFO" '"max_input_tokens \(.max_input_tokens), max_output_tokens \(.max_output_tokens), $\((.input_cost_per_token // 0) * 1000000)/M input, $\((.output_cost_per_token // 0) * 1000000)/M output (the proxy config calls its prices illustrative), upstream \(.upstream_model)"')"
  GW_DECLARED_WINDOW=$(num "$(jqs "$GW_INFO" '.max_input_tokens // 0')")
  [ "$GW_DECLARED_WINDOW" -ge 300000 ] && gp_big=yes || gp_big=no
  assert_eq "the gateway declares a window of at least 300000 tokens for $CW_MODEL ($GW_DECLARED_WINDOW): below that the run would prove nothing" "$gp_big" "yes"
  [ "$gp_big" = yes ] || return 1
  GW_PRICE_IN=$(jqs "$GW_INFO" '(.input_cost_per_token // 0)')
  GW_PRICE_OUT=$(jqs "$GW_INFO" '(.output_cost_per_token // 0)')
  gp_smoke=$(llm smoke "$CW_MODEL" 2>&1); gp_rc=$?
  note "smoke (one POST /v1/messages, max_tokens 16, model $CW_MODEL): $gp_smoke"
  assert_eq "smoke: /v1/messages answers HTTP 200 for the alias spelled exactly $CW_MODEL" "$(jqs "$gp_smoke" '.status')" "200"
  assert_eq "smoke: the reply is an Anthropic message (type message, role assistant)" "$(jqs "$gp_smoke" '"\(.type) \(.role)"')" "message assistant"
  assert_eq "smoke: the reply names the model $CW_MODEL" "$(jqs "$gp_smoke" '.model')" "$CW_MODEL"
  [ "$(num "$(jqs "$gp_smoke" '.usage.input_tokens // 0')")" -gt 0 ] && gp_usage=yes || gp_usage=no
  assert_eq "smoke: the usage block reports input tokens" "$gp_usage" "yes"
  [ "$FAILED" -eq 0 ]
}

# set_window_var on|off: the variable under test, in the PROJECT environment (the route docs/user-guide.md documents)
set_window_var() {
  if [ "$1" = on ]; then
    fm project env set "$PROJECT" "CLAUDE_CODE_MAX_CONTEXT_TOKENS=$CW_WINDOW" >"$WORK/env-set.out" 2>&1 || { head -c 300 "$WORK/env-set.out"; return 1; }
  elif fm project env list --format=json "$PROJECT" 2>/dev/null | jq -e '.vars | has("CLAUDE_CODE_MAX_CONTEXT_TOKENS")' >/dev/null 2>&1; then
    fm project env unset "$PROJECT" CLAUDE_CODE_MAX_CONTEXT_TOKENS >"$WORK/env-set.out" 2>&1 || { head -c 300 "$WORK/env-set.out"; return 1; }
  fi
  note "project environment now: $(fm project env list --format=json "$PROJECT" 2>/dev/null | jq -c '.vars')"
}

part_name() { printf 'part-%02d' "$1"; }

build_prompt() { # <mode fixed|adapt> <number of parts, or the hard cap>
  if [ "$1" = fixed ]; then
    cat <<EOF
Corpus check. The directory ballast/ in the current working directory holds plain-text files named part-01.txt, part-02.txt and so on. Only the first $2 of them matter.
Step 1. Read $(part_name 1).txt through $(part_name "$2").txt IN ORDER with the Read tool: ONE file per tool call (never two files in one step), each in full (no offset, no limit). Do not use Bash, grep, head, tail, wc or any other way to look at them, and do not skip or summarise any file. After each file, reply with one short line: read part-NN.
Step 2. The last line of every part file has the form "CHECKSUM part-NN <12 hex characters>". Create the file report.txt in the current working directory holding exactly two lines: the CHECKSUM line of part-01.txt and the CHECKSUM line of $(part_name "$2").txt, each copied character for character.
Step 3. Reply with exactly: done
EOF
  else
    cat <<EOF
Corpus check. The directory ballast/ in the current working directory holds plain-text files named part-01.txt, part-02.txt and so on; more of them appear while you work, and there are never more than $2.
Step 1. Read the parts IN ORDER with the Read tool, starting with part-01.txt: ONE file per tool call (never two files in one step), each in full (no offset, no limit). Do not use Bash, grep, head, tail, wc or any other way to look at them, and do not skip or summarise any file. After each file, reply with one short line: read part-NN. Keep going until the Read of the next part tells you that the file does not exist: the corpus is then complete. Do not create part files yourself and do not look for further parts with Bash.
Step 2. The last line of every part file has the form "CHECKSUM part-NN <12 hex characters>". Create the file report.txt in the current working directory holding exactly two lines: the CHECKSUM line of part-01.txt and the CHECKSUM line of the LAST part you read, each copied character for character.
Step 3. Reply with exactly: done
EOF
  fi
}

write_gateway_workflow() {
  cat > "$WORK/workflows/claudegw.yaml" <<EOF
name: claudegw
description: Live acceptance workflow (foreman-gppjx). One claude phase on the gateway model alias $CW_MODEL; carries out the task and commits.
task_types: [claude-gw]
worktree:
  enabled: true
  branch: foreman/{task_id}/{run_id}
  path: workspace
  cleanup: on_success
phases:
  - name: edit
    prompt: edit.md
    provider: claude
    approval_mode: auto_approve
    timeout_minutes: 60
    models:
      default: $CW_MODEL
    commit: true
EOF
}

# cw_session_files: every claude session file under the private HOME, sorted (claude_home.sh's claude_session_files needs BSD stat; devbox's is GNU)
cw_session_files() { find "$WORK/home/.claude/projects" -name '*.jsonl' 2>/dev/null | sort; }
# new_session_files <file listing the session files before the run>: the session files the run added
new_session_files() {
  cw_session_files > "$WORK/sessions-now.txt"
  comm -13 "$1" "$WORK/sessions-now.txt"
}

# the gateway's own log of the requests a run made: count, max/sum prompt tokens, spend and one row per request
proxy_rows() { # <since> <until or ""> <out file>
  if [ -n "$2" ]; then llm spend "$CW_MODEL" "$1" "$2" > "$3" 2>"$3.err"; else llm spend "$CW_MODEL" "$1" > "$3" 2>"$3.err"; fi
}

# stage_cwd <the stage's tee-before listing>: the working directory of the claude process this stage's run started (its worktree)
stage_cwd() {
  for sc in $(ls -1 "$CW_TEE_DIR" 2>/dev/null | grep '^launch-' | sort | comm -13 "$1" -); do
    if grep -q '^flags=.* --print' "$CW_TEE_DIR/$sc"; then sed -n 's/^cwd=//p' "$CW_TEE_DIR/$sc" | head -n 1; return 0; fi
  done
  return 1
}

# add_parts <worktree> <from> <to>: the harness adds ballast parts to the directory the agent is reading
add_parts() {
  python3 "$LIVE/make_ballast.py" --out "$1/ballast" --first "$2" --last "$3" --bytes "$CW_BALLAST_BYTES" || return 1
  PART_LIMIT=$3
}

# cancel_run <why>: ends a run that crossed a bound
cancel_run() {
  ABORT_REASON=$1
  out "   ABORT: $1: cancelling run $RUN"
  fm run cancel --id "$RUN" --reason "context-window-live bound" >"$WORK/cancel.out" 2>&1
  cr=$(date +%s)
  while [ "$(elapsed "$cr")" -lt 90 ]; do
    RUN_STATUS=$(api_get "/api/runs/$RUN" | jq -r '.status // .run.status // empty' 2>/dev/null)
    case "$RUN_STATUS" in completed|failed|cancelled) return 0 ;; esac
    sleep 3
  done
}

# watch_run <timeout s> <t0> <stage dir> <mode none|fixed|adapt> <parts: fixed = how many, adapt = the hard cap> <token budget>
# Waits for the run to end. In `fixed` mode it adds parts 4..N at once; in `adapt` mode it adds parts as the session file shows the agent
# going, CW_LEAD_PARTS ahead, until a request is above CW_CROSS_TOKENS (then none). Cancels the run when a bound is crossed.
# Sets RUN_STATUS, ABORT_REASON, PART_LIMIT (the last part that exists) and CROSSED (the crossing request, when seen).
watch_run() {
  ww_timeout=$1; ww_t0=$2; ww_dir=$3; ww_mode=$4; ww_n=$5; ww_budget=$6
  ABORT_REASON=""; CROSSED=""; PART_LIMIT=$CW_SEED_PARTS; ww_wt=""; ww_frozen=0
  ww_start=$(date +%s); ww_st=-100; ww_px=-100; ww_pr=-100; ww_sv=-100
  while :; do
    ww_el=$(elapsed "$ww_start")
    if [ $((ww_el - ww_st)) -ge 3 ]; then
      ww_st=$ww_el
      RUN_STATUS=$(api_get "/api/runs/$RUN" | jq -r '.status // .run.status // empty' 2>/dev/null)
      case "$RUN_STATUS" in completed|failed|cancelled) return 0 ;; esac
    fi
    if [ "$ww_el" -ge "$ww_timeout" ]; then cancel_run "no terminal state after ${ww_timeout}s (last status ${RUN_STATUS:-none})"; return 0; fi
    if [ -z "$ww_wt" ]; then
      ww_wt=$(stage_cwd "$ww_dir/tee-before.txt")
      if [ -n "$ww_wt" ]; then
        note "  ${ww_el}s: the agent's worktree is $ww_wt"
        if [ "$ww_mode" = fixed ] && [ "$ww_n" -gt "$PART_LIMIT" ]; then add_parts "$ww_wt" $((PART_LIMIT + 1)) "$ww_n" && note "  ${ww_el}s: parts up to $(part_name "$ww_n") added at once (the corpus of this run is fixed)"; fi
      fi
    fi
    ww_files=$(new_session_files "$ww_dir/sessions-before.txt")
    if [ -n "$ww_files" ]; then
      # shellcheck disable=SC2086
      ww_a=$(python3 "$LIVE/session_usage.py" $ww_files 2>/dev/null)
      ww_cum=$(num "$(jqs "$ww_a" '.sum_context // 0')")
      ww_max=$(num "$(jqs "$ww_a" '.max_context // 0')")
      ww_high=$(num "$(jqs "$ww_a" '.max_part_ref // 0')")
      ww_par=$(num "$(jqs "$ww_a" '.max_reads_per_request // 1')")
      if [ "$ww_mode" = adapt ] && [ -n "$ww_wt" ] && [ "$ww_frozen" = 0 ]; then
        if [ "$ww_max" -gt "$CW_CROSS_TOKENS" ]; then
          ww_frozen=1
          CROSSED=$(printf '%s' "$ww_a" | jq -r --argjson c "$CW_CROSS_TOKENS" '[.requests[] | select(.context > $c)][0] | "request \(.n) of the session: \(.context) tokens"' 2>/dev/null)
          note "  ${ww_el}s: CROSSING OBSERVED in the session file ($CROSSED, after $ww_high part(s) requested): no part beyond $(part_name "$PART_LIMIT") will be added"
        else
          ww_lead=$((2 * ww_par)); [ "$ww_lead" -lt "$CW_LEAD_PARTS" ] && ww_lead=$CW_LEAD_PARTS # an agent that reads several parts per step needs a longer lead
          ww_want=$((ww_high + ww_lead)); [ "$ww_want" -gt "$ww_n" ] && ww_want=$ww_n
          if [ "$ww_want" -gt "$PART_LIMIT" ]; then add_parts "$ww_wt" $((PART_LIMIT + 1)) "$ww_want" && note "  ${ww_el}s: parts up to $(part_name "$PART_LIMIT") exist (the agent has asked for $(part_name "$ww_high"), largest context so far $ww_max)"; fi
        fi
      fi
      if [ $((ww_el - ww_sv)) -ge 10 ]; then # the numbers leave the work dir as the run proceeds
        ww_sv=$ww_el
        mkdir -p "$ww_dir/live"
        for ww_f in $ww_files; do cp "$ww_f" "$ww_dir/live/session-$(basename "$ww_f")" 2>/dev/null; done
        printf '%s\n' "$ww_a" > "$ww_dir/live/analysis.json"
      fi
      if [ $((ww_el - ww_pr)) -ge 20 ]; then
        ww_pr=$ww_el
        note "  ${ww_el}s: status ${RUN_STATUS:-none}, $(jqs "$ww_a" '"\(.request_count) requests, largest context \(.max_context), \(.compactions | length) compaction(s), \(.sum_context) input tokens so far"')"
      fi
      if [ "$ww_cum" -gt "$ww_budget" ]; then cancel_run "the session files report $ww_cum input tokens for this run, over its budget of $ww_budget"; return 0; fi
    fi
    if [ $((ww_el - ww_px)) -ge 10 ]; then
      ww_px=$ww_el
      proxy_rows "$ww_t0" "" "$ww_dir/proxy-watch.json"
      ww_pj=$(cat "$ww_dir/proxy-watch.json" 2>/dev/null)
      ww_p=$(num "$(jqs "$ww_pj" '(.sum_prompt_tokens // 0) + (.sum_completion_tokens // 0)')")
      ww_s=$(jqs "$ww_pj" '.sum_spend // 0')
      if [ "$ww_mode" = adapt ] && [ "$ww_frozen" = 0 ] && [ "$(num "$(jqs "$ww_pj" '.max_prompt_tokens // 0')")" -gt "$CW_CROSS_TOKENS" ]; then
        ww_frozen=1; CROSSED="a request of $(jqs "$ww_pj" '.max_prompt_tokens') prompt tokens in the gateway's own log"
        note "  ${ww_el}s: CROSSING OBSERVED at the gateway ($CROSSED): no part beyond $(part_name "$PART_LIMIT") will be added"
      fi
      if [ "$ww_p" -gt "$ww_budget" ]; then cancel_run "the gateway reports $ww_p tokens for this run, over its budget of $ww_budget"; return 0; fi
      if awk -v s="${ww_s:-0}" -v m="$(awk -v a="$CW_MAX_SPEND_USD" -v b="$LEDGER_SPEND0" 'BEGIN{print a - b}')" 'BEGIN{exit !(s > m)}'; then cancel_run "the gateway reports \$$ww_s of spend for this run, over what is left of \$$CW_MAX_SPEND_USD"; return 0; fi
    fi
    sleep 1
  done
}

# keep_processes <file>: the command lines of the server's process tree (never anyone else's), for the key scan
keep_processes() {
  { for kp in $SERVER_PID $(descendants "$SERVER_PID"); do ps -ww -o pid=,etime=,command= -p "$kp" 2>/dev/null | cut -c1-400; done; } > "$1"
}

# run_stage <label> <mode fixed|adapt> <parts (fixed) or hard cap (adapt)> <on|off> <timeout>: one Foreman claude run; everything it
# leaves behind is copied to $CW_EVIDENCE_DIR/<label>/ before the function returns
run_stage() {
  rs_label=$1; rs_mode=$2; rs_n=$3; rs_var=$4; rs_timeout=$5
  rs_dir="$CW_EVIDENCE_DIR/$rs_label"; mkdir -p "$rs_dir"
  say "run $rs_label: $([ "$rs_mode" = fixed ] && echo "$rs_n parts" || echo "adaptive ballast, at most $rs_n parts"), CLAUDE_CODE_MAX_CONTEXT_TOKENS $([ "$rs_var" = on ] && echo "=$CW_WINDOW" || echo "unset")"
  set_window_var "$rs_var" || { fail "run $rs_label: cannot set the project environment"; return 1; }
  printf '{"files": %s, "until_missing": %s}\n' "$rs_n" "$([ "$rs_mode" = adapt ] && echo true || echo false)" > "$WORK/gateway-control.json"
  cw_session_files > "$rs_dir/sessions-before.txt"
  ls -1 "$CW_TEE_DIR" 2>/dev/null | sort > "$rs_dir/tee-before.txt"
  RUN=""
  STAGE_T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  rs_t0=$STAGE_T0
  rs_start=$(date +%s)
  TASK="cw-$rs_label-$SUFFIX"
  PROMPT=$(build_prompt "$rs_mode" "$rs_n")
  printf '%s\n' "$PROMPT" > "$rs_dir/prompt.txt"
  STAGE_OPEN=$rs_label
  if fm run submit --project-id "$PROJECT" --work-id "$TASK" --backend claude --workflow claudegw --prompt "$PROMPT" >"$WORK/run-submit-$rs_label.out" 2>&1; then
    pass "run $rs_label was submitted (task $TASK, workflow claudegw, model $CW_MODEL)"
  else
    fail "run $rs_label: run submit failed: $(head -c 400 "$WORK/run-submit-$rs_label.out")"; STAGE_OPEN=""; return 1
  fi
  rs_w=$(date +%s)
  while [ -z "$RUN" ] && [ "$(elapsed "$rs_w")" -lt 120 ]; do
    RUN=$(api_get "/api/runs?project_id=$PROJECT&limit=50" | jq -r --arg t "$TASK" '[.runs[]? | select(.task_id == $t)][0].run_id // empty' 2>/dev/null)
    [ -n "$RUN" ] || sleep 2
  done
  [ -n "$RUN" ] || { fail "run $rs_label: no run for task $TASK after 120 s"; STAGE_OPEN=""; return 1; }
  note "run $RUN"
  LEDGER_SPEND0=$(ledger_spend)
  rs_budget=$((CW_ABORT_TOKENS - $(num "$(ledger_tokens)")))
  watch_run "$rs_timeout" "$rs_t0" "$rs_dir" "$rs_mode" "$rs_n" "$rs_budget"
  rs_t1=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  note "run $RUN ended: ${RUN_STATUS:-unknown} after $(elapsed "$rs_start")s${ABORT_REASON:+ (aborted: $ABORT_REASON)}"
  ABORTED_REASON=$ABORT_REASON
  sleep 4 # the proxy writes its spend log asynchronously
  keep_processes "$rs_dir/processes.txt"

  # what the run left behind, copied out of the work dir at once
  api_get "/api/runs/$RUN" > "$rs_dir/run.json" 2>/dev/null
  rs_sessions=$(new_session_files "$rs_dir/sessions-before.txt")
  for rs_f in $rs_sessions; do cp "$rs_f" "$rs_dir/session-$(basename "$rs_f")" 2>/dev/null; done
  # shellcheck disable=SC2086
  if [ -n "$rs_sessions" ]; then python3 "$LIVE/session_usage.py" $rs_sessions > "$rs_dir/analysis.json" 2>"$rs_dir/analysis.err"; else echo '{}' > "$rs_dir/analysis.json"; fi
  ls -1 "$CW_TEE_DIR" 2>/dev/null | sort > "$rs_dir/tee-after.txt"
  for rs_f in $(comm -13 "$rs_dir/tee-before.txt" "$rs_dir/tee-after.txt"); do cp "$CW_TEE_DIR/$rs_f" "$rs_dir/tee-$rs_f"; done
  proxy_rows "$rs_t0" "$rs_t1" "$rs_dir/proxy.json"
  if [ "$CW_GATEWAY" = litellm ]; then ledger_stage_from_proxy "$rs_label" "$RUN" "$rs_dir"; fi
  STAGE_OPEN=""
  fm usage --project "$PROJECT" --by model --format json > "$rs_dir/foreman-usage.json" 2>&1
  rs_code=$(cat "$ASSETS/event_store_dump.exs")
  elixir --name "e2ecwev$$@127.0.0.1" --cookie "$COOKIE" --hidden --rpc-eval "$NODE" "$rs_code" 2>&1 | grep '^EVIDENCE ' | cut -c10- > "$rs_dir/events.jsonl"
  git -C "$REPO" show "foreman/$TASK/$RUN:report.txt" > "$rs_dir/report.txt" 2>/dev/null
  git -C "$REPO" ls-tree -r --name-only "foreman/$TASK/$RUN" 2>/dev/null | grep -c '^ballast/part-' > "$rs_dir/parts-on-branch.txt"
  # the per-request input-token series: the session file's view next to the gateway's own log (same order), one tab-separated line per request
  { printf 'n\ttimestamp\tcontext\tinput\tcache_read\tcache_write\toutput\treads_before\n'
    jq -r '.requests[]? | [.n, .timestamp, .context, .input, .cache_read, .cache_write, .output, .reads_before] | @tsv' "$rs_dir/analysis.json" 2>/dev/null
    printf 'gateway_request\tstart\tprompt_tokens\tcompletion_tokens\tstatus\n'
    jq -r '.rows | to_entries[]? | [(.key + 1), .value.t, .value.prompt, .value.completion, .value.status] | @tsv' "$rs_dir/proxy.json" 2>/dev/null
  } > "$rs_dir/series.tsv"
  rm -rf "$rs_dir/live"
  scrub_evidence
  return 0
}

# ledger_stage_from_proxy <label> <run> <stage dir>: the run's own proxy figures into the ledger
ledger_stage_from_proxy() {
  if [ -n "$(jq -r '.count // empty' "$3/proxy.json" 2>/dev/null)" ]; then
    ledger_add "$1" "$2" "$(num "$(jq -r '.sum_prompt_tokens' "$3/proxy.json")")" "$(num "$(jq -r '.sum_completion_tokens' "$3/proxy.json")")" "$(jq -r '.sum_spend' "$3/proxy.json")" "proxy spend log"
  else
    ledger_add "$1" "$2" "$(num "$(jq -r '.sum_context // 0' "$3/analysis.json" 2>/dev/null)")" "$(num "$(jq -r '.sum_output // 0' "$3/analysis.json" 2>/dev/null)")" 0 "session file (the proxy log was unreadable)"
  fi
}

# the recorder's view of the run's claude process: launch file and the CLI's own stream
CLI_LAUNCH=""; CLI_STDOUT=""; CLI_STDERR=""
find_cli_logs() { # <stage dir>
  CLI_LAUNCH=""; CLI_STDOUT=""; CLI_STDERR=""
  for fcl in "$1"/tee-launch-*.txt; do
    [ -f "$fcl" ] || continue
    if grep -q '^flags=.* --print' "$fcl"; then CLI_LAUNCH=$fcl; fi
  done
  [ -n "$CLI_LAUNCH" ] || return 1
  fcl_id=$(basename "$CLI_LAUNCH" .txt); fcl_id=${fcl_id#tee-launch-}
  CLI_STDOUT="$1/tee-stdout-$fcl_id.jsonl"; CLI_STDERR="$1/tee-stderr-$fcl_id.txt"
}
launch_field() { sed -n "s/^$1=//p" "$CLI_LAUNCH" | head -n 1; }
cli_result() { jq -c 'select(.type == "result")' "$CLI_STDOUT" 2>/dev/null | tail -n 1; }

# expected_line <part number>: the CHECKSUM line of that part, regenerated here by the same generator
expected_line() {
  el_dir="$WORK/expected"; mkdir -p "$el_dir"
  python3 "$LIVE/make_ballast.py" --out "$el_dir" --first "$1" --last "$1" --bytes "$CW_BALLAST_BYTES" && tail -n 1 "$el_dir/$(part_name "$1").txt"
}

# ---------------------------------------------------------------- per-run assertions

# common_checks <label> <expected variable value or unset> <expected CLI window> <last part the agent should have read>
common_checks() {
  cc_label=$1; cc_dir="$CW_EVIDENCE_DIR/$1"
  assert_eq "run $cc_label: Foreman's run status" "${RUN_STATUS:-unknown}" "completed"
  if find_cli_logs "$cc_dir"; then
    pass "run $cc_label: the recorder saw the claude process Foreman started ($(basename "$CLI_LAUNCH"))"
    assert_eq "run $cc_label: the CLI got the model string verbatim (--model)" "$(launch_field model_argument)" "$CW_MODEL"
    assert_eq "run $cc_label: the CLI got ANTHROPIC_BASE_URL from the project environment" "$(launch_field ANTHROPIC_BASE_URL)" "$GW_URL"
    case "$(launch_field ANTHROPIC_API_KEY)" in "<set, "*) pass "run $cc_label: the CLI got ANTHROPIC_API_KEY from the project secret ($(launch_field ANTHROPIC_API_KEY))" ;; *) fail "run $cc_label: ANTHROPIC_API_KEY did not reach the CLI ($(launch_field ANTHROPIC_API_KEY))" ;; esac
    assert_eq "run $cc_label: the CLI's permission mode (the phase's auto_approve)" "$(launch_field permission_mode)" "bypassPermissions"
    cc_expect=$2; [ "$cc_expect" = unset ] && cc_expect='<unset>'
    assert_eq "run $cc_label: CLAUDE_CODE_MAX_CONTEXT_TOKENS as the CLI's environment had it" "$(launch_field CLAUDE_CODE_MAX_CONTEXT_TOKENS)" "$cc_expect"
    CLI_WINDOW=$(cli_result | jq -r --arg m "$CW_MODEL" '.modelUsage[$m].contextWindow // empty' 2>/dev/null)
    assert_eq "run $cc_label: the window the CLI itself reports for $CW_MODEL (modelUsage.contextWindow of its result record)" "$CLI_WINDOW" "$3"
    CLI_DIAG=$(grep -c 'unrecognized_model' "$CLI_STDERR" 2>/dev/null)
    note "run $cc_label: CLI diagnostic 'unrecognized_model' on stderr: $([ "${CLI_DIAG:-0}" -gt 0 ] && echo yes || echo no); CLI result: $(cli_result | jq -c '{subtype, is_error, num_turns, duration_ms, total_cost_usd}' 2>/dev/null); api_retry records: $(grep -c '"subtype":"api_retry"' "$CLI_STDOUT" 2>/dev/null)"
  else
    CLI_WINDOW=""
    fail "run $cc_label: the recorder logged no claude process of this run (is context_window_live/bin first on the server's PATH?)"
  fi
  CA="$cc_dir/analysis.json"
  assert_eq "run $cc_label: the claude session file exists (private HOME $WORK/home)" "$([ "$(jq -r '.request_count // 0' "$CA" 2>/dev/null)" -gt 0 ] && echo yes || echo no)" "yes"
  note "run $cc_label: context of each request (input + cache read + cache write): $(jq -r '[.requests[]?.context] | join(", ")' "$CA" 2>/dev/null)"
  note "run $cc_label: tool calls $(jq -c '.tool_calls' "$CA" 2>/dev/null), Read files $(jq -r '.read_files | join(" ")' "$CA" 2>/dev/null), final text: $(jq -r '.final_text' "$CA" 2>/dev/null | tr '\n' ' ' | cut -c1-80)"
  note "run $cc_label: compactions in the session file: $(jq -c '.compactions' "$CA" 2>/dev/null); summary records: $(jq -r '.summary_records' "$CA" 2>/dev/null); models: $(jq -c '.models' "$CA" 2>/dev/null)"
  # the gateway's own log of the same requests
  if [ -n "$(jq -r '.count // empty' "$cc_dir/proxy.json" 2>/dev/null)" ]; then
    note "run $cc_label: the gateway logged $(jq -c '{count, success, failed, max_prompt_tokens, sum_prompt_tokens, sum_completion_tokens, sum_spend}' "$cc_dir/proxy.json")"
    note "run $cc_label: gateway prompt tokens per request: $(jq -r '[.rows[].prompt] | join(", ")' "$cc_dir/proxy.json")"
    PROXY_OK=yes
  else
    unverified "run $cc_label: the gateway's own log of the run" "the gateway did not answer /spend/logs: $(head -c 200 "$cc_dir/proxy.json" "$cc_dir/proxy.json.err" 2>/dev/null | tr '\n' ' ')"
    PROXY_OK=no
  fi
  # Foreman's own record
  cc_usage=$(jq -c --arg r "$RUN" 'select(.type == "UsageRecorded" and ((.data.run_id // "") == $r))' "$cc_dir/events.jsonl" 2>/dev/null | tail -n 1)
  FM_IN=0
  if [ -n "$cc_usage" ]; then
    note "run $cc_label: Foreman's UsageRecorded: $(jqs "$cc_usage" '.data | {input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, total_tokens, cost_usd, model}' | tr -d '\n ')"
    FM_IN=$(num "$(jqs "$cc_usage" '(.data.input_tokens // 0) + (.data.cache_read_tokens // 0) + (.data.cache_write_tokens // 0)')")
  else
    unverified "run $cc_label: Foreman's UsageRecorded event" "none for run $RUN in the event store dump"
  fi
  # what the agent wrote: the CHECKSUM lines of the first part and of the last part it read
  cc_report=$(cat "$cc_dir/report.txt" 2>/dev/null)
  cc_exp=$(printf '%s\n%s' "$(expected_line 1)" "$(expected_line "$4")")
  if [ "$cc_report" = "$cc_exp" ]; then
    pass "run $cc_label: report.txt on the run's branch holds the CHECKSUM lines of part-01 and $(part_name "$4") (the agent kept the first part's across the whole context)"
  else
    note "run $cc_label: report.txt is NOT what the parts say (a model-quality observation, not asserted): got '$(printf '%s' "$cc_report" | tr '\n' '|' | cut -c1-120)', expected '$(printf '%s' "$cc_exp" | tr '\n' '|')'"
  fi
}

# ---------------------------------------------------------------- the run

check_environment
for cw_tool in claude jq curl python3 awk pg_dump; do command -v "$cw_tool" >/dev/null 2>&1 || die "'$cw_tool' is required on PATH" 1; done
[ -n "$CW_REAL_CLAUDE" ] || die "no claude on PATH" 1
case "$CW_GATEWAY" in
  litellm)
    [ -n "$CRED_FILE" ] || die "CW_LITELLM_FILE is required (a file with a 'url:' line and a 'key:' line; CW_GATEWAY=standin needs none)" 1
    [ -r "$CRED_FILE" ] || die "CW_LITELLM_FILE is not readable" 1
    read_credentials || die "CW_LITELLM_FILE must hold a 'url:' line and a 'key:' line" 1
    ;;
  standin) ;;
  *) die "CW_GATEWAY must be litellm or standin" 1 ;;
esac
out "context_window_live: gateway $CW_GATEWAY, model alias $CW_MODEL, window variable $CW_WINDOW, stages $CW_STAGES; claude $("$CW_REAL_CLAUDE" --version 2>&1 | head -n 1); evidence $CW_EVIDENCE_DIR"
mkdir -p "$CW_EVIDENCE_DIR" || die "cannot create $CW_EVIDENCE_DIR" 1
if [ "$CW_GATEWAY" = litellm ]; then
  INVOCATION_T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  LEDGER_SPEND0=$(ledger_spend)
  out "   ledger $CW_LEDGER: $(ledger_tokens) tokens and \$$LEDGER_SPEND0 recorded for earlier real runs; ceiling $CW_ABORT_TOKENS tokens and \$$CW_MAX_SPEND_USD for all of them together"
  gateway_preflight || { out "   the gateway is not usable (see above): nothing was built and nothing more was spent"; summary; exit $?; }
  if [ "${CW_PREFLIGHT_ONLY:-0}" = 1 ]; then out "   CW_PREFLIGHT_ONLY=1: the gateway checks are all this invocation does"; summary; exit $?; fi
fi
install_traps
trap cw_cleanup EXIT

setup_stack
if [ "$CW_GATEWAY" = standin ]; then
  start_standin
  LEDGER_SPEND0=0
  read_credentials || die "stand-in credentials unreadable" 2
  gateway_preflight || { summary; exit $?; }
fi

# the repository: the seed parts committed to main (every run's worktree is cut from it) and the one workflow, then a restart so the catalog sees it
python3 "$LIVE/make_ballast.py" --out "$REPO/ballast" --last "$CW_SEED_PARTS" --bytes "$CW_BALLAST_BYTES" || die "cannot generate the ballast" 2
git -C "$REPO" add ballast && git -C "$REPO" commit -q -m "seed ballast for the context window run" && git -C "$REPO" push -q origin main || die "cannot commit the ballast" 2
note "ballast in the repository: $(ls "$REPO/ballast" | wc -l | tr -d ' ') parts of about $(wc -c < "$REPO/ballast/part-01.txt" | tr -d ' ') bytes; more are added to a run's worktree while it goes on (B) or when it starts (C)"
write_gateway_workflow
stop_server; start_server
register_project || { head -c 1500 "$WORK/project-create.out"; tail -n 20 "$SERVER_LOG" | cut -c1-240; die "cannot register the project" 2; }
note "project $PROJECT registered over $REPO"

say "project environment: base URL and plumbing as plain variables, the key as a project secret"
fm project env set "$PROJECT" "ANTHROPIC_BASE_URL=$GW_URL" DISABLE_AUTOUPDATER=1 DISABLE_TELEMETRY=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  >"$WORK/env-set.out" 2>&1 || { head -c 500 "$WORK/env-set.out"; die "project env set failed" 2; }
printf '%s' "$GW_KEY" | fm project secret set "$PROJECT" ANTHROPIC_API_KEY >"$WORK/secret-set.out" 2>&1 || { head -c 300 "$WORK/secret-set.out"; die "project secret set failed (the CLI never prints the value)" 2; }
note "$(cat "$WORK/secret-set.out")"
note "project env (values of plain variables only): $(fm project env list --format=json "$PROJECT" | jq -c '.vars')"
note "project secrets (names and versions only): $(fm project secret list --format=json "$PROJECT" | jq -c '[.[] | {name, version}]')"
assert_eq "the key is held as a project secret, not a plain variable" "$(fm project env list --format=json "$PROJECT" | jq -r '.vars | has("ANTHROPIC_API_KEY")')" "false"

ABORTED_REASON=""
A_BASE=""; A_STEP=""

# ---- run A: the canary and the baseline
case " $CW_STAGES " in *" A "*)
  A_NEED=$((CW_SMALL_FILES * 60000 + 150000))
  if [ $((A_NEED + $(num "$(ledger_tokens)"))) -gt "$CW_ABORT_TOKENS" ]; then
    unverified "run A" "not started: the ledger says the combined ceiling of $CW_ABORT_TOKENS tokens leaves no room"
  elif run_stage A fixed "$CW_SMALL_FILES" off 900; then
    common_checks A unset 200000 "$CW_SMALL_FILES"
    assert_eq "run A: no compaction (the context stayed far below the 176000 the CLI compacts at)" "$(jq -r '(.compactions | length) + .summary_records' "$CW_EVIDENCE_DIR/A/analysis.json")" "0"
    # what run A measured: the base request (the first request's context) and the tokens one part adds
    A_BASE=$(jq -r '.requests[0].context // 0' "$CW_EVIDENCE_DIR/A/analysis.json" 2>/dev/null)
    A_AFTER=$(jq -r --argjson r "$CW_SMALL_FILES" '[.requests[] | select(.reads_before == $r)][0].context // 0' "$CW_EVIDENCE_DIR/A/analysis.json" 2>/dev/null)
    A_STEP=$(awk -v b="${A_BASE:-0}" -v a="${A_AFTER:-0}" -v r="$CW_SMALL_FILES" 'BEGIN { if (b > 0 && a > b) printf "%d", (a - b) / r }')
    note "run A measured: base request $A_BASE tokens, ${A_STEP:-unknown} tokens added by each part read (about $(awk -v b="${A_BASE:-0}" -v s="${A_STEP:-0}" -v c="$CW_CROSS_TOKENS" 'BEGIN { if (s > 0) printf "%d", (c - b) / s + 2 }') parts to the first request above $CW_CROSS_TOKENS)"
  fi
  ;;
esac

# the hard cap of parts for run B: the number whose context is about CW_CAP_TOKENS, from what run A measured (or the same from the document's numbers)
if [ -z "$CW_PART_CAP" ]; then
  CW_PART_CAP=$(awk -v b="${A_BASE:-14000}" -v s="${A_STEP:-21000}" -v cap="$CW_CAP_TOKENS" 'BEGIN { n = int((cap - b) / s); if (n < 8) n = 8; if (n > 20) n = 20; print n }')
fi
note "run B's hard cap: $CW_PART_CAP parts (about $(awk -v b="${A_BASE:-14000}" -v s="${A_STEP:-21000}" -v n="$CW_PART_CAP" 'BEGIN { printf "%d", b + n * s }') tokens of context, $((CW_PART_CAP * CW_BALLAST_BYTES / 1000)) KB of ballast)"

# stage_estimate <mode> <parts> <on|off>: the input tokens a run is expected to process, from run A's numbers (or the document's). A run with the
# variable unset is modelled with the compaction the CLI is expected to make at 176000 tokens (it sends the old context once more to be summarised).
stage_estimate() {
  awk -v mode="$1" -v n="$2" -v var="${3:-on}" -v b="${A_BASE:-14000}" -v s="${A_STEP:-21000}" -v cross="$CW_CROSS_TOKENS" -v lead="$CW_LEAD_PARTS" '
    BEGIN {
      if (mode == "adapt") { jc = int((cross - b) / s) + 2; n = jc - 1 + lead < n ? jc - 1 + lead : n }
      t = 0; ctx = b; reads = 0; wrote = 0; prev = 0
      while (1) {
        if (var == "off" && prev >= 176000) { t += prev; ctx = b + 8000 }
        t += ctx; prev = ctx
        if (reads < n) { reads++; ctx += s }
        else if (!wrote) { wrote = 1; ctx += 300 }
        else break
      }
      if (mode == "adapt") t += b + n * s   # the request that asks for the part that does not exist, and its answer
      printf "%d", t
    }'
}
guard_stage() { # <label> <mode> <parts> <on|off>: refuses a run the ledger makes too expensive
  gs_est=$(stage_estimate "$2" "$3" "$4")
  gs_have=$(num "$(ledger_tokens)")
  out "   run $1 expects about $gs_est input tokens (about \$$(awk -v t="$gs_est" -v p="${GW_PRICE_IN:-0}" 'BEGIN{printf "%.2f", t * p}') at the gateway's declared input price $(awk -v p="${GW_PRICE_IN:-0}" 'BEGIN{printf "%.2f", p * 1000000}')/M, before any prompt-cache discount); the ledger holds $gs_have tokens of earlier real runs, the ceiling for all of them together is $CW_ABORT_TOKENS"
  if [ $((gs_have + gs_est)) -gt "$CW_ABORT_TOKENS" ] && [ "$CW_GATEWAY" = litellm ]; then
    out "   run $1 NOT started: it would not fit under the combined ceiling"
    unverified "run $1" "not started: $gs_have + about $gs_est tokens would cross the combined ceiling of $CW_ABORT_TOKENS"
    return 1
  fi
  return 0
}

# ---- run B: the acceptance
B_LAST=""
case " $CW_STAGES " in *" B "*)
  if [ "$FAILED" -eq 0 ] && guard_stage B adapt "$CW_PART_CAP" on; then
    if run_stage B adapt "$CW_PART_CAP" on "$CW_RUN_TIMEOUT"; then
      B_LIMIT=$PART_LIMIT
      B_LAST=$(jq -r --argjson lim "$B_LIMIT" '[.read_files[] | capture("part-(?<n>[0-9]+)") | .n | tonumber | select(. <= $lim)] | max // 0' "$CW_EVIDENCE_DIR/B/analysis.json" 2>/dev/null)
      note "run B: the agent had $B_LIMIT parts to read and read up to part $B_LAST; the crossing: ${CROSSED:-never observed by the harness}"
      common_checks B "$CW_WINDOW" "$CW_WINDOW" "${B_LAST:-0}"
      B_MAX=$(num "$(jq -r '.max_context // 0' "$CW_EVIDENCE_DIR/B/analysis.json")")
      assert_eq "run B: no aborted run" "${ABORTED_REASON:-none}" "none"
      [ "$B_MAX" -gt 200000 ] && b_over=yes || b_over=no
      assert_eq "run B: a request above 200000 tokens in the claude session file (largest: $B_MAX; requests above 200000: $(jq -r '[.requests[] | select(.context > 200000)] | length' "$CW_EVIDENCE_DIR/B/analysis.json"))" "$b_over" "yes"
      if [ "$PROXY_OK" = yes ]; then
        B_PMAX=$(num "$(jq -r '.max_prompt_tokens // 0' "$CW_EVIDENCE_DIR/B/proxy.json")")
        [ "$B_PMAX" -gt 200000 ] && b_pover=yes || b_pover=no
        assert_eq "run B: the gateway itself logged a request above 200000 prompt tokens (largest: $B_PMAX), accepted with HTTP success" "$b_pover" "yes"
        assert_eq "run B: no request of the run failed at the gateway" "$(jq -r '.failed' "$CW_EVIDENCE_DIR/B/proxy.json")" "0"
      fi
      assert_eq "run B: NO compaction record in the claude session file" "$(jq -r '(.compactions | length) + .summary_records' "$CW_EVIDENCE_DIR/B/analysis.json")" "0"
      B_SUM=$(num "$(jq -r '.sum_context // 0' "$CW_EVIDENCE_DIR/B/analysis.json")")
      assert_eq "run B: the run's own input tokens ($B_SUM) stayed within what the combined ceiling left it" "$([ "$B_SUM" -le "$CW_ABORT_TOKENS" ] && echo yes || echo no)" "yes"
      if [ "$FM_IN" -gt 0 ]; then
        awk -v a="$FM_IN" -v b="$B_SUM" 'BEGIN{d = a - b; if (d < 0) d = -d; exit !(d <= 0.01 * b)}' && fm_agree=yes || fm_agree=no
        if [ "$fm_agree" = yes ]; then pass "run B: Foreman's UsageRecorded input side ($FM_IN) agrees with the session file's sum ($B_SUM) within 1%"
        else note "run B: Foreman's UsageRecorded input side is $FM_IN, the session file's sum is $B_SUM (they differ by more than 1%; not asserted)"; fi
      fi
      if [ "$B_MAX" -gt 200000 ] && [ "$(jq -r '(.compactions | length) + .summary_records' "$CW_EVIDENCE_DIR/B/analysis.json")" = 0 ] && [ "$CLI_WINDOW" != "$CW_WINDOW" ]; then
        out "   run C is ADVISED: B crossed 200000 without a compaction but the CLI's own window evidence says '${CLI_WINDOW:-none}': which of the two is the cause needs the same corpus without the variable (CW_STAGES=C CW_LARGE_FILES=$B_LIMIT)"
      fi
    fi
  else
    unverified "run B (the acceptance)" "not started: an earlier assertion failed, or the ledger leaves no room"
  fi
  ;;
esac

# ---- run C (optional): the same corpus without the variable
case " $CW_STAGES " in *" C "*)
  C_PARTS=${CW_LARGE_FILES:-${B_LIMIT:-}}
  if [ -z "$C_PARTS" ]; then
    unverified "run C" "not started: it needs the corpus of run B (CW_LARGE_FILES=<parts>), and run B did not run in this invocation"
  elif guard_stage C fixed "$C_PARTS" off; then
    if run_stage C fixed "$C_PARTS" off "$CW_RUN_TIMEOUT"; then
      common_checks C unset 200000 "$C_PARTS"
      C_PRE=$(jq -r '[.compactions[]?.pre_tokens] | first // empty' "$CW_EVIDENCE_DIR/C/analysis.json")
      assert_eq "run C: the CLI auto-compacted (trigger auto, at least once)" "$(jq -r '[.compactions[]? | select(.trigger == "auto")] | length > 0' "$CW_EVIDENCE_DIR/C/analysis.json")" "true"
      [ -n "$C_PRE" ] && [ "$C_PRE" -lt 200000 ] && c_early=yes || c_early=no
      assert_eq "run C: the first compaction came BELOW 200000 tokens (at ${C_PRE:-none}: the window of a model that takes $CW_WINDOW)" "$c_early" "yes"
    fi
  fi
  ;;
esac

# ---------------------------------------------------------------- the totals, and what leaked where

say "what the real provider was asked to process"
if [ "$CW_GATEWAY" = litellm ]; then
  note "ledger $CW_LEDGER (all real runs together): $(ledger_tokens) prompt+completion tokens, proxy spend \$$(ledger_spend)"
  note "this invocation: $(jq -s --arg t "$INVOCATION_T0" '[.[] | select(.at >= $t)] | {runs: length, prompt_tokens: ([.[].prompt_tokens] | add // 0), completion_tokens: ([.[].completion_tokens] | add // 0), proxy_spend_usd: ([.[].spend] | add // 0)}' "$CW_LEDGER" 2>/dev/null | tr -d '\n ')"
  note "computed at the proxy's declared prices ($(awk -v p="$GW_PRICE_IN" 'BEGIN{printf "%.2f", p * 1000000}')/M in, $(awk -v p="$GW_PRICE_OUT" 'BEGIN{printf "%.2f", p * 1000000}')/M out, no cache discount): this invocation \$$(jq -s --arg t "$INVOCATION_T0" --argjson pi "$GW_PRICE_IN" --argjson po "$GW_PRICE_OUT" '[.[] | select(.at >= $t) | (.prompt_tokens * $pi) + (.completion_tokens * $po)] | add // 0 | . * 10000 | round / 10000' "$CW_LEDGER" 2>/dev/null), all real runs together \$$(jq -s --argjson pi "$GW_PRICE_IN" --argjson po "$GW_PRICE_OUT" '[.[] | (.prompt_tokens * $pi) + (.completion_tokens * $po)] | add // 0 | . * 10000 | round / 10000' "$CW_LEDGER" 2>/dev/null)"
  assert_eq "the real runs together stayed under the combined ceiling of $CW_ABORT_TOKENS tokens" "$([ "$(num "$(ledger_tokens)")" -le "$CW_ABORT_TOKENS" ] && echo yes || echo no)" "yes"
fi
say "the key: where it is and where it is not"
keep_processes "$CW_EVIDENCE_DIR/processes-final.txt"
PGPASSWORD=$E2E_PG_PASSWORD pg_dump -h "$E2E_PG_HOST" -p "$E2E_PG_PORT" -U "$E2E_PG_USER" --data-only "$E2E_DB_NAME" > "$WORK/db.sql" 2>"$WORK/pg_dump.err" \
  || note "pg_dump failed: $(head -c 200 "$WORK/pg_dump.err")"
SECRETS_DIR="$WORK/home/.foreman/secrets"
SCAN_EXCLUDES="--exclude $SECRETS_DIR"
[ "$CW_GATEWAY" = standin ] && SCAN_EXCLUDES="$SCAN_EXCLUDES --exclude $WORK/standin-credentials.txt"
final_evidence
# shellcheck disable=SC2086
scan_out=$(llm scan $SCAN_EXCLUDES "$WORK" "$CW_EVIDENCE_DIR" 2>&1)
printf '%s\n' "$scan_out" | while IFS= read -r l; do note "$l"; done
assert_eq "files with the key outside the secret store (work dir incl. server log and database dump, evidence dir)" "$(printf '%s\n' "$scan_out" | sed -n 's/^scan total: \([0-9]*\) file.*/\1/p')" "0"
store_out=$(llm scan "$SECRETS_DIR" 2>&1)
note "$(printf '%s\n' "$store_out" | head -n 1)"
assert_eq "the secret store (the write-only home of the secret) holds the key in exactly one file" "$(printf '%s\n' "$store_out" | sed -n 's/^scan total: \([0-9]*\) file.*/\1/p')" "1"
out "   evidence kept in $CW_EVIDENCE_DIR"
summary
exit $?
