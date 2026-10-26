#!/bin/sh
# The "tool call" of scripts/e2e/network_policy_flow.sh. fake-pi runs it INSIDE the jobsite container, in
# /workspace, with the agent env-file's environment. Template: the flow script substitutes @PORT@ (the
# local target's port), @HOST_IP@ (the host's address as a container sees it) and @BLOCKED_HOST@, then
# commits the result to the scratch repo so every jobsite worktree carries it.
#
# Four requests, all to a tiny HTTP server on the host that logs what actually reaches it:
#   allowed_via_proxy  host.docker.internal (on the project's allowlist), through HTTP_PROXY
#   blocked_via_proxy  @BLOCKED_HOST@ (a name for the SAME server that is NOT on the allowlist), through HTTP_PROXY
#   bypass_by_ip       the allowed server's IP, proxy bypassed (--noproxy '*'): there must be no route
#   bypass_by_name     the allowed host's NAME, proxy bypassed: there must be no DNS either
# PROBE_TAG (default "policy") prefixes the request paths so the target's log tells runs apart.
TAG=${PROBE_TAG:-policy}
ALLOWED="http://host.docker.internal:@PORT@/$TAG-allowed"
BLOCKED="http://@BLOCKED_HOST@:@PORT@/$TAG-blocked"
BYPASS_IP="http://@HOST_IP@:@PORT@/$TAG-bypass-ip"
BYPASS_NAME="http://host.docker.internal:@PORT@/$TAG-bypass-name"

# A resumed jobsite keeps its worktree: markers of the interrupted run must not satisfy this run.
rm -f /workspace/.probe-holding /workspace/.probe-release

probe() { # <label> <url> [curl flags]
  label=$1; url=$2; shift 2
  rm -f /tmp/probe.body /tmp/probe.err
  code=$(curl -sS -m 15 -o /tmp/probe.body -w '%{http_code}' "$@" "$url" 2>/tmp/probe.err)
  rc=$?
  body=$(head -c 110 /tmp/probe.body 2>/dev/null | tr -d '\r' | tr '\n' ' ')
  err=$(head -c 200 /tmp/probe.err 2>/dev/null | tr '\n' ' ')
  echo "RESULT $label rc=$rc code=$code body=[$body] err=[$err]"
}

echo "ENV $(env | grep -i -E '^(http|https|no)_proxy=' | sort | tr '\n' ' ')"
echo "TOPO routes=$(tail -n +2 /proc/net/route | wc -l | tr -d ' ') addrs=[$(ip -o -4 addr show 2>/dev/null | awk '{print $2 "=" $4}' | tr '\n' ' ')]"

probe allowed_via_proxy "$ALLOWED"
probe blocked_via_proxy "$BLOCKED"
probe bypass_by_ip "$BYPASS_IP" --noproxy '*'
probe bypass_by_name "$BYPASS_NAME" --noproxy '*'

if [ -n "${PROBE_HOLD:-}" ]; then
  : > /workspace/.probe-holding
  echo "HOLD waiting for /workspace/.probe-release"
  n=0
  while [ ! -e /workspace/.probe-release ] && [ "$n" -lt 300 ]; do sleep 1; n=$((n + 1)); done
  rm -f /workspace/.probe-release /workspace/.probe-holding
  echo "HOLD released after ${n}s"
fi
