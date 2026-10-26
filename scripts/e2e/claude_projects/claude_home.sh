#!/usr/bin/env bash
# Helpers for the live scripts that run a REAL claude through the redirected HOME of
# scripts/e2e/claude_projects/lib.sh ($WORK/home is the server's HOME, so it is the HOME of every claude
# the server spawns). Sourced after lib.sh, never executed. Needs lib.sh's WORK, REAL_HOME, pass/fail/note.
#
# lib.sh's link_claude_auth LINKS the operator's ~/.claude and ~/.claude.json into that HOME: the agents then
# run with the operator's own hooks, plugins, skills, permission default and session history, and write their
# sessions into the operator's ~/.claude/projects. The scripts that use these helpers want neither, and the
# second one needs a user-scope MCP server (Foreman's own /mcp endpoint) that the operator's config does not
# have and that nothing may add to it. So here the HOME gets:
#
#   .claude            a private EMPTY directory: stock settings (the default permission mode, no hooks,
#                      plugins or skills), sessions land under $WORK/home/.claude/projects and vanish with
#                      the work dir
#   .claude.json       a COPY of the operator's (login metadata; the OAuth token itself is in the macOS
#                      keychain), plus one HTTP MCP server entry when asked for
#   Library/Keychains  lib.sh's link_claude_auth adds this symlink (the OAuth token); nothing else is linked
#
# Call claude_private_home BEFORE claude_ready (which calls link_claude_auth: it only links what is absent).

# claude_private_home [<mcp server name> <mcp url> [<bearer token>]]: builds the HOME described above.
# Returns 1 (and sets CLAUDE_UNAVAILABLE) when the operator has no ~/.claude.json to copy.
claude_private_home() {
  CLAUDE_UNAVAILABLE=""
  mkdir -p "$WORK/home/.claude" "$WORK/home/Library"
  if [ ! -f "$REAL_HOME/.claude.json" ]; then
    CLAUDE_UNAVAILABLE="no $REAL_HOME/.claude.json to copy: claude is not logged in on this host"
    return 1
  fi
  if [ $# -ge 2 ]; then
    jq --arg name "$1" --arg url "$2" --arg token "${3:-}" '
      . + {mcpServers: {($name): ({type: "http", url: $url}
            + (if $token == "" then {} else {headers: {Authorization: ("Bearer " + $token)}} end))}}
    ' "$REAL_HOME/.claude.json" > "$WORK/home/.claude.json" || { CLAUDE_UNAVAILABLE="cannot write $WORK/home/.claude.json"; return 1; }
  else
    cp "$REAL_HOME/.claude.json" "$WORK/home/.claude.json" || { CLAUDE_UNAVAILABLE="cannot copy ~/.claude.json"; return 1; }
  fi
  chmod 600 "$WORK/home/.claude.json"
}

# claude_session_files [<substring of the project directory name>]: the session transcripts claude wrote
# under the private HOME (one JSON object per line), oldest first.
claude_session_files() {
  find "$WORK/home/.claude/projects" -name '*.jsonl' -path "*${1:-}*" 2>/dev/null | while read -r csf; do
    printf '%s %s\n' "$(stat -f %m "$csf" 2>/dev/null || stat -c %Y "$csf")" "$csf"
  done | sort -n | cut -d' ' -f2-
}

# claude_tool_calls <session file>: every tool call of the agent, one compact JSON object per line
# ({name, input}); MCP tools are named mcp__<server>__<tool>.
claude_tool_calls() {
  jq -c 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | {name, input}' "$1" 2>/dev/null
}
