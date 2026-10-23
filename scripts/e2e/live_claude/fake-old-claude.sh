#!/bin/sh
# SIMULATED older claude CLI: one that does not know --permission-prompt-tool. It rejects that
# flag exactly like commander.js rejects any unknown option (message on stderr, exit 1) and
# otherwise runs the real claude. Used through FOREMAN_CLAUDE_CLI (priv/bin/foreman-claude-permission
# execs it): E2E_EXTRA_ENV=FOREMAN_CLAUDE_CLI=$PWD/scripts/e2e/live_claude/fake-old-claude.sh stack.sh restart
for a in "$@"; do
  if [ "$a" = "--permission-prompt-tool" ]; then
    echo "error: unknown option '--permission-prompt-tool'" >&2
    echo "(Did you mean --permission-mode?)" >&2
    exit 1
  fi
done
exec claude "$@"
