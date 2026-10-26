#!/usr/bin/env bash
# Notification-sink assertions for scripts/e2e/claude_projects_flow.sh (step 6). Sourced by the flow;
# executed directly it runs only the stack-free self-test:  bash scripts/e2e/claude_projects/notifications.sh
#
# The sink (webhook_listener.py) appends one JSON line per delivery: {"at": ..., "body": <webhook body>}
# where the body is ForemanServer.Messaging.Providers.Webhook.build_request/3's map (`event_class`
# is the Notifier.Mapping class: failure, stall, run_update, action_needed; `run_id` the run).
#
# "The sink received >= 1 delivery" passes for ANY class of ANY run, so a flow whose runs never
# produced their own notification still passed. The assertion this file provides is the specific
# delivery a finished run owes the sink: class run_update, for THAT run id.

# delivery_count <capture.jsonl> <event_class> <run_id>: how many deliveries carry that class AND run id.
# A missing or empty capture, and a line that is not a JSON object, count as nothing.
delivery_count() {
  if [ ! -s "$1" ]; then echo 0; return 0; fi
  jq -R -s -r --arg class "$2" --arg run "$3" '
    [split("\n")[] | select(length > 0) | (try fromjson catch null)
     | select(type == "object" and (.body | type) == "object"
              and .body.event_class == $class and .body.run_id == $run)]
    | length' "$1" 2>/dev/null || echo 0
}

# notifications_selftest: proves the assertion can fail. A delivery of another class, of another run, an
# empty sink and garbage lines must all report 0; only the matching delivery is counted.
notifications_selftest() {
  say "6.0 notification assertion self-test (the check must be able to fail)"
  nt=$(mktemp "${TMPDIR:-/tmp}/notifications-selftest.XXXXXX") || return 1
  : > "$nt"
  assert_eq "an empty sink holds no delivery for the run" "$(delivery_count "$nt" run_update run-1)" "0"
  assert_eq "a missing capture file holds no delivery" "$(delivery_count "$nt.absent" run_update run-1)" "0"

  printf '%s\n' '{"at":"2026-10-25T00:00:00+00:00","body":{"event_class":"failure","run_id":"run-1","subject":"Run failed"}}' >> "$nt"
  assert_eq "a failure delivery for the run is not a run_update" "$(delivery_count "$nt" run_update run-1)" "0"
  printf '%s\n' '{"at":"2026-10-25T00:00:01+00:00","body":{"event_class":"run_update","run_id":"run-2","subject":"Run completed"}}' >> "$nt"
  assert_eq "a run_update for ANOTHER run does not satisfy the run" "$(delivery_count "$nt" run_update run-1)" "0"
  printf '%s\n' 'not json at all' '{"at":"x","body":"a string body"}' '{"unparsed":"raw"}' '{"at":"x","body":{"unparsed":"raw"}}' >> "$nt"
  assert_eq "garbage and unparsed sink lines are ignored" "$(delivery_count "$nt" run_update run-1)" "0"

  printf '%s\n' '{"at":"2026-10-25T00:00:02+00:00","body":{"event_class":"run_update","run_id":"run-1","subject":"Run completed"}}' >> "$nt"
  assert_eq "the run's own run_update delivery is found" "$(delivery_count "$nt" run_update run-1)" "1"
  assert_eq "the other run's delivery is still its own" "$(delivery_count "$nt" run_update run-2)" "1"
  assert_eq "the class is matched exactly" "$(delivery_count "$nt" run_updat run-1)" "0"
  printf '%s\n' '{"at":"2026-10-25T00:00:03+00:00","body":{"event_class":"run_update","run_id":"run-1","subject":"Review recorded"}}' >> "$nt"
  assert_eq "every matching delivery is counted" "$(delivery_count "$nt" run_update run-1)" "2"
  rm -f "$nt"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
  # shellcheck source=lib.sh
  . "$(dirname "$0")/lib.sh"
  notifications_selftest
  summary
  exit $?
fi
