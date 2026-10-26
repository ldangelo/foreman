#!/usr/bin/env bash
# scripts/e2e/network_policy_flow.sh
#
# IN-CONTAINER acceptance of the project network policy (E4-S5, `foreman project network ...`): a real
# docker jobsite of a real throwaway Foreman server (private database/port/scratch repo), started through
# `POST /api/jobsites` under a policy, with something INSIDE the jobsite's container making requests whose
# outcome the harness reads back. The policy code is the product's own (NetworkPolicy -> internal docker
# network + tinyproxy sidecar + HTTP(S)_PROXY env); nothing here builds a network or a proxy by hand.
#
# What runs inside the container, and why it is not a real agent: the jobsite image carries curl, jq and a
# SIMULATED `pi` (scripts/e2e/network_policy/fake-pi). Foreman runs it exactly like the real one (the
# docker sandbox's `docker exec --env-file` shim, the `pi --mode json` event stream), and it runs the
# probe (scripts/e2e/network_policy/probe.sh, committed to the scratch repo) as the agent's tool call, in
# the agent's environment. The real `pi` is a node program, and an image carrying it would also need a
# provider credential; neither is needed to observe what the container's network lets through. All
# targets are a tiny HTTP server on THIS host (scripts/e2e/network_policy/target.py, 127.0.0.1) reached as
# host.docker.internal (allowed) and as a second name of the same host (blocked): no third-party service
# is a target. The one thing that goes out is what the policy itself needs: the first jobsite builds the
# egress proxy image (FROM alpine:3.20, apk add tinyproxy), and this script's own probe image needs curl.
#
# Scenarios (each prints EXPECTED vs ACTUAL via PASS/FAIL lines; the target's own request log is the
# independent witness of what reached the host):
#   control       the same probe in a plain container on the default bridge, no policy: every request
#                 reaches the target (so a later failure is the policy, not the host or the names)
#   allowlist     `--mode allowlist --allow host.docker.internal`: the sandbox sits on an --internal
#                 network only, the sidecar on that network AND bridge; the allowed host answers 200, the
#                 other name gets 403 from the proxy and never reaches the target, a proxy-bypassing
#                 request has no DNS and no route; the network, the sidecar and the sandbox are gone
#                 after the jobsite completes
#   none          `--mode none`: `--network none`; nothing is reachable at all; no sidecar or network
#                 exists to leak
#   cancel        cancelling an in-flight allowlist jobsite removes the sidecar, the network, the sandbox
#   pause-resume  pausing removes them too; resume re-applies the policy (a NEW network and sidecar, the
#                 same enforcement) and completion removes them again
#   hook-env      a sandbox hook (`hooks.sandbox.on_sandbox_ready`) runs through the same docker exec path
#                 as every other in-sandbox command: under the allowlist it must reach an allowed host
#                 through the sidecar too (the policy's whole point), not just the agent's own process; the
#                 allowlist scenarios also assert the sandbox container's own environment carries the proxy
#   scope         the network, sidecar and sandbox carry Foreman's labels (`foreman.owner`, `foreman.jobsite`),
#                 and a sweep for ANOTHER owner, run on the server's node, removes none of an in-flight
#                 jobsite's objects (a second Foreman server booting on this docker host must not)
#   crash         `kill -9` of the server with an allowlist jobsite in flight, then a restart: the boot
#                 sweep leaves no network, sidecar or sandbox container of that jobsite behind. This is the
#                 scenario that found the leak: the sweep removed the sidecar but not the sandbox container
#                 that outlived the server, and `docker network rm` refuses while that container is
#                 attached. The orphaned (paused) jobsite is then resumed: the policy is applied again
#                 under the same network name and the resumed probe is held to the same enforcement
#
# Exit: 0 all passed (UNVERIFIED lines are counted, never passes), 1 environment problem, 2 setup
# failed, 3 one or more assertions failed.
#
#     devbox run -- bash scripts/e2e/network_policy_flow.sh [scenario ...]
#
# With no arguments every scenario runs. Needs a reachable docker daemon (OrbStack or Docker Desktop:
# the targets are reached as host.docker.internal) and access to Docker Hub / the Alpine package CDN for
# the two image builds; without a daemon the run records UNVERIFIED with the `docker info` output.
# Environment (all optional): E2E_WORK_DIR, E2E_DB_NAME, E2E_PORT, E2E_HOOK_PORT, E2E_KEEP (as in
# claude_projects/lib.sh), E2E_NET_BLOCKED_HOST (default host.orb.internal: any second name that
# resolves to the host from a plain container), E2E_NET_KEEP_IMAGES=1 (keep the two images built here).
# The server runs with DOCKER_CONFIG pointing at the real ~/.docker (HOME is redirected, the docker
# client must still find its context) and E2E_REVIEW_ANALYSIS=0 (no reviewer agent for a simulated one).

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
E2E_NAME=${E2E_NAME:-net}
E2E_PORT=${E2E_PORT:-4860}
E2E_HOOK_PORT=${E2E_HOOK_PORT:-4960}
# shellcheck source=claude_projects/lib.sh
. "$HERE/claude_projects/lib.sh"

SCENARIOS=${*:-"control allowlist none cancel pause-resume hook-env scope crash"}
for s in $SCENARIOS; do
  case "$s" in control|allowlist|none|cancel|pause-resume|hook-env|scope|crash) ;; *) die "unknown scenario '$s'" 1 ;; esac
done

NP="$HERE/network_policy"
ALLOWED_HOST=host.docker.internal
BLOCKED_HOST=${E2E_NET_BLOCKED_HOST:-host.orb.internal}
# The docker sandbox defaults to foreman-jobsite:<basename of the repo path>: a name of its own keeps this
# image away from every other harness's scratch repo.
REPO="$WORK/nprepo"
ORIGIN="$WORK/nporigin.git"
IMAGE="foreman-jobsite:$(basename "$REPO")"
TARGET_LOG="$WORK/target-capture.jsonl"
TARGET_PID=""
TARGET_PORT=""
HOST_IP=""
JOBSITES=""
BUILT_IMAGES=""
EGRESS_IMAGE_EXISTED=0

E2E_EXTRA_ENV="FOREMAN_JOBSITES_ALLOW_REMOTE_START=true E2E_REVIEW_ANALYSIS=0 DOCKER_CONFIG=${DOCKER_CONFIG:-$REAL_HOME/.docker}"

# ---------------------------------------------------------------- docker helpers

docker_ready() { DOCKER_UNAVAILABLE=$(docker info 2>&1 >/dev/null | head -n 3 | tr '\n' ' '); docker version --format '{{.Server.Version}}' >/dev/null 2>&1; }

net_of() { echo "foreman-jobsite-$1"; }
proxy_of() { echo "foreman-jobsite-proxy-$1"; }

# sandbox_of <jobsite id>: container id of the jobsite's sandbox (a container of OUR image on the
# jobsite's network; the sidecar is another image)
sandbox_of() { docker ps -q --filter "network=$(net_of "$1")" --filter "ancestor=$IMAGE" 2>/dev/null | head -n 1; }

# leftovers <jobsite id> [sandbox container id]: everything of the jobsite still on the docker host
leftovers() {
  docker ps -a --filter "name=$(proxy_of "$1")" --format 'container {{.Names}} ({{.Status}})' 2>/dev/null
  docker network ls --filter "name=$(net_of "$1")" --format 'network {{.Name}}' 2>/dev/null | grep -F "$(net_of "$1")"
  if [ -n "${2:-}" ]; then docker ps -a --filter "id=$2" --format 'container {{.ID}} ({{.Status}})' 2>/dev/null; fi
}

# purge_jobsite <jobsite id>: what this harness started and could not see the product remove
net_cleanup() {
  for nc_id in $JOBSITES; do
    for nc_c in $(docker ps -aq --filter "network=$(net_of "$nc_id")" 2>/dev/null); do docker rm -f "$nc_c" >/dev/null 2>&1; done
    docker rm -f "$(proxy_of "$nc_id")" >/dev/null 2>&1
    docker network rm "$(net_of "$nc_id")" >/dev/null 2>&1
  done
  for nc_c in $(docker ps -aq --filter "ancestor=$IMAGE" 2>/dev/null); do docker rm -f "$nc_c" >/dev/null 2>&1; done
  stop_pid "$TARGET_PID"
  if [ "${E2E_NET_KEEP_IMAGES:-0}" != 1 ] && [ "$E2E_KEEP" != 1 ]; then
    for nc_i in $BUILT_IMAGES; do docker rmi "$nc_i" >/dev/null 2>&1; done
  fi
}

net_exit() { ne_rc=$?; net_cleanup; return "$ne_rc"; }

# ---------------------------------------------------------------- jobsite helpers

# jobsite_start <branch> <prompt> [extra json object merged into the body] -> JOBSITE_ID, JOBSITE_CODE
jobsite_start() {
  js_extra=${3:-}; [ -n "$js_extra" ] || js_extra='{}'
  js_body=$(jq -n --arg p "$PROJECT" --arg b "$1" --arg pr "$2" --argjson extra "$js_extra" \
    '{project_id: $p, prompt: $pr, agent: {provider: "pi", model: "fake-pi", approval_mode: "auto_approve"},
      strategy: {branch: $b}, sandbox: "docker"} + $extra')
  JOBSITE_CODE=$(curl -sS -m 120 -o "$WORK/jobsite-start.json" -w '%{http_code}' -X POST \
    -H "authorization: Bearer $E2E_API_TOKEN" -H 'content-type: application/json' --data "$js_body" "$API/api/jobsites")
  JOBSITE_ID=$(jq -r '.id // empty' "$WORK/jobsite-start.json" 2>/dev/null)
  if [ -n "$JOBSITE_ID" ]; then JOBSITES="$JOBSITES $JOBSITE_ID"; fi
}

jobsite_post() { # <id> <verb> [json body] -> HTTP status
  curl -sS -m 120 -o "$WORK/jobsite-$2.json" -w '%{http_code}' -X POST \
    -H "authorization: Bearer $E2E_API_TOKEN" -H 'content-type: application/json' --data "${3:-"{}"}" "$API/api/jobsites/$1/$2"
}

jobsite_status() { api_get "/api/jobsites/$1" | jq -r '.status // empty'; }

# jobsite_wait <id> <status regex> <timeout s> -> JOBSITE_STATUS
jobsite_wait() {
  jw_start=$(date +%s); JOBSITE_STATUS=""
  while :; do
    JOBSITE_STATUS=$(jobsite_status "$1")
    if printf '%s' "$JOBSITE_STATUS" | grep -Eq "^($2)$"; then return 0; fi
    [ "$(elapsed "$jw_start")" -lt "$3" ] || return 1
    sleep 2
  done
}

# wait_holding <jobsite id> [timeout s] -> SANDBOX (the container id), 0 once the probe in that container has
# finished its requests and is waiting for the release file
wait_holding() {
  wh_start=$(date +%s); SANDBOX=""
  while :; do
    SANDBOX=$(sandbox_of "$1")
    if [ -n "$SANDBOX" ] && docker exec "$SANDBOX" test -e /workspace/.probe-holding 2>/dev/null; then return 0; fi
    st=$(jobsite_status "$1")
    case "$st" in failed|cancelled|completed) return 1 ;; esac
    [ "$(elapsed "$wh_start")" -lt "${2:-180}" ] || return 1
    sleep 2
  done
}

release_probe() { docker exec "$1" touch /workspace/.probe-release 2>/dev/null; }

# probe_output <branch>: the probe's committed output on a jobsite branch
probe_output() { git -C "$REPO" show "$1:net-probe.out" 2>/dev/null; }
probe_result() { printf '%s\n' "$1" | grep "^RESULT $2 " | head -n 1; }
result_code() { printf '%s' "$1" | sed -n 's/.* code=\([0-9]*\) .*/\1/p'; }
result_rc() { printf '%s' "$1" | sed -n 's/.* rc=\([0-9]*\) .*/\1/p'; }

# target_hits <path>: how many requests for that path REACHED the host target
target_hits() { grep -c "\"path\": \"$1\"" "$TARGET_LOG" 2>/dev/null || true; }

net_names() { docker inspect --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$1" 2>/dev/null | sed 's/ *$//'; }

# label_of <network|container> <name or id> <label>: the value of a docker label
label_of() {
  if [ "$1" = network ]; then
    docker network inspect --format "{{index .Labels \"$3\"}}" "$2" 2>/dev/null
  else
    docker inspect --format "{{index .Config.Labels \"$3\"}}" "$2" 2>/dev/null
  fi
}

# expect_clean <what> <jobsite id> [sandbox id]: nothing of that jobsite is left on the docker host
expect_clean() {
  ec_n=0; ec_left=""
  while [ "$ec_n" -lt 30 ]; do
    ec_left=$(leftovers "$2" "${3:-}" | tr '\n' ';')
    [ -z "$ec_left" ] && break
    sleep 2; ec_n=$((ec_n + 2))
  done
  if [ -z "$ec_left" ]; then pass "$1: no sidecar, network or sandbox of jobsite $2 left (docker ps -a / network ls)"; else fail "$1: left on the docker host: $ec_left"; fi
}

# ---------------------------------------------------------------- setup

setup_probe_assets() {
  HOST_IP=$(docker run --rm alpine:3.20 getent hosts "$ALLOWED_HOST" 2>/dev/null | awk '{print $1; exit}')
  [ -n "$HOST_IP" ] || { unverified "$ALLOWED_HOST resolvable from a container" "getent hosts $ALLOWED_HOST printed nothing: this docker host has no host alias"; return 1; }
  TARGET_PORT=$(pick_port $((E2E_PORT + 200)))
  : > "$TARGET_LOG"
  python3 "$NP/target.py" "$TARGET_PORT" "$TARGET_LOG" >"$WORK/target.log" 2>&1 &
  TARGET_PID=$!
  tw=0
  while [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$TARGET_PORT/ready" 2>/dev/null)" != 200 ]; do
    kill -0 "$TARGET_PID" 2>/dev/null || { cat "$WORK/target.log"; die "target server exited" 2; }
    tw=$((tw + 1)); [ "$tw" -lt 20 ] || die "target server not answering on 127.0.0.1:$TARGET_PORT" 2
    sleep 1
  done
  note "target http://127.0.0.1:$TARGET_PORT (container view: $ALLOWED_HOST = $HOST_IP, blocked name $BLOCKED_HOST), witness log $TARGET_LOG"

  sed -e "s|@PORT@|$TARGET_PORT|g" -e "s|@HOST_IP@|$HOST_IP|g" -e "s|@BLOCKED_HOST@|$BLOCKED_HOST|g" "$NP/probe.sh" > "$REPO/probe.sh"
  git -C "$REPO" add probe.sh && git -C "$REPO" commit -q -m "probe.sh: the in-container tool call" && git -C "$REPO" push -q origin main \
    || die "cannot commit the probe to the scratch repo" 2

  mkdir -p "$WORK/image"
  cp "$NP/Dockerfile" "$NP/fake-pi" "$WORK/image/"
  if ! docker build -q -t "$IMAGE" "$WORK/image" >"$WORK/image-build.log" 2>&1; then
    unverified "probe image $IMAGE" "docker build failed: $(tail -n 3 "$WORK/image-build.log" | tr '\n' ' ')"
    return 1
  fi
  BUILT_IMAGES="$IMAGE"
  note "probe image $IMAGE built (alpine + curl + jq + simulated pi)"
  if docker image inspect foreman-egress-proxy:1 >/dev/null 2>&1; then EGRESS_IMAGE_EXISTED=1; else BUILT_IMAGES="$BUILT_IMAGES foreman-egress-proxy:1"; fi
  return 0
}

set_policy() { # <mode> [host ...]
  sp_mode=$1; shift
  sp_args=""
  for h in "$@"; do sp_args="$sp_args --allow $h"; done
  # shellcheck disable=SC2086
  fm project network set --mode "$sp_mode" $sp_args "$PROJECT" >"$WORK/network-set.out" 2>&1 \
    && assert_eq "policy set through the CLI: $(cat "$WORK/network-set.out")" "$(fm project network show "$PROJECT" | jq -r '.network.mode')" "$sp_mode"
}

# ---------------------------------------------------------------- scenarios

scenario_control() {
  say "scenario control: the probe with NO policy (plain container on the default bridge)"
  note "EXPECTED: all four requests reach the host target, so a failure under the policy is the policy"
  out=$(docker run --rm --network bridge -e PROBE_TAG=control -v "$REPO/probe.sh:/workspace/probe.sh:ro" "$IMAGE" sh /workspace/probe.sh 2>&1)
  printf '%s\n' "$out" | while IFS= read -r l; do note "  $l"; done
  for label in allowed_via_proxy blocked_via_proxy bypass_by_ip bypass_by_name; do
    assert_eq "control: $label reached the target" "$(result_code "$(probe_result "$out" "$label")")" 200
  done
  assert_eq "control: the target saw the $BLOCKED_HOST request (the name is reachable)" "$(target_hits /control-blocked)" 1
  assert_eq "control: the target saw the IP request" "$(target_hits /control-bypass-ip)" 1
}

# check_allowlist_probe <what> <probe output> <tag>: the four-request outcome under the allowlist
check_allowlist_probe() {
  ca_what=$1; ca_out=$2; ca_tag=$3
  ca_allowed=$(probe_result "$ca_out" allowed_via_proxy)
  ca_blocked=$(probe_result "$ca_out" blocked_via_proxy)
  ca_ip=$(probe_result "$ca_out" bypass_by_ip)
  ca_name=$(probe_result "$ca_out" bypass_by_name)
  assert_eq "$ca_what: allowed host $ALLOWED_HOST answers 200 through the proxy" "$(result_code "$ca_allowed")" 200
  assert_has "$ca_what: allowed response is the target's" "$ca_allowed" "TARGET-ANSWERED path=/$ca_tag-allowed host=$ALLOWED_HOST:$TARGET_PORT"
  assert_eq "$ca_what: blocked name $BLOCKED_HOST is refused by the proxy (403)" "$(result_code "$ca_blocked")" 403
  assert_not_has "$ca_what: blocked response is not the target's" "$ca_blocked" "TARGET-ANSWERED"
  assert_eq "$ca_what: proxy-bypassing request by IP fails (no route)" "$(result_code "$ca_ip")" 000
  assert_true "$ca_what: ...with a connection error, rc=$(result_rc "$ca_ip")" test "$(result_rc "$ca_ip")" -ne 0
  assert_eq "$ca_what: proxy-bypassing request by name fails (no DNS)" "$(result_code "$ca_name")" 000
  assert_true "$ca_what: ...with a resolution error, rc=$(result_rc "$ca_name")" test "$(result_rc "$ca_name")" -ne 0
  note "$ca_what: IP bypass: $ca_ip"
  note "$ca_what: name bypass: $ca_name"
  assert_eq "$ca_what: the target saw the allowed request exactly once" "$(target_hits "/$ca_tag-allowed")" 1
  assert_eq "$ca_what: the target never saw the blocked request" "$(target_hits "/$ca_tag-blocked")" 0
  assert_eq "$ca_what: the target never saw the bypass-by-IP request" "$(target_hits "/$ca_tag-bypass-ip")" 0
  assert_eq "$ca_what: the target never saw the bypass-by-name request" "$(target_hits "/$ca_tag-bypass-name")" 0
}

# check_allowlist_topology <what> <jobsite id> <sandbox>: the docker objects the policy created, as docker reports them
check_allowlist_topology() {
  ct_net=$(net_of "$2"); ct_proxy=$(proxy_of "$2")
  assert_eq "$1: policy network $ct_net is --internal" "$(docker network inspect "$ct_net" --format '{{.Internal}}' 2>/dev/null)" true
  assert_eq "$1: sandbox is attached to the policy network ONLY" "$(net_names "$3")" "$ct_net"
  ct_proxy_nets=""; ct_allow=""; ct_try=0
  while [ "$ct_try" -lt 10 ]; do
    ct_proxy_nets=$(net_names "$ct_proxy" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ *$//')
    ct_allow=$(docker exec "$ct_proxy" cat /etc/tinyproxy/allow 2>"$WORK/proxy-exec.err")
    if [ -n "$ct_proxy_nets" ] && [ -n "$ct_allow" ]; then break; fi
    ct_try=$((ct_try + 1)); sleep 2
  done
  if [ -z "$ct_allow" ]; then note "$1: docker exec on the sidecar $ct_proxy said: $(head -c 200 "$WORK/proxy-exec.err")"; fi
  assert_eq "$1: the sidecar is attached to the policy network AND bridge" "$ct_proxy_nets" "bridge $ct_net"
  assert_has "$1: sidecar allow-list has the project host" "$ct_allow" '^host\.docker\.internal$'
  assert_has "$1: sidecar allow-list has the always-allowed provider hosts" "$ct_allow" '^api\.anthropic\.com$'
  assert_not_has "$1: sidecar allow-list does not have the blocked name" "$ct_allow" 'host\.orb\.internal'
  assert_eq "$1: the sandbox container's own environment carries the proxy (what hooks and docker exec run under)" \
    "$(docker exec "$3" sh -c 'echo "$HTTP_PROXY"' 2>/dev/null)" "http://$ct_proxy:3128"
  ct_owner=$(label_of network "$ct_net" foreman.owner)
  assert_true "$1: the policy network carries this server's foreman.owner label ($ct_owner)" test -n "$ct_owner"
  assert_eq "$1: the policy network is labelled foreman.jobsite=$2" "$(label_of network "$ct_net" foreman.jobsite)" "$2"
  assert_eq "$1: the sidecar is labelled with the same owner and jobsite" \
    "$(label_of container "$ct_proxy" foreman.owner)/$(label_of container "$ct_proxy" foreman.jobsite)" "$ct_owner/$2"
  assert_eq "$1: the sandbox is labelled with the same owner and jobsite" \
    "$(label_of container "$3" foreman.owner)/$(label_of container "$3" foreman.jobsite)" "$ct_owner/$2"
}

scenario_allowlist() {
  say "scenario allowlist: --mode allowlist --allow $ALLOWED_HOST"
  note "EXPECTED: allowed host 200, other name 403 and never at the target, bypass has no route, everything removed afterwards"
  set_policy allowlist "$ALLOWED_HOST" || return 0
  jobsite_start net-probe-allowlist "network probe TAG=policy HOLD"
  assert_eq "POST /api/jobsites accepted (202)" "$JOBSITE_CODE" 202
  [ -n "$JOBSITE_ID" ] || { fail "no jobsite id: $(cat "$WORK/jobsite-start.json")"; return 0; }
  note "jobsite $JOBSITE_ID"
  if ! wait_holding "$JOBSITE_ID" 240; then
    fail "allowlist: the probe never reached its hold (jobsite status $(jobsite_status "$JOBSITE_ID"); error $(api_get "/api/jobsites/$JOBSITE_ID" | jq -c '.last_error // null'))"
    return 0
  fi
  AL_SANDBOX=$SANDBOX
  check_allowlist_topology allowlist "$JOBSITE_ID" "$SANDBOX"
  release_probe "$SANDBOX"
  if ! jobsite_wait "$JOBSITE_ID" completed 120; then
    fail "allowlist: jobsite did not complete (status $JOBSITE_STATUS; error $(api_get "/api/jobsites/$JOBSITE_ID" | jq -c '.last_error // null'))"
    return 0
  fi
  pass "allowlist: jobsite $JOBSITE_ID completed"
  out=$(probe_output net-probe-allowlist)
  [ -n "$out" ] || { fail "allowlist: no net-probe.out on branch net-probe-allowlist"; return 0; }
  printf '%s\n' "$out" | while IFS= read -r l; do note "  $l"; done
  assert_has "allowlist: agent env carries the proxy variables the policy computed" "$out" "http_proxy=http://$(proxy_of "$JOBSITE_ID"):3128"
  check_allowlist_probe allowlist "$out" policy
  expect_clean allowlist "$JOBSITE_ID" "$AL_SANDBOX"
}

scenario_none() {
  say "scenario none: --mode none"
  note "EXPECTED: --network none; no request gets out, no network or sidecar exists to leak"
  set_policy none || return 0
  jobsite_start net-probe-none "network probe TAG=none HOLD"
  assert_eq "POST /api/jobsites accepted (202)" "$JOBSITE_CODE" 202
  [ -n "$JOBSITE_ID" ] || { fail "no jobsite id: $(cat "$WORK/jobsite-start.json")"; return 0; }
  note "jobsite $JOBSITE_ID"
  nw=0; NONE_SANDBOX=""
  while [ "$nw" -lt 240 ]; do
    NONE_SANDBOX=$(docker ps -q --filter "ancestor=$IMAGE" --filter network=none 2>/dev/null | head -n 1)
    if [ -n "$NONE_SANDBOX" ] && docker exec "$NONE_SANDBOX" test -e /workspace/.probe-holding 2>/dev/null; then break; fi
    NONE_SANDBOX=""
    case "$(jobsite_status "$JOBSITE_ID")" in failed|cancelled|completed) break ;; esac
    sleep 2; nw=$((nw + 2))
  done
  [ -n "$NONE_SANDBOX" ] || { fail "none: the probe never reached its hold (status $(jobsite_status "$JOBSITE_ID"); error $(api_get "/api/jobsites/$JOBSITE_ID" | jq -c '.last_error // null'))"; return 0; }
  assert_eq "none: docker reports NetworkMode none" "$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$NONE_SANDBOX")" none
  assert_eq "none: the sandbox is attached to the none network only" "$(net_names "$NONE_SANDBOX")" none
  release_probe "$NONE_SANDBOX"
  jobsite_wait "$JOBSITE_ID" completed 120 || { fail "none: jobsite did not complete (status $JOBSITE_STATUS)"; return 0; }
  pass "none: jobsite $JOBSITE_ID completed"
  out=$(probe_output net-probe-none)
  printf '%s\n' "$out" | while IFS= read -r l; do note "  $l"; done
  for label in allowed_via_proxy blocked_via_proxy bypass_by_ip bypass_by_name; do
    assert_eq "none: $label cannot connect" "$(result_code "$(probe_result "$out" "$label")")" 000
  done
  assert_eq "none: no proxy variables in the agent env" "$(printf '%s\n' "$out" | grep '^ENV ' | tr -d ' ')" "ENV"
  for p in allowed blocked bypass-ip bypass-name; do assert_eq "none: the target never saw /none-$p" "$(target_hits "/none-$p")" 0; done
  expect_clean none "$JOBSITE_ID" "$NONE_SANDBOX"
}

# hold_allowlist_jobsite <branch> <tag>: starts an allowlist jobsite and waits until its probe holds
# -> JOBSITE_ID, SANDBOX; 1 when it never gets there
hold_allowlist_jobsite() {
  jobsite_start "$1" "network probe TAG=$2 HOLD"
  if [ "$JOBSITE_CODE" != 202 ] || [ -z "$JOBSITE_ID" ]; then fail "$2: POST /api/jobsites answered $JOBSITE_CODE: $(cat "$WORK/jobsite-start.json")"; return 1; fi
  note "jobsite $JOBSITE_ID"
  if ! wait_holding "$JOBSITE_ID" 240; then
    fail "$2: the probe never reached its hold (status $(jobsite_status "$JOBSITE_ID"); error $(api_get "/api/jobsites/$JOBSITE_ID" | jq -c '.last_error // null'))"
    return 1
  fi
  return 0
}

scenario_cancel() {
  say "scenario cancel: cancelling an in-flight allowlist jobsite"
  note "EXPECTED: status cancelled and the sidecar, network and sandbox removed"
  set_policy allowlist "$ALLOWED_HOST" || return 0
  hold_allowlist_jobsite net-probe-cancel cancel || return 0
  c_sandbox=$SANDBOX; c_id=$JOBSITE_ID
  assert_eq "cancel: the network exists while the jobsite runs" "$(docker network ls -q --filter "name=$(net_of "$c_id")" | wc -l | tr -d ' ')" 1
  assert_eq "POST /api/jobsites/:id/cancel accepted (200)" "$(jobsite_post "$c_id" cancel '{"reason": "e2e network policy"}')" 200
  jobsite_wait "$c_id" "cancelled|failed" 120
  assert_eq "cancel: jobsite status" "$JOBSITE_STATUS" cancelled
  expect_clean cancel "$c_id" "$c_sandbox"
}

scenario_pause_resume() {
  say "scenario pause-resume: pause removes the policy's objects, resume re-applies the policy"
  note "EXPECTED: paused -> nothing left; resumed -> a new network and sidecar with the same enforcement; completed -> nothing left"
  set_policy allowlist "$ALLOWED_HOST" || return 0
  hold_allowlist_jobsite net-probe-pause pause || return 0
  p_sandbox=$SANDBOX; p_id=$JOBSITE_ID
  assert_eq "POST /api/jobsites/:id/pause accepted (200)" "$(jobsite_post "$p_id" pause '{"reason": "e2e network policy"}')" 200
  jobsite_wait "$p_id" "paused|failed|cancelled" 120
  assert_eq "pause: jobsite status" "$JOBSITE_STATUS" paused
  expect_clean paused "$p_id" "$p_sandbox"
  assert_eq "POST /api/jobsites/:id/resume accepted (202)" "$(jobsite_post "$p_id" resume '{"prompt": "Continue. TAG=resumed HOLD"}')" 202
  if ! wait_holding "$p_id" 240; then
    fail "resume: the resumed probe never reached its hold (status $(jobsite_status "$p_id"); error $(api_get "/api/jobsites/$p_id" | jq -c '.last_error // null'))"
    return 0
  fi
  r_sandbox=$SANDBOX
  assert_true "resume: a NEW sandbox container (was $p_sandbox, is $r_sandbox)" test "$r_sandbox" != "$p_sandbox"
  check_allowlist_topology resumed "$p_id" "$r_sandbox"
  release_probe "$r_sandbox"
  jobsite_wait "$p_id" completed 120 || { fail "resume: jobsite did not complete (status $JOBSITE_STATUS)"; return 0; }
  pass "resume: jobsite $p_id completed"
  out=$(probe_output net-probe-pause)
  printf '%s\n' "$out" | while IFS= read -r l; do note "  $l"; done
  check_allowlist_probe resumed "$out" resumed
  expect_clean resumed "$p_id" "$r_sandbox"
}

scenario_hook_env() {
  say "scenario hook-env: a sandbox hook under the allowlist"
  note "EXPECTED: the hook reaches the allowed host through the sidecar (it runs in the same container, under the same policy)"
  set_policy allowlist "$ALLOWED_HOST" || return 0
  hook="curl -sS -m 15 -o /dev/null -w 'hook code=%{http_code}' http://$ALLOWED_HOST:$TARGET_PORT/hook-allowed > /workspace/hook.out 2>&1 || true; cat /workspace/hook.out; echo; grep -q 'code=200' /workspace/hook.out"
  jobsite_start net-probe-hook "network probe TAG=hookagent" "$(jq -n --arg c "$hook" '{hooks: {sandbox: {on_sandbox_ready: [{command: $c}]}}}')"
  if [ "$JOBSITE_CODE" != 202 ] || [ -z "$JOBSITE_ID" ]; then fail "hook-env: POST /api/jobsites answered $JOBSITE_CODE: $(cat "$WORK/jobsite-start.json")"; return 0; fi
  note "jobsite $JOBSITE_ID"
  jobsite_wait "$JOBSITE_ID" "completed|failed|cancelled" 240
  note "hook-env: status $JOBSITE_STATUS; error $(api_get "/api/jobsites/$JOBSITE_ID" | jq -c '.last_error // null' | cut -c1-400)"
  assert_eq "hook-env: the hook reached $ALLOWED_HOST (jobsite completed, hook exited 0)" "$JOBSITE_STATUS" completed
  assert_eq "hook-env: the target saw /hook-allowed exactly once (the hook's own request; the agent's probe has its own TAG)" "$(target_hits /hook-allowed)" 1
  # The hook ran first and then the agent: both are held to the same enforcement.
  out=$(probe_output net-probe-hook)
  printf '%s\n' "$out" | while IFS= read -r l; do note "  $l"; done
  check_allowlist_probe hook-env-agent "$out" hookagent
  expect_clean hook-env "$JOBSITE_ID"
}

scenario_scope() {
  say "scenario scope: another server's sweep leaves an in-flight jobsite alone"
  note "EXPECTED: a sweep for another foreman.owner (the product's own function, run on this server's node) removes nothing of this jobsite"
  set_policy allowlist "$ALLOWED_HOST" || return 0
  hold_allowlist_jobsite net-probe-scope scope || return 0
  s_sandbox=$SANDBOX; s_id=$JOBSITE_ID
  s_before=$(leftovers "$s_id" "$s_sandbox" | sed 's/ ([^)]*)//' | tr '\n' ';')
  note "in flight: $s_before"
  s_out=$(rpc 'ForemanServer.Jobsite.NetworkPolicy.sweep_orphans(owner: "another-server"); IO.puts("SWEPT")' | tail -n 1)
  assert_eq "scope: the sweep for another owner ran on the server" "$s_out" SWEPT
  assert_eq "scope: the in-flight jobsite's sidecar, network and sandbox are all still there" "$(leftovers "$s_id" "$s_sandbox" | sed 's/ ([^)]*)//' | tr '\n' ';')" "$s_before"
  assert_true "scope: the sandbox is still running its probe" docker exec "$s_sandbox" test -e /workspace/.probe-holding
  release_probe "$s_sandbox"
  if ! jobsite_wait "$s_id" completed 120; then
    fail "scope: jobsite did not complete (status $JOBSITE_STATUS; error $(api_get "/api/jobsites/$s_id" | jq -c '.last_error // null'))"
    return 0
  fi
  pass "scope: jobsite $s_id completed after the other owner's sweep"
  expect_clean scope "$s_id" "$s_sandbox"
}

scenario_crash() {
  say "scenario crash: kill -9 of the server with an allowlist jobsite in flight, then a restart"
  note "EXPECTED: the boot sweep removes the jobsite's sidecar, network AND the sandbox container that outlived the server; the orphaned jobsite then resumes under the same policy"
  set_policy allowlist "$ALLOWED_HOST" || return 0
  hold_allowlist_jobsite net-probe-crash crash || return 0
  k_sandbox=$SANDBOX; k_id=$JOBSITE_ID
  note "before the crash: $(leftovers "$k_id" "$k_sandbox" | tr '\n' ';')"
  k_old=$SERVER_PID
  k_tree=$(descendants "$k_old")
  # shellcheck disable=SC2086
  kill -9 $k_tree "$k_old" 2>/dev/null
  SERVER_PID=""
  sleep 2
  note "after the crash, before the restart: $(leftovers "$k_id" "$k_sandbox" | tr '\n' ';')"
  start_server
  expect_clean "after restart (boot sweep)" "$k_id" "$k_sandbox"
  jobsite_wait "$k_id" "paused|failed|completed|cancelled" 60
  assert_eq "crash: the jobsite the crash orphaned is recorded paused (resumable)" "$JOBSITE_STATUS" paused
  [ "$JOBSITE_STATUS" = paused ] || return 0
  # A leaked network would fail the policy's `network create` under the same name here.
  assert_eq "POST /api/jobsites/:id/resume accepted (202)" "$(jobsite_post "$k_id" resume '{"prompt": "Continue. TAG=crashresumed HOLD"}')" 202
  if ! wait_holding "$k_id" 240; then
    fail "crash: the resumed probe never reached its hold (status $(jobsite_status "$k_id"); error $(api_get "/api/jobsites/$k_id" | jq -c '.last_error // null'))"
    return 0
  fi
  kr_sandbox=$SANDBOX
  assert_true "crash: the resume runs in a NEW sandbox container (was $k_sandbox, is $kr_sandbox)" test "$kr_sandbox" != "$k_sandbox"
  check_allowlist_topology crash-resumed "$k_id" "$kr_sandbox"
  release_probe "$kr_sandbox"
  if ! jobsite_wait "$k_id" completed 120; then
    fail "crash: the resumed jobsite did not complete (status $JOBSITE_STATUS; error $(api_get "/api/jobsites/$k_id" | jq -c '.last_error // null'))"
    return 0
  fi
  pass "crash: resumed jobsite $k_id completed"
  out=$(probe_output net-probe-crash)
  printf '%s\n' "$out" | while IFS= read -r l; do note "  $l"; done
  check_allowlist_probe crash-resumed "$out" crashresumed
  expect_clean crash-resumed "$k_id" "$kr_sandbox"
}

# ---------------------------------------------------------------- main

check_environment
command -v docker >/dev/null 2>&1 || die "'docker' is required on PATH" 1
install_traps
trap 'net_exit; cleanup' EXIT

if ! docker_ready; then
  say "docker"
  unverified "in-container network policy enforcement" "no usable docker daemon: docker info says: ${DOCKER_UNAVAILABLE:-nothing}"
  summary
  exit $?
fi
note "docker $(docker version --format '{{.Server.Version}} on {{.Server.Os}}/{{.Server.Arch}}') context $(docker context show 2>/dev/null)"

setup_stack
register_project || { tail -n 5 "$WORK/project-create.out"; die "cannot register the project" 2; }
note "project $PROJECT registered over $REPO"

if ! setup_probe_assets; then
  summary
  exit $?
fi

# (scenarios run in the order given)
for s in $SCENARIOS; do
  case "$s" in
    control) scenario_control ;;
    allowlist) scenario_allowlist ;;
    none) scenario_none ;;
    cancel) scenario_cancel ;;
    pause-resume) scenario_pause_resume ;;
    hook-env) scenario_hook_env ;;
    scope) scenario_scope ;;
    crash) scenario_crash ;;
  esac
done

say "server log"
note "docker-related lines: $(grep -i -E 'network_policy|network policy|foreman-jobsite|egress' "$SERVER_LOG" | cut -c1-200 | head -n 5 | tr '\n' '|')"
summary
exit $?
