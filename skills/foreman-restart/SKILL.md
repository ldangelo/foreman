---
name: foreman-restart
description: "Rebuild and restart the foreman Elixir server + Go cockpit for local development. Use when: (1) the user says 'restart foreman' / 'rebuild and restart' / 'foreman server is broken' / 'server is hung' / 'cockpit is empty', (2) after merging a PR that touches the Elixir server source (packages/foreman_server/), the Node CLI (src/), the Go cockpit (clients/cockpit/), or the bundled prompt/workflow files, (3) any time `foreman server status` shows the server as stopped, the rebuild times out, or the projection store reports zero tables. Make sure to use this skill whenever the user mentions the foreman server, the Elixir backend, the rebuild, or the local stack — even if they don't explicitly say 'restart'."
---

# foreman-restart

Rebuild and restart the foreman Elixir server + Go cockpit for local development. Captures the DB-alignment caveats and rebuild ordering learned the hard way.

## Variables used throughout

These placeholders keep the recipe portable. Set them once for the session.

```bash
# The foreman repo root. If you run foreman from a different checkout,
# update this. Examples:
#   export FOREMAN_ROOT="$HOME/projects/foreman"
#   export FOREMAN_ROOT="$(git -C . rev-parse --show-toplevel)"
export FOREMAN_ROOT="$HOME/Development/Fortium/foreman"

# The user home. Used for ~/.foreman/... and ~/.pi/agent/skills/... paths.
export HOME_DIR="$HOME"

# Load the checkout's .env before choosing defaults. For Foreman restarts,
# DATABASE_URL from .env or the process environment is the source of truth.
# Only fall back to the compose default when DATABASE_URL is unset.
if [[ -f "$FOREMAN_ROOT/.env" ]]; then
  set -a
  source "$FOREMAN_ROOT/.env"
  set +a
fi
export FOREMAN_PG_HOST="${FOREMAN_PG_HOST:-127.0.0.1}"
export FOREMAN_PG_PORT="${FOREMAN_PG_PORT:-55432}"
export DATABASE_URL="${DATABASE_URL:-postgresql://postgres:postgres@${FOREMAN_PG_HOST}:${FOREMAN_PG_PORT}/foreman}"

# The active foreman project ID is resolved later, in step 9c, after the
# CLI is built (step 3) and the server is up (step 8). Resolving it here
# would fail on a fresh checkout with no `dist/cli/index.js` and would
# silently skip the board check in 9c when the lookup returns empty.
```

If the operator prefers a different layout, the rest of the recipe reads the values from these variables.

## When to Use

- User says "restart foreman", "rebuild and restart", "foreman server is broken", "cockpit is empty", "the rebuild is stuck", or "the server is hung".
- After merging a PR that touches any of:
  - `packages/foreman_server/` (Elixir server: events, projections, HTTP)
  - `src/` (Node CLI)
  - `clients/cockpit/` (Go TUI)
  - Bundled prompt/workflow files (reinstall via `foreman init --force`)
- `foreman server status` shows the server as stopped, or the rebuild times out.
- Projection store reports zero tables on a fresh DB (migrations missing).

## DB alignment caveat (read this before starting)

- The checkout's `.env` is the source of truth for Foreman's `DATABASE_URL`; do not hardcode the compose default when restarting. The compose-managed Foreman database is exposed on `127.0.0.1:55432` only when local env does not intentionally point elsewhere.
- **Always verify which DB the running server is on** with `curl -sS http://127.0.0.1:4766/api/v1/health` and `pg_stat_activity`, before declaring the restart done. Confirm both:
  - `lsof -nP -iTCP:4766 -sTCP:LISTEN` shows the active beam PID
  - `ps eww -p $PID | tr ' ' '\n' | grep '^DATABASE_URL='` shows the actual env
  - `psql "$DATABASE_URL" -c "SELECT ... FROM pg_stat_activity"` shows the beam's idle connections on the same database
- Different Postgres instances (for example, ports 55432 and 5432) do not share task data.
- **Don't switch DBs without migrating data.** If the populated task history is on a different database than the one you intend to start, do NOT truncate or restore first. Ask the user before any destructive migration.
  1. **Confirm the target is disposable.** If the target already has task data, do not migrate. Ask the user.
  2. **Back up the target** even if it looks empty:
     ```bash
     pg_dump "$TARGET_DATABASE_URL" -F c -f "${FOREMAN_ROOT}/foreman-target-backup.dump"
     ```
  3. **Back up the source** (the data you want to keep):
     ```bash
     pg_dump "$SOURCE_DATABASE_URL" -F c -f "${FOREMAN_ROOT}/foreman-source-backup.dump"
     ```
  4. **Truncate the target** projection tables + `foreman_events` (the destructive step):
     ```bash
     psql "$TARGET_DATABASE_URL" -c "TRUNCATE foreman_projection_checkpoints, foreman_task_projections, foreman_run_projections, foreman_project_projections, foreman_inbox_message_projections, foreman_events;"
     ```
  5. **Restore the source dump** into the target:
     ```bash
     pg_restore --dbname="$TARGET_DATABASE_URL" --clean --if-exists --no-owner --no-acl "${FOREMAN_ROOT}/foreman-source-backup.dump"
     ```
  6. **Verify** with `SELECT count(*) FROM foreman_task_projections;` on both sides — the counts should match the source.
  7. If anything looks wrong, restore the target from the backup dump:
     ```bash
     pg_restore --dbname="$TARGET_DATABASE_URL" --clean --if-exists --no-owner --no-acl "${FOREMAN_ROOT}/foreman-target-backup.dump"
     ```

## Recipe

1. **Check for uncommitted work** in the controller worktree (the `foreman-restart` skill lives under `skills/`, but staged/unstaged changes anywhere in the project risk getting clobbered by a `git checkout`). Run `git status --short` from the foreman repo root.
2. **Fetch + pull main** (force-push, rebase, or other history-changing ops should be coordinated with the user first).
3. **Build the Node CLI** (atomic dist swap):
   ```bash
   cd "$FOREMAN_ROOT"
   npm run build
   ```
4. **Build the Go cockpit** (binary used by `foreman watch` and `go run .`):
   ```bash
   bash -lc "set -o pipefail; cd '${FOREMAN_ROOT}/clients/cockpit' && go build -o foreman-cockpit ."
   go_exit=$?
   echo "go build exit=$go_exit"
   if [[ "$go_exit" -ne 0 ]]; then
     echo "go build failed with exit $go_exit; aborting"
     exit "$go_exit"
   fi
   ```
   The exit status of the `bash -lc` invocation is captured into
   `go_exit` and propagated, so a failed `go build` aborts the recipe
   before the restart proceeds. Avoid `if ! cmd; then go_exit=$?`
   because `$?` after `!` is the status of `!` (0), not of `cmd`.


5. **Stop the current foreman server** (idempotent if already stopped):
   ```bash
   cd "$FOREMAN_ROOT"
   foreman server stop
   ```
6. **Clean up orphaned beam processes** (only target Foreman PIDs whose cwd contains `foreman_server`; wait for each to exit; escalate if necessary):
   ```bash
   kill_foreman_beams() {
     local pids=()
     for pid in $(ps -eo pid,command | awk '/[b]eam.smp/ {print $1}'); do
       cwd=$(lsof -a -p "$pid" -d cwd 2>/dev/null | tail -1 | awk '{print $NF}')
       if [[ "$cwd" == *foreman_server* ]]; then
         echo "  targeting foreman beam pid=$pid cwd=$cwd"
         pids+=("$pid")
         kill -TERM "$pid" 2>/dev/null
       fi
     done
     # Wait for each targeted PID to actually exit (not just sleep).
     for pid in "${pids[@]}"; do
       for i in 1 2 3 4 5 6 7 8 9 10; do
         if ! kill -0 "$pid" 2>/dev/null; then
           echo "  pid=$pid exited"
           break
         fi
         sleep 1
       done
       # Escalate if still alive.
       if kill -0 "$pid" 2>/dev/null; then
         echo "  pid=$pid still alive after 10s; sending SIGKILL"
         kill -KILL "$pid" 2>/dev/null
         sleep 1
       fi
     done
   }
   kill_foreman_beams
   # Verify the exact PIDs we targeted are gone (not a broad count, which
   # could include unrelated beam.smp from other applications).
   echo "  remaining foreman_server beams:"
   ps -eo pid,cwd | awk '/[f]oreman_server/ {print "    pid=" $1 " cwd=" $2}'
   ```
7. **Remove stale PID file** (the wrapper doesn't always overwrite it on start; remove only after the targeted beams have exited — see step 6):
   ```bash
   rm -f "$HOME_DIR/.foreman/elixir-server.pid"
   ```
8. **Start the server** (use `DATABASE_URL` loaded from `.env`/env; prefix it explicitly so unrelated shell state cannot override the selected database):
   ```bash
   cd "$FOREMAN_ROOT"
   DATABASE_URL="$DATABASE_URL" nohup foreman server start > /tmp/srv.log 2>&1 &
   echo "wrapper pid=$!"
   # Readiness polling (moved to step 9b) replaces the old fixed 20s sleep.
   cat /tmp/srv.log
   ```
   Override `DATABASE_URL` in `.env` or the shell when intentionally changing databases. The DB-alignment check in step 9a uses the same `DATABASE_URL`, so the verify step stays consistent with the start step. Don't guess.
9. **Verify** (DB alignment FIRST, then port, then board API, then doctor — with readiness polling, not a fixed sleep):
   ```bash
   readiness_budget_ms="${FOREMAN_STARTUP_TIMEOUT_MS:-600000}"

   # 9a. Wait for the listener to appear before capturing the PID. The beam
   # can take a few seconds to bind :4766 after `nohup foreman server start &`,
   # and the listener doesn't exist until the supervisor finishes its init.
   deadline_listener=$(( $(date +%s) + readiness_budget_ms / 1000 ))
   pid=""
   while [[ $(date +%s) -lt $deadline_listener ]]; do
     pid=$(lsof -nP -iTCP:4766 -sTCP:LISTEN 2>/dev/null | awk '/beam.smp/ {print $2}' | head -1)
     [[ -n "$pid" ]] && break
     sleep 1
   done
   if [[ -z "$pid" ]]; then
     echo "  ERROR: no beam on :4766 after ${readiness_budget_ms}ms; cannot run DB-alignment or health checks"
     foreman server doctor 2>&1 | head -20
     exit 1
   fi
   echo "  beam pid=$pid"
   ps eww -p "$pid" 2>/dev/null | tr ' ' '
' | grep '^DATABASE_URL=' | head -1
   PGPASSWORD="${POSTGRES_PASSWORD:-postgres}" psql "$DATABASE_URL" -tA -c "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND application_name = '' AND state='idle';" 2>/dev/null | xargs -I{} echo "  DATABASE_URL idle connections: {}"
   # If the beam is on a different DB than DATABASE_URL, do not declare success — fix the DB first.

   # 9b. Wait for the server to report ready. Default readiness budget is
   # 600_000 ms (the documented projection-rebuild timeout). Override with
   # FOREMAN_STARTUP_TIMEOUT_MS if your environment is faster/slower.
   echo "  waiting for /api/v1/health (budget=${readiness_budget_ms}ms)"
   deadline_ms=$(python3 -c "import time; print(int(time.monotonic_ns() // 1_000_000) + int('${readiness_budget_ms}'))")
   ready=0
   while :; do
     if curl -sS -m 5 "http://127.0.0.1:4766/api/v1/health" 2>/dev/null | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("ok") else 1)' 2>/dev/null; then
       echo "  ready"
       ready=1
       break
     fi
     if [[ $(python3 -c "import time; print(int(time.monotonic_ns() // 1_000_000))") -gt $deadline_ms ]]; then
       echo "  timeout waiting for readiness; aborting verify"
       break
     fi
     sleep 2
   done

   # 9c. Only run the other checks if readiness was achieved. If the deadline
   # expired, fail clearly and skip the dependent checks.
   if [[ "$ready" -ne 1 ]]; then
     echo "  restart did not become ready within ${readiness_budget_ms}ms; running doctor for diagnosis, but skipping port/board checks"
     foreman server doctor 2>&1 | head -20
     exit 1
   fi
   lsof -nP -iTCP:4766 -sTCP:LISTEN | head -3
   curl -sS -m 5 "http://127.0.0.1:4766/api/v1/health" | python3 -m json.tool

   # Resolve the active project ID now (after the CLI is built and the
   # server is up). Uses the same DATABASE_URL override the start step used.
   # If the CLI is missing or the project isn't registered, fail clearly.
   pyresolver=$(cat <<'PY'
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    sys.exit(0)
parsed = json.loads(raw)
items = parsed if isinstance(parsed, list) else parsed.get("projects", [])
match = next((p for p in items if p.get("name") == "foreman"), {})
sys.stdout.write(match.get("project_id", match.get("id", "")))
PY
   )
   FOREMAN_PROJECT_ID="$(DATABASE_URL="$DATABASE_URL" "$FOREMAN_ROOT/bin/foreman" project list --json 2>/dev/null | python3 -c "$pyresolver" 2>/dev/null)"
   if [[ -z "$FOREMAN_PROJECT_ID" ]]; then
     echo "  ERROR: FOREMAN_PROJECT_ID not resolved (CLI built? project registered? foreman init?); aborting"
     foreman server doctor 2>&1 | head -20
     exit 1
   fi
   curl -sS -m 5 "http://127.0.0.1:4766/api/v1/board?project_id=${FOREMAN_PROJECT_ID}" | python3 -m json.tool

   # Doctor: capture exit status before truncating output, then exit
   # non-zero so the recipe's own status reflects the doctor result.
   set +e
   foreman server doctor 2>&1 | tee /tmp/foreman-doctor.out | head -20
   doctor_exit=${PIPESTATUS[0]}
   set -e
   echo "  doctor exit=$doctor_exit"
   if [[ "$doctor_exit" -ne 0 ]]; then
     echo "  foreman server doctor reported errors; aborting"
     exit "$doctor_exit"
   fi
   ```


10. **Tell the user to relaunch the Go cockpit** if they had it running (a previous `pkill -f foreman-cockpit` may have killed it):
    ```bash
    cd "${FOREMAN_ROOT}/clients/cockpit"
    go run .
    ```

## When bundled prompts / workflows / skills also change

If the merged PR touched any of these bundled-source paths, the installed runtime copies at `~/.foreman/prompts/`, `~/.foreman/workflows/`, or `~/.pi/agent/skills/` are now stale. `foreman run` / `foreman run --watch` / direct worker startup fail fast on stale installed runtime assets, so the rebuild alone is not enough.

Triggers for `foreman init --force`:
- `src/defaults/prompts/**/*.md` (bundled prompt templates)
- `src/defaults/workflows/**/*.yaml` (bundled workflow definitions)
- `src/defaults/skills/<name>/SKILL.md` (bundled required skills)
- `src/lib/prompt-loader.ts` (the `REQUIRED_SKILLS` and `REQUIRED_PHASES` lists)

Reinstall after merge:

```bash
cd "$FOREMAN_ROOT"
foreman init --force
```

This re-copies bundled prompts/workflows/skills to the installed runtime paths and re-validates the required-skills list. Without it, the next dispatch may fail with "stale installed runtime asset" errors that look unrelated to the merged change.

Do NOT add the .agents/, .pi/skills/, or skills-lock.json byproducts to git. They are runtime outputs of `foreman init --force` and will be regenerated.

## Pitfalls

- **Don't pipe builds through `tail`/`head` without `set -o pipefail`.** The pipe consumer can succeed even when the producer failed.
- **Don't blanket-pkill `foreman-cockpit`.** The Go cockpit is a SEPARATE process from the Elixir server; the user may be running it interactively. Target exact PIDs.
- **Don't write the restart recipe into `.agents/` or `.pi/skills/`.** Those are untracked install outputs from `foreman init --force` and would be lost on the next `foreman init`. Put it in `skills/<name>/SKILL.md` (this file).
- **Don't add the `.agents/`, `.pi/skills/`, or `skills-lock.json` byproducts to git.** They are runtime artifacts.
- **Don't add to-do lists that need re-running.** If something seems off (orphan beams, stale PID, port still bound), fix it in this skill's recipe so the next restart is clean.
- **Don't rely on the wrapper's stdout for errors.** The `foreman server start` Node wrapper often produces empty stdout and exits with no error while the underlying Elixir server is hung in init (typically GenServer init timeout vs a large event log). Foreground `bash -lc "cd packages/foreman_server && DATABASE_URL=... mix run --no-halt"` to surface real errors.

## Common issues and fixes

- **`projection_store.ex:57 connection is closed because of an error`** on a server with a large event log: the GenServer init (5s default) and the `Repo.transaction` (15s default) both timeout. Fixed by `packages/foreman_server/lib/foreman_server/runtime_info.ex:projection_rebuild_timeout_ms/0` (default 600_000 ms, env override `FOREMAN_SERVER_PROJECTION_REBUILD_TIMEOUT_MS`).
- **`shutdown: failed to start child: ForemanServer.EventStore`** with `table is missing`: run `cd packages/foreman_server && DATABASE_URL=... mix ecto.migrate` first.
- **Cockpit is empty after a restart** (no tasks in board columns): the user's data is in a different DB than the server. Use the DB-alignment caveat section above to verify.
