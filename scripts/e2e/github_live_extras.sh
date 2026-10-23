#!/usr/bin/env bash
# scripts/e2e/github_live_extras.sh
#
# Live acceptance of the GitHub paths that stage 8 of claude_projects_flow.sh (claude_projects/github.sh)
# leaves open (bead foreman-ksy0q), against a REAL private scratch repository and a real, throwaway
# Foreman server (own port, own Postgres database, real pi agent on minimax/MiniMax-M2.7-highspeed):
#
#   ui           the workspace UI buttons Fix CI / Address comments / Resolve conflicts / Create PR clicked in a
#                real browser (Playwright) on real PRs; no merge or approve control exists anywhere
#   autofix      the pr_auto_fix policy off (observed, not fixed), on (fixed automatically), and bounded
#   postapproval what a push after merge approval does to the gate and the PR (observation only)
#   protection   operator merge under GitHub branch protection (required checks, a required review,
#                linear history): the refusal text and the merge once every rule is met
#
# Usage, from a devbox shell (E2E_WORK_DIR, E2E_DB_NAME, E2E_PORT, E2E_HOOK_PORT as for the other harnesses):
#
#     FOREMAN_E2E_GITHUB_REPO=<owner>/foreman-scratch-<suffix> E2E_GH_ALLOW_PUBLIC=1 \
#       devbox run -- bash scripts/e2e/github_live_extras.sh [all | serve | stage <name>... | stop]
#
#   all    (default) set up, run every stage in order, tear everything down.
#   serve  set up the stack and the webhook tunnel, write $E2E_WORK_DIR/state.env, print SERVE-READY and keep
#          running until `stop` (or a signal); then tear down. For re-running single stages.
#   stage  attach to a `serve`d stack and run the named stages (see STAGES_ALL below).
#   stop   ask a `serve`d stack to tear itself down.
#
# FOREMAN_E2E_GITHUB_REPO must name an existing PRIVATE, non-archived <owner>/foreman-scratch-<suffix> repository
# seeded from scripts/e2e/claude_projects/github-fixture/ (the harness never creates or deletes a repository).
# Branch protection does not exist on private repositories of a free GitHub plan (HTTP 403), so the protection stage
# makes THAT repository public for a few minutes, after a content safety scan, and makes it private again; it runs only
# with E2E_GH_ALLOW_PUBLIC=1 and otherwise counts as UNVERIFIED. Evidence (events, UI JSON, screenshots, command
# output) is kept in E2E_EVIDENCE_DIR (default <repo>/tmp/gx-evidence), outside the work dir that is removed.
#
# Exit status: 0 all passed, 1 environment problem, 2 setup failed, 3 one or more assertions failed.

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
E2E_NAME=${E2E_NAME:-gx}
# shellcheck source=claude_projects/lib.sh
. "$HERE/claude_projects/lib.sh"
# shellcheck source=claude_projects/github.sh
. "$HERE/claude_projects/github.sh"
# shellcheck source=claude_projects/github_extras.sh
. "$HERE/claude_projects/github_extras.sh"

MODE=${1:-all}
export E2E_REVIEW_ANALYSIS=0
E2E_EVIDENCE_DIR=${E2E_EVIDENCE_DIR:-$ROOT/tmp/gx-evidence}
E2E_TRANSCRIPT=${E2E_TRANSCRIPT:-$E2E_EVIDENCE_DIR/transcript-$MODE.txt}

STAGES_ALL="pr_a ui_baseline policy_off_and_fix_ci ui_address ui_conflicts autofix createpr postapproval prot_prepare protection"
STATE_FILE="$WORK/state.env"
STATE_VARS="WORK ROOT SUFFIX NODE COOKIE API E2E_PORT E2E_HOOK_PORT E2E_DB_NAME DATABASE_URL E2E_API_TOKEN E2E_MODEL
  SERVER_PID HOOK_PID SERVER_LOG HOOK_CAPTURE FOREMAN PROJECT REPO DB_CREATED GH_REPO GH_CLONE GH_OP GH_PROJECT
  GH_HOOK_ID GH_BASE_SHA GH_HOOK_SECRET TUNNEL_PID TUNNEL_URL SAVE_PROJECT SAVE_REPO GH_THREAD GH_RUN GH_PR GH_PR_URL
  GH_BRANCH GH_PR_FILE BEAD_ID BROKEN GH_ORIGIN_URL GH_FLIPPED GH_PROTECTED GH_FLIP_AT GH_UNFLIP_AT"

state_save() {
  ss_tmp="$STATE_FILE.tmp"
  : > "$ss_tmp"
  # `set` rather than `compgen -v`: the nix bash devbox provides has no programmable-completion builtins
  for ss_v in $STATE_VARS $(set | awk -F= '/^PR[A-Z0-9]+_(THREAD|RUN|PR|PR_URL|BRANCH|FILE|BEAD)=/ {print $1}'); do
    printf '%s=%q\n' "$ss_v" "${!ss_v-}" >> "$ss_tmp"
  done
  mv "$ss_tmp" "$STATE_FILE"
}

# finish: keep the server log with the evidence, then the shared cleanup (server, hook, tunnel, database, work dir)
finish() {
  fi_rc=$?
  trap - EXIT INT TERM HUP
  mkdir -p "$E2E_EVIDENCE_DIR"
  [ -f "${SERVER_LOG:-}" ] && cp "$SERVER_LOG" "$E2E_EVIDENCE_DIR/server.log" 2>/dev/null
  [ -f "${HOOK_CAPTURE:-}" ] && cp "$HOOK_CAPTURE" "$E2E_EVIDENCE_DIR/notifications.jsonl" 2>/dev/null
  cleanup
  exit "$fi_rc"
}

# attach_env: the credentials the server's environment carries (see github_prepare), without a new webhook secret
attach_env() {
  GH_TOKEN=$(gh auth token) || die "gh auth token failed" 1
  export GH_TOKEN
  export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0="credential.helper" GIT_CONFIG_VALUE_0="" \
    GIT_CONFIG_KEY_1="credential.https://github.com.helper" GIT_CONFIG_VALUE_1='!gh auth git-credential'
}

setup_all() {
  github_enabled || die "FOREMAN_E2E_GITHUB_REPO is required (a private <owner>/foreman-scratch-<suffix> repository)" 1
  check_environment
  github_prepare
  mkdir -p "$E2E_EVIDENCE_DIR"
  : > "$E2E_TRANSCRIPT"
  install_traps
  trap finish EXIT
  setup_stack
  gh_extras_init
  gh_stage_setup || die "GitHub setup failed" 2
  gh_stage_webhook
  state_save
}

run_stage() {
  rs_name=$1
  type "gh_x_$rs_name" >/dev/null 2>&1 || die "unknown stage '$rs_name' (known: $STAGES_ALL)" 1
  rs_start=$(date +%s)
  "gh_x_$rs_name"
  note "(stage $rs_name finished after $(elapsed "$rs_start")s)"
  state_save
}

case "$MODE" in
  all)
    setup_all
    for s in $STAGES_ALL; do run_stage "$s"; done
    gh_unwind_protection
    summary
    exit $?
    ;;
  serve)
    setup_all
    out "SERVE-READY state=$STATE_FILE api=$API project=$PROJECT repo=$GH_REPO"
    while [ ! -e "$WORK/stop" ]; do
      kill -0 "$SERVER_PID" 2>/dev/null || { out "the server died: stopping"; break; }
      sleep 3
    done
    gh_unwind_protection
    summary
    exit $?
    ;;
  stage)
    shift
    [ -f "$STATE_FILE" ] || die "no running stack: $STATE_FILE is missing (start one with: $0 serve)" 1
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    attach_env
    kill -0 "$SERVER_PID" 2>/dev/null || die "the stack's server (pid $SERVER_PID) is not running" 1
    mkdir -p "$E2E_EVIDENCE_DIR"
    gh_extras_init
    trap state_save EXIT
    for s in "$@"; do run_stage "$s"; done
    summary
    exit $?
    ;;
  stop)
    [ -f "$STATE_FILE" ] || die "no running stack: $STATE_FILE is missing" 1
    : > "$WORK/stop"
    out "stop requested: the serve process tears the stack down"
    exit 0
    ;;
  *)
    die "usage: $0 [all | serve | stage <name>... | stop] (stages: $STAGES_ALL)" 1
    ;;
esac
