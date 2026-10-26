#!/usr/bin/env bash
# scripts/e2e/multi_repo_agent.sh
#
# Live proof, with a REAL agent, of the multi-repository paths that scripts/e2e/multi_repo.sh does not drive
# (bead foreman-he4yf): per-phase repository selection, a thread adding a repository to its own run, and goal
# fan-out; plus the typed refusal of a multi-repository jobsite. The agent is claude (haiku) by default, or
# pi + MiniMax with E2E_PROVIDER=pi. It reaches Foreman the way an operator's agent does: through Foreman's own
# HTTP MCP endpoint (/mcp), configured as a user-scope MCP server of the agent (claude: $WORK/home/.claude.json;
# pi: $WORK/pi-agent/mcp.json). Nothing is simulated except GitHub: a recording fake `gh`
# (scripts/e2e/multi_repo/fake-gh) and local bare origins; real GitHub is never touched. The server is booted
# the way every live harness boots it (`mix run --no-start --no-halt`, not `mix phx.server`), which is exactly
# what foreman-cnn1l broke (/mcp answered HTTP 500 there): setup asserts `initialize` answers 200 first.
#
# Stages (E2E_STAGES, space separated, default "phases fanout jobsite"; `setup` and the closing `strays` always run):
#
#   phases  ONE task over the project's primary repository (no repo_ids). Phase 1's agent records its own
#           $FOREMAN_REPOS, then calls the MCP tool foreman_run_request_repo twice (the registered repository b by
#           repo_id; the git checkout c, not registered, by repo_path). Phase 2's agent records ITS $FOREMAN_REPOS
#           and writes a file into every repository it lists. Asserted: phase 1's environment and prompt list
#           only the primary although the worktrees of b and c were created DURING phase 1 (event times);
#           phase 2's environment, prompt and edits cover all three; both requests are audited as allowed
#           (run_repo_audit:<run>); three branches pushed, three PRs; the agent's own transcript shows the calls.
#   fanout  A run's agent calls foreman_task_fanout for "all" repositories and then repeats the identical call.
#           Asserted: one open task <fanout_id>-<repo_id> per registered repository, each carrying the
#           fan-out source, and no duplicate (the repeat returns the same task ids: the tool's own answers are
#           read from the agent's transcript); then the operator approves them and every single-repository
#           run completes with its own branch and PR.
#   jobsite POST /api/jobsites with a `repositories` key is refused: 403 spec_forbidden_key, "multi-repo
#           jobsites unsupported" (by design, docs/spikes/S3.md), and no jobsite starts.
#
# Run it from a devbox shell:
#
#     devbox run -- bash scripts/e2e/multi_repo_agent.sh
#
# Environment (all optional): E2E_PROVIDER (claude | pi, default claude), E2E_AGENT_MODEL (default haiku for
# claude, minimax/MiniMax-M2.7-highspeed for pi), E2E_STAGES, E2E_WORK_DIR (default <repo>/tmp/e2e-multi-repo-agent;
# never /tmp), E2E_DB_NAME (default foreman_e2e_multi_repo_agent), E2E_PORT, E2E_HOOK_PORT, E2E_RUN_TIMEOUT,
# E2E_POLL_SECS, E2E_TRANSCRIPT, E2E_KEEP=1 (keep the server, database and work dir), and the
# E2E_PG_* / E2E_API_TOKEN settings of scripts/e2e/claude_projects/lib.sh.
#
# Exit status: 0 every assertion passed; 1 environment problem; 2 setup failed; 3 an assertion failed.
# A claude that is not logged in (or no claude binary) records UNVERIFIED, never a pass.

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
E2E_NAME=${E2E_NAME:-mra}
E2E_WORK_DIR=${E2E_WORK_DIR:-$ROOT/tmp/e2e-multi-repo-agent}
E2E_DB_NAME=${E2E_DB_NAME:-foreman_e2e_multi_repo_agent}
E2E_PROVIDER=${E2E_PROVIDER:-claude}
E2E_STAGES=${E2E_STAGES:-"phases fanout jobsite"}
# shellcheck source=claude_projects/lib.sh
. "$HERE/claude_projects/lib.sh"
# shellcheck source=claude_projects/claude_home.sh
. "$HERE/claude_projects/claude_home.sh"

case "$E2E_PROVIDER" in
  claude) E2E_AGENT_MODEL=${E2E_AGENT_MODEL:-haiku} ;;
  pi) E2E_AGENT_MODEL=${E2E_AGENT_MODEL:-minimax/MiniMax-M2.7-highspeed} ;;
  *) die "E2E_PROVIDER must be claude or pi (got '$E2E_PROVIDER')" 1 ;;
esac
case "$E2E_STAGES" in *[!a-z\ ]*) die "E2E_STAGES may only name stages (phases fanout jobsite)" 1 ;; esac
for stage in $E2E_STAGES; do
  case "$stage" in phases|fanout|jobsite) ;; *) die "unknown stage '$stage'" 1 ;; esac
done

REPO_B="$WORK/repo-b"
ORIGIN_B="$WORK/origin-b.git"
REPO_C="$WORK/repo-c"
ORIGIN_C="$WORK/origin-c.git"
FAKEBIN="$WORK/fakebin"
GH_STATE="$WORK/gh"
CALLS="$GH_STATE/calls.log"
TAB=$(printf '\t')

check_environment
install_traps

# ---------------------------------------------------------------- building blocks

# api_post <json envelope> -> API_CODE, API_BODY
api_post() {
  API_CODE=$(curl -sS -o "$WORK/last.body" -w '%{http_code}' --max-time 60 -X POST "$API/api/commands" \
    -H "authorization: Bearer $E2E_API_TOKEN" -H 'content-type: application/json' -d "$1")
  API_BODY=$(cat "$WORK/last.body")
}

# task_json <task id> <title> <prompt> <workflow>
task_json() {
  jq -nc --arg t "$1" --arg ti "$2" --arg pr "$3" --arg wf "$4" --arg p "$PROJECT" \
    '{type: "task.create",
      payload: {task_id: $t, project_id: $p, task_type: "task", workflow_type: $wf, title: $ti,
                prompt: $pr, provider_tracked: false, auto_approve: true}}'
}

# await_run <task id> -> RUN (empty after ~90 s without a run)
await_run() {
  ar_n=0; RUN=""
  while [ -z "$RUN" ] && [ "$ar_n" -lt 90 ]; do
    RUN=$(api_get "/api/runs?project_id=$PROJECT" | jq -r --arg t "$1" '[.runs[]? | select(.task_id == $t)][0].run_id // empty')
    [ -n "$RUN" ] || sleep 1
    ar_n=$((ar_n + 1))
  done
}

# wait_run <run id> -> RUN_STATUS (the last `foreman run get`), RUN_JSON
wait_run() {
  wr_run=$1; wr_start=$(date +%s); wr_last=""; RUN_JSON=""
  while :; do
    if RUN_JSON=$(fm run get "$wr_run" 2>"$WORK/run-get.err"); then
      RUN_STATUS=$(printf '%s' "$RUN_JSON" | jq -r '.run.status // empty')
    else
      RUN_STATUS="get-failed: $(tr '\n' ' ' < "$WORK/run-get.err" | cut -c1-160)"
    fi
    if [ "$RUN_STATUS" != "$wr_last" ]; then
      note "run $wr_run: ${RUN_STATUS:-<none>} (+$(elapsed "$wr_start")s)"
      wr_last=$RUN_STATUS
    fi
    case "$RUN_STATUS" in completed|failed|cancelled|blocked|stuck|deleted) return 0 ;; esac
    if [ "$(elapsed "$wr_start")" -ge "$E2E_RUN_TIMEOUT" ]; then RUN_STATUS="timeout"; return 1; fi
    sleep "$E2E_POLL_SECS"
  done
}

diagnose_run() { # <run id>: what a post-mortem of a failed stage needs
  out "   --- run projection: $(api_get "/api/runs/$1" | jq -c '.run | {status, failure_reason, pr_url, pr_urls, repo_ids}' 2>/dev/null)"
  out "   --- server log (errors and warnings, last 25 lines):"
  grep -E '\[(error|warning)\]' "$SERVER_LOG" 2>/dev/null | tail -n 25 | cut -c1-300 | while IFS= read -r l; do out "   $l"; done
}

origin_of() { case "$1" in main) echo "$ORIGIN" ;; b) echo "$ORIGIN_B" ;; *) echo "$ORIGIN_C" ;; esac; }
# origin_file <repo id> <branch> <path>: the file as committed on the pushed branch (empty when absent)
origin_file() { git --git-dir="$(origin_of "$1")" show "$2:$3" 2>/dev/null; }
origin_branch_sha() { git --git-dir="$(origin_of "$1")" rev-parse --verify -q "refs/heads/$2" 2>/dev/null; }
gh_calls() { grep -c -- "$1" "$CALLS" 2>/dev/null || true; }
yes_no() { if [ -n "$1" ]; then echo yes; else echo no; fi; }

# agent_calls <run id> <tool name>: the tool calls the agent itself made, from ITS OWN transcript.
# claude: the session file (the project directory name carries the run id); pi: the session jsonl.
agent_calls() {
  ac_files=""
  if [ "$E2E_PROVIDER" = claude ]; then
    ac_files=$(claude_session_files "$1")
    for f in $ac_files; do claude_tool_calls "$f"; done | jq -c --arg n "mcp__foreman__foreman_$2" 'select(.name == $n) | .input'
  else
    ac_files=$(find "$WORK/pi-agent/sessions" -path "*$1*" -name '*.jsonl' 2>/dev/null)
    for f in $ac_files; do
      jq -c --arg n "foreman_$2" '
        select(.type == "message" and .message.role == "assistant") | .message.content[]?
        | select(.type == "toolCall" and ((.name // "") | test($n))) | .arguments' "$f" 2>/dev/null
    done
  fi
}

# agent_results <run id> <tool name>: what each call of the tool RETURNED to the agent (the text of its tool
# result: the tool's JSON), one line per call in call order, from the agent's own transcript.
agent_results() {
  if [ "$E2E_PROVIDER" = claude ]; then
    for f in $(claude_session_files "$1"); do
      jq -rs --arg n "mcp__foreman__foreman_$2" '
        [.[] | select(.type == "assistant") | .message.content[]? | select(.type == "tool_use" and .name == $n) | .id] as $ids
        | [.[] | select(.type == "user") | .message.content | arrays | .[] | select(.type == "tool_result")] as $results
        | $ids[] as $id
        | ($results[] | select(.tool_use_id == $id) | [.content[]? | select(.type == "text") | .text] | join(""))' "$f" 2>/dev/null
    done
  else
    for f in $(find "$WORK/pi-agent/sessions" -path "*$1*" -name '*.jsonl' 2>/dev/null); do
      jq -rs --arg n "foreman_$2" '
        [.[] | select(.type == "message" and .message.role == "assistant") | .message.content[]?
          | select(.type == "toolCall" and ((.name // "") | test($n))) | .id] as $ids
        | [.[] | select(.type == "message" and .message.role == "toolResult") | .message] as $results
        | $ids[] as $id
        | ($results[] | select(.toolCallId == $id) | [.content[]? | select(.type == "text") | .text] | join(""))' "$f" 2>/dev/null
    done
  fi
}

# ---------------------------------------------------------------- setup

write_workflows() {
  mkdir -p "$WORK/workflows/prompts"
  if [ "$E2E_PROVIDER" = claude ]; then
    agent_yaml="    provider: claude
    approval_mode: auto_approve
    models:
      default: $E2E_AGENT_MODEL"
  else
    agent_yaml="    provider: pi
    models:
      default: $E2E_AGENT_MODEL"
  fi
  # `task_types` must be unique across the catalog (the harness's own `edit` workflow already owns task,
  # bug, chore and feature), so each workflow here gets a type of its own; tasks name their workflow
  # explicitly (`workflow_type`), which is also how `foreman_task_fanout` addresses it.
  for spec in "repo-phases:attach edit" "repo-fanout-call:call" "repo-one:edit"; do
    wf=${spec%%:*}
    {
      printf 'name: %s\ndescription: E2E workflow of scripts/e2e/multi_repo_agent.sh\ntask_types: [mra-%s]\n' "$wf" "$wf"
      printf 'worktree:\n  enabled: true\n  branch: foreman/{task_id}/{run_id}\n  path: workspace\n  cleanup: on_success\nphases:\n'
      for ph in ${spec#*:}; do
        printf '  - name: %s\n    prompt: %s-%s.md\n%s\n    commit: true\n' "$ph" "$wf" "$ph" "$agent_yaml"
      done
    } > "$WORK/workflows/$wf.yaml"
  done

  cat > "$WORK/workflows/prompts/repo-phases-attach.md" <<'MD'
{{workflow_name}} :: {{phase_name}} (phase 1 of 2)

## Task

{{input.prompt}}

## Steps (do them in this order, exactly; run every command from your current working directory)

1. Run the shell command: `printenv FOREMAN_REPOS > phase1-repos.json`
2. Run the shell command: `printf '%s\n' '{{repositories_count}}' > phase1-count.txt`
3. Call the MCP tool `foreman_run_request_repo` of the `foreman` MCP server once for EACH repository named in the
   Task, always with `run_id` `{{run_id}}`; give `repo_id` for a registered repository and `repo_path` for a path.
4. Do not touch any other file. Reply with exactly: done
MD
  cat > "$WORK/workflows/prompts/repo-phases-edit.md" <<'MD'
{{workflow_name}} :: {{phase_name}} (phase 2 of 2)

This phase has {{repositories_count}} repositories. Their checkouts, as JSON (`path` is the directory to edit;
`primary: true` is your current working directory):

{{repositories}}

## Steps (do them in this order, exactly)

1. In your current working directory run the shell command: `printenv FOREMAN_REPOS > phase2-repos.json`
2. In your current working directory run the shell command: `printf '%s\n' '{{repositories_count}}' > phase2-count.txt`
3. For EVERY repository in the JSON above create a file named `PHASE2` in that repository's `path`, containing
   exactly `phase2-` followed by the repository's `id` and a newline (for example `phase2-main`). Use the absolute
   `path` for every repository other than your current working directory.
4. Do not touch any other file, and do not run git. Reply with exactly: done
MD
  cat > "$WORK/workflows/prompts/repo-fanout-call-call.md" <<'MD'
{{workflow_name}} :: {{phase_name}}

## Task

{{input.prompt}}

## Rules

- Use only the MCP tools of the `foreman` MCP server that the Task names. Do not edit any file and do not run git.
- Reply with exactly: done
MD
  cat > "$WORK/workflows/prompts/repo-one-edit.md" <<'MD'
{{workflow_name}} :: {{phase_name}}

## Task

{{input.prompt}}

## Rules

- Work only inside the current working directory (a git worktree). Do NOT run git: Foreman commits when you finish.
- When finished, reply with exactly: done
MD
}

setup_repos_and_gh() {
  make_repo "$REPO_B" "$ORIGIN_B" || die "cannot create scratch repository b" 2
  make_repo "$REPO_C" "$ORIGIN_C" || die "cannot create scratch repository c" 2
  mkdir -p "$FAKEBIN" "$GH_STATE"
  cp "$HERE/multi_repo/fake-gh" "$FAKEBIN/gh"
  chmod +x "$FAKEBIN/gh"
  note "repositories: $REPO (primary, id main)  $REPO_B (b)  $REPO_C (c, never registered by the operator); local bare origins, fake gh first on the server PATH"
}

# agent_access: how the agent reaches Foreman's MCP endpoint (and, for claude, a stock login)
agent_access() {
  mcp_url="$API/mcp"
  if [ "$E2E_PROVIDER" = claude ]; then
    claude_private_home foreman "$mcp_url" "$E2E_API_TOKEN" || { out "fatal: $CLAUDE_UNAVAILABLE"; exit 1; }
    if ! claude_ready; then
      unverified "$E2E_STAGES with a real claude" "$CLAUDE_UNAVAILABLE"
      summary
      exit $?
    fi
    note "claude answers through $WORK/home (private .claude, copied .claude.json + user-scope MCP server foreman -> $mcp_url)"
  else
    (cd "$WORK" && PI_CODING_AGENT_DIR="$WORK/pi-agent" pi mcp add foreman --url "$mcp_url" \
      --header "Authorization=Bearer $E2E_API_TOKEN" --exposure direct >"$WORK/pi-mcp-add.log" 2>&1) \
      || { tail -n 5 "$WORK/pi-mcp-add.log"; die "pi mcp add failed" 2; }
    note "pi agent dir $WORK/pi-agent has the MCP server foreman -> $mcp_url (exposure direct)"
  fi
}

# check_mcp_endpoint: foreman-cnn1l. On a server booted the way every live harness boots it (`mix run --no-start
# --no-halt`, not `mix phx.server`) Anubis skipped its supervisor and /mcp answered HTTP 500 to every request, so
# no agent could call a Foreman tool. Every stage below needs it: stop here when it is down.
check_mcp_endpoint() {
  mcp_code=$(curl -sS -o "$WORK/mcp-initialize.body" -w '%{http_code}' --max-time 30 -X POST "$API/mcp" \
    -H "authorization: Bearer $E2E_API_TOKEN" -H 'content-type: application/json' -H 'accept: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"multi-repo-agent-e2e","version":"1"}}}')
  assert_eq "/mcp answers initialize with HTTP 200 on this harness-booted server (foreman-cnn1l: it answered 500)" "$mcp_code" "200"
  assert_eq "/mcp initialize names the Foreman MCP server" "$(jq -r '.result.serverInfo.name // empty' "$WORK/mcp-initialize.body" 2>/dev/null)" "foreman-mcp"
  if [ "$mcp_code" != 200 ]; then
    out "   $(head -c 400 "$WORK/mcp-initialize.body" | tr '\n' ' ')"
    summary
    exit $?
  fi
}

setup_all() {
  E2E_PATH_PREFIX="$FAKEBIN"
  # No review analysis: it would start a second agent per terminal run (and may file gap beads).
  # Remote jobsite start on: the `jobsite` stage needs the request to reach spec validation (it never starts one).
  E2E_EXTRA_ENV="E2E_GH_STATE=$GH_STATE E2E_REVIEW_ANALYSIS=0 FOREMAN_JOBSITES_ALLOW_REMOTE_START=true"
  setup_stack
  setup_repos_and_gh
  write_workflows
  agent_access
  note "restarting the server so it loads the workflows and the new PATH entries"
  stop_server
  start_server
  api_post "$(jq -nc --arg p "$PROJECT" --arg path "$REPO" '{type: "project.register", payload: {project_id: $p, name: $p, path: $path, status: "active"}}')"
  [ "$API_CODE" = 201 ] || die "project.register $PROJECT: HTTP $API_CODE $API_BODY" 2
  fm project repo add --id b --path "$REPO_B" "$PROJECT" >/dev/null || die "foreman project repo add b failed" 2
  api_post "$(jq -nc --arg p "$PROJECT" --arg root "$WORK" '{type: "project.update", payload: {project_id: $p, repo_allowlist: [$root]}}')"
  [ "$API_CODE" = 200 ] || [ "$API_CODE" = 201 ] || [ "$API_CODE" = 202 ] || die "project.update repo_allowlist: HTTP $API_CODE $API_BODY" 2
  note "project $PROJECT over $REPO; repositories: $(api_get "/api/projects/$PROJECT/repositories" | jq -c '[.repositories[]? | {id, primary}]'); repo_allowlist=[$WORK]"
  check_mcp_endpoint
  rpc "Code.require_file(\"$HERE/multi_repo/agent_probe.exs\")" >/dev/null
}

# ---------------------------------------------------------------- stage: phases

stage_phases() {
  say "phases: one run, two phases; phase 1 asks for b (repo_id) and c (repo_path), phase 2 works in all three"
  PH_TASK="phases-task-$SUFFIX"
  ph_prompt="Add these repositories to this run: the registered repository with repo_id b, and the git checkout at the path $REPO_C (it is not registered with the project)."
  t0=$(date +%s)
  api_post "$(task_json "$PH_TASK" "E2E: per-phase repository selection" "$ph_prompt" repo-phases)"
  assert_eq "task.create (primary repository only, no repo_ids)" "$API_CODE" "201"
  await_run "$PH_TASK"
  PH_RUN=$RUN
  [ -n "$PH_RUN" ] || { fail "phases: no run was created for task $PH_TASK"; return 0; }
  note "run id: $PH_RUN"
  wait_run "$PH_RUN"
  note "terminal status '$RUN_STATUS' after $(elapsed "$t0")s"
  if [ "$RUN_STATUS" != completed ]; then
    fail "phases: run reached '$RUN_STATUS', expected 'completed'"
    diagnose_run "$PH_RUN"
    return 0
  fi
  pass "phases: run completed"
  PH_BRANCH="foreman/$PH_TASK/$PH_RUN"

  # --- the audit stream and the order of events: the requests were allowed, the worktrees appeared during phase 1
  timeline=$(rpc "E2EAgentRepoProbe.timeline(\"$PH_RUN\")" | grep '^\[' | tail -n 1)
  out "   timeline: $(printf '%s' "$timeline" | jq -c '[.[] | select(.type | test("^(PhaseStarted|PhaseCompleted|WorktreeCreated|RunRepoRequested)$")) | {type, repo_id, index, decision, reason, at_ms}]')"
  assert_eq "audit: RunRepoRequested events (one per request the agent made)" \
    "$(printf '%s' "$timeline" | jq '[.[] | select(.type == "RunRepoRequested")] | length')" "2"
  assert_eq "audit: both requests were allowed" \
    "$(printf '%s' "$timeline" | jq -c '[.[] | select(.type == "RunRepoRequested") | .decision] | unique')" '["allowed"]'
  assert_eq "audit: requested by the run itself" \
    "$(printf '%s' "$timeline" | jq -r '[.[] | select(.type == "RunRepoRequested") | .requested_by] | unique | join(",")')" "run:$PH_RUN"
  C_ID=$(printf '%s' "$timeline" | jq -r '[.[] | select(.type == "RunRepoRequested" and .repo_id != "b") | .repo_id][0] // empty')
  note "repository c was registered by the request under the id '$C_ID'"
  assert_eq "audit: the registered repository was requested by repo_id" \
    "$(printf '%s' "$timeline" | jq -r '[.[] | select(.type == "RunRepoRequested" and .repo_id == "b")] | length')" "1"
  p1_start=$(printf '%s' "$timeline" | jq '[.[] | select(.type == "PhaseStarted" and .index == 1)][0].at_ms')
  p1_end=$(printf '%s' "$timeline" | jq '[.[] | select(.type == "PhaseCompleted" and .index == 1)][0].at_ms')
  p2_start=$(printf '%s' "$timeline" | jq '[.[] | select(.type == "PhaseStarted" and .index == 2)][0].at_ms')
  for id in b "$C_ID"; do
    wt=$(printf '%s' "$timeline" | jq --arg id "$id" '[.[] | select(.type == "WorktreeCreated" and .repo_id == $id)][0].at_ms')
    if [ -n "$id" ] && [ "$wt" != null ] && [ "$wt" -ge "$p1_start" ] && [ "$wt" -le "$p1_end" ]; then
      pass "worktree of '$id' was created DURING phase 1 (phase 1 $p1_start..$p1_end, worktree $wt)"
    else
      fail "worktree of '$id': created at $wt, expected between the start ($p1_start) and the end ($p1_end) of phase 1"
    fi
  done
  assert_eq "phase 2 started after phase 1 completed" "$([ "$p2_start" != null ] && [ "$p2_start" -ge "$p1_end" ] && echo yes || echo no)" "yes"

  # --- what each phase saw: the files the agents wrote from their own environment, committed on the branches
  p1=$(origin_file main "$PH_BRANCH" phase1-repos.json)
  p2=$(origin_file main "$PH_BRANCH" phase2-repos.json)
  out "   phase 1 \$FOREMAN_REPOS (as the agent captured it): $(printf '%s' "$p1" | cut -c1-300)"
  out "   phase 2 \$FOREMAN_REPOS (as the agent captured it): $(printf '%s' "$p2" | cut -c1-500)"
  assert_eq "phase 1 environment: FOREMAN_REPOS lists ONLY the primary" "$(printf '%s' "$p1" | jq -c 'keys' 2>/dev/null)" '["main"]'
  assert_eq "phase 2 environment: FOREMAN_REPOS lists the primary and both requested repositories" \
    "$(printf '%s' "$p2" | jq -c 'keys' 2>/dev/null)" "$(jq -nc --arg c "$C_ID" '["b", $c, "main"] | sort')"
  case "$(printf '%s' "$p2" | jq -r '.b.path' 2>/dev/null)" in */"$PH_RUN"/repos/b) pass "phase 2: b's checkout is <run>/repos/b" ;; *) fail "phase 2: b's path: $(printf '%s' "$p2" | jq -r '.b.path' 2>/dev/null)" ;; esac
  assert_content_exactly "phase 1 prompt: {{repositories_count}} rendered as" "$(origin_file main "$PH_BRANCH" phase1-count.txt)" "1"
  assert_content_exactly "phase 2 prompt: {{repositories_count}} rendered as" "$(origin_file main "$PH_BRANCH" phase2-count.txt)" "3"
  for id in main b "$C_ID"; do
    assert_content_exactly "phase 2 edit reached repository '$id' (committed on its pushed branch)" \
      "$(origin_file "$([ "$id" = main ] || [ "$id" = b ] && echo "$id" || echo c)" "$PH_BRANCH" PHASE2)" "phase2-$id"
  done
  assert_eq "phase 1 wrote nothing into b or c (they only became visible in phase 2)" \
    "$(yes_no "$(origin_file b "$PH_BRANCH" phase1-repos.json)$(origin_file c "$PH_BRANCH" phase1-repos.json)")" "no"

  # --- PRs: one per repository
  assert_eq "pr_associations: one PR per repository" "$(api_get "/api/runs/$PH_RUN/prs" | jq '[.prs[]] | length')" "3"
  assert_eq "fake gh: 'pr create' calls for the run branch" "$(gh_calls "pr create .*--head $PH_BRANCH")" "3"
  for r in repo repo-b repo-c; do
    assert_eq "fake gh: the PR of $r was created from its own checkout" "$(gh_calls "${r}${TAB}pr create .*--head $PH_BRANCH")" "1"
  done

  # --- the agent really made the calls (its own transcript), not a harness shortcut
  calls=$(agent_calls "$PH_RUN" run_request_repo)
  out "   agent's foreman_run_request_repo calls: $(printf '%s' "$calls" | tr '\n' ' ' | cut -c1-400)"
  assert_eq "the agent called foreman_run_request_repo twice (its own transcript)" "$(printf '%s' "$calls" | grep -c .)" "2"
  assert_eq "every call named this run's id" "$(printf '%s' "$calls" | jq -r '.run_id' | sort -u | tr '\n' ' ')" "$PH_RUN "
}

# ---------------------------------------------------------------- stage: fanout

stage_fanout() {
  say "fanout: an agent calls foreman_task_fanout for every repository, twice"
  FAN_TASK="fanout-call-$SUFFIX"
  FANOUT_ID="fan$SUFFIX"
  FAN_TOKEN="FANOUT-$SUFFIX-$(date +%s)"
  expected=$(api_get "/api/projects/$PROJECT/repositories" | jq '[.repositories[]?] | length')
  repo_ids=$(api_get "/api/projects/$PROJECT/repositories" | jq -r '[.repositories[]?.id] | sort | join(",")')
  goal="Create a file named FANOUT in the repository root containing exactly $FAN_TOKEN followed by a newline."
  fan_prompt="Call the MCP tool foreman_task_fanout of the foreman MCP server with EXACTLY these arguments: project_id \"$PROJECT\", title \"E2E fan-out $SUFFIX\", prompt \"$goal\", workflow \"repo-one\", repo_ids \"all\" (the string all, not a list), fanout_id \"$FANOUT_ID\". When it has returned, call it a SECOND time with exactly the same arguments. Do not create any task any other way."
  t0=$(date +%s)
  api_post "$(task_json "$FAN_TASK" "E2E: agent-driven fan-out" "$fan_prompt" repo-fanout-call)"
  assert_eq "task.create for the agent that fans out" "$API_CODE" "201"
  await_run "$FAN_TASK"
  FAN_RUN=$RUN
  [ -n "$FAN_RUN" ] || { fail "fanout: no run was created for task $FAN_TASK"; return 0; }
  note "run id: $FAN_RUN (registered repositories: $repo_ids)"
  wait_run "$FAN_RUN"
  note "terminal status '$RUN_STATUS' after $(elapsed "$t0")s"
  if [ "$RUN_STATUS" != completed ]; then
    fail "fanout: run reached '$RUN_STATUS', expected 'completed'"
    diagnose_run "$FAN_RUN"
    return 0
  fi
  pass "fanout: the agent's run completed"

  calls=$(agent_calls "$FAN_RUN" task_fanout)
  out "   agent's foreman_task_fanout calls: $(printf '%s' "$calls" | tr '\n' ' ' | cut -c1-500)"
  assert_eq "the agent called foreman_task_fanout twice (its own transcript)" "$(printf '%s' "$calls" | grep -c .)" "2"
  assert_eq "both calls carried the same fanout_id" "$(printf '%s' "$calls" | jq -r '.fanout_id' | sort -u | tr '\n' ' ')" "$FANOUT_ID "
  results=$(agent_results "$FAN_RUN" task_fanout)
  first=$(printf '%s\n' "$results" | sed -n 1p)
  second=$(printf '%s\n' "$results" | sed -n 2p)
  assert_eq "first call: the tool created a task for every repository" "$(printf '%s' "$first" | jq -r '[.tasks[]?.status] | unique | join(",")')" "created"
  assert_eq "repeat call: the same task ids, nothing new (idempotent per fanout_id)" \
    "$(printf '%s' "$second" | jq -c '[.tasks[]?.task_id] | sort')" "$(printf '%s' "$first" | jq -c '[.tasks[]?.task_id] | sort')"
  assert_eq "repeat call: every task reported created (replayed command) or exists, never rejected" \
    "$(printf '%s' "$second" | jq -r '[.tasks[]?.status] | map(select(. != "created" and . != "exists")) | length')" "0"

  tasks=$(api_get "/api/tasks?project_id=$PROJECT" | jq -c --arg f "$FANOUT_ID" '[.tasks[]? | select(.task_id | startswith($f + "-"))]')
  out "   tasks: $(printf '%s' "$tasks" | jq -c '[.[] | {task_id, status, repo_id, workflow_type}]')"
  assert_eq "one task per registered repository, no duplicate from the second call" "$(printf '%s' "$tasks" | jq 'length')" "$expected"
  assert_eq "task ids are <fanout_id>-<repo_id>" \
    "$(printf '%s' "$tasks" | jq -r --arg f "$FANOUT_ID-" '[.[] | .task_id | ltrimstr($f)] | sort | join(",")')" "$repo_ids"
  assert_eq "every fanned-out task is open until the operator starts it" \
    "$(printf '%s' "$tasks" | jq -r '[.[] | .status] | unique | join(",")')" "open"
  # The task read model does not carry `source`; the TaskCreated events do.
  fan_events=$(rpc "E2EAgentRepoProbe.fanout_tasks(\"$FANOUT_ID\")" | grep '^\[' | tail -n 1)
  assert_eq "every fanned-out task carries the fan-out source (TaskCreated.source)" \
    "$(printf '%s' "$fan_events" | jq -r '[.[] | .source] | unique | join(",")')" "fanout:$FANOUT_ID"
  assert_eq "one TaskCreated event per repository (the repeat created nothing)" "$(printf '%s' "$fan_events" | jq 'length')" "$expected"

  # --- the operator starts them (fan-out only creates the tasks); each is its own single-repository run
  for tid in $(printf '%s' "$tasks" | jq -r '.[] | .task_id'); do
    api_post "$(jq -nc --arg t "$tid" '{type: "task.approve", payload: {task_id: $t, approved_by: "e2e-operator"}}')"
    case "$API_CODE" in 200|201|202) ;; *) fail "task.approve $tid: HTTP $API_CODE $API_BODY" ;; esac
  done
  note "approved $expected fanned-out tasks; waiting for their runs"
  for id in $(printf '%s' "$repo_ids" | tr ',' ' '); do
    await_run "$FANOUT_ID-$id"
    run=$RUN
    [ -n "$run" ] || { fail "fanout: no run for $FANOUT_ID-$id"; continue; }
    wait_run "$run"
    if [ "$RUN_STATUS" != completed ]; then fail "fanout: run $run of repository $id reached '$RUN_STATUS'"; diagnose_run "$run"; continue; fi
    branch="foreman/$FANOUT_ID-$id/$run"
    oid=$([ "$id" = main ] || [ "$id" = b ] && echo "$id" || echo c)
    assert_content_exactly "fan-out run in repository '$id': FANOUT committed on its own branch" "$(origin_file "$oid" "$branch" FANOUT)" "$FAN_TOKEN"
    assert_eq "fan-out run in repository '$id': exactly one PR, from that repository's checkout" \
      "$(api_get "/api/runs/$run/prs" | jq '[.prs[]] | length')" "1"
  done
}

# ---------------------------------------------------------------- stage: jobsite

# A multi-repository jobsite is out of v1 by design (docs/spikes/S3.md): the remote spec refuses a
# `repositories` key with a typed error, before anything is validated further or started.
stage_jobsite() {
  say "jobsite: a multi-repository jobsite is refused with its typed error, and nothing starts"
  js_code=$(curl -sS -o "$WORK/jobsite.body" -w '%{http_code}' --max-time 30 -X POST "$API/api/jobsites" \
    -H "authorization: Bearer $E2E_API_TOKEN" -H 'content-type: application/json' \
    -d "$(jq -nc --arg p "$PROJECT" '{project_id: $p, prompt: "never runs", repositories: [{id: "b"}]}')")
  assert_eq "POST /api/jobsites with \`repositories\`: HTTP status and typed error" "$js_code $(jq -r '.error // empty' "$WORK/jobsite.body")" "403 spec_forbidden_key"
  assert_has "the refusal names the reason" "$(jq -r '.message // empty' "$WORK/jobsite.body")" "multi-repo jobsites unsupported"
  assert_eq "no jobsite was started" "$(api_get /api/jobsites | jq '[.jobsites[]?] | length')" "0"
}

# ---------------------------------------------------------------- closing checks

stage_strays() {
  say "strays: nothing left behind by the runs"
  for r in "$REPO" "$REPO_B" "$REPO_C"; do
    assert_eq "$(basename "$r"): only its main checkout is a registered worktree" "$(git -C "$r" worktree list --porcelain | grep -c '^worktree ')" "1"
  done
  assert_eq "fake gh: unsupported invocations over the whole run" "$(cat "$GH_STATE/unsupported.log" 2>/dev/null | wc -l | tr -d ' ')" "0"
  say "evidence: fake gh calls"
  cut -f2- "$CALLS" 2>/dev/null | cut -c1-200 | while IFS= read -r l; do out "   gh@$l"; done
}

# ---------------------------------------------------------------- main

say "foreman multi-repo agent live e2e: provider=$E2E_PROVIDER model=$E2E_AGENT_MODEL stages=[$E2E_STAGES]"
setup_all
for stage in $E2E_STAGES; do
  s0=$(date +%s)
  "stage_$stage"
  note "stage $stage took $(elapsed "$s0")s"
done
stage_strays
summary
exit $?
