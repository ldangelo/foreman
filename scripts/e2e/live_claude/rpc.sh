#!/usr/bin/env bash
# rpc.sh '<elixir expression>': evaluate on the private server node of stack.sh (needs devbox: elixir).
#   devbox run -- bash scripts/e2e/live_claude/rpc.sh 'IO.inspect(Application.get_env(:foreman_server, :approvals))'
# Output of IO.* calls in the expression is printed locally.
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
WORK=${E2E_WORK_DIR:-$(dirname "$ROOT")/$(basename "$ROOT")-scratch/work}
. "$WORK/stack.env"
exec elixir --name "lcctl$$@127.0.0.1" --cookie "$COOKIE" --hidden --rpc-eval "$NODE" "$1"
