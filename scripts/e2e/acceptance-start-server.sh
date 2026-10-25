#!/bin/bash
export DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_accept
export FOREMAN_HTTP_PORT=47661
export FOREMAN_API_TOKEN=accept-token
export FOREMAN_START_BEADS_WATCHER=false
export FOREMAN_PR_FIX_SANDBOX=host FOREMAN_JOBSITES_ALLOW_HOST_SANDBOX=true
export FOREMAN_PR_MONITOR_ENABLED=true
export FOREMAN_NOTIFY_WEBHOOK_URL=http://127.0.0.1:47662/hook
export FOREMAN_NOTIFY_WEBHOOK_ALLOW_INSECURE_HTTP=true FOREMAN_NOTIFY_WEBHOOK_ALLOW_PRIVATE_HOSTS=true
export FOREMAN_REVIEW_PROVIDER=pi FOREMAN_REVIEW_MODEL=minimax/MiniMax-M2.7-highspeed
export MIX_HOME=/Users/ldangelo/.mix HEX_HOME=/Users/ldangelo/.hex
export HOME=/Users/ldangelo/Development/Fortium/foreman-wt/accept-scratch/home
export PATH=/Users/ldangelo/Development/Fortium/foreman-wt/accept-scratch/fakegh:$PATH
cd /Users/ldangelo/Development/Fortium/foreman-wt/e16acc/packages/foreman_server
if [ "$1" = setup ]; then mix ecto.create && mix ecto.migrate && mix event_store.create && mix event_store.init; exit; fi
exec mix phx.server
