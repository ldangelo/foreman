#!/usr/bin/env bash
# Regenerates packages/foreman_server/test/fixtures/br/* from a REAL `br`.
# Usage: scripts/refresh_br_fixtures.sh [scratch_dir]
# Scratch dir must live outside /tmp; default: <repo>/../brfix-scratch/fixtures-run.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/packages/foreman_server/test/fixtures/br"
SCRATCH="${1:-$ROOT/../brfix-scratch/fixtures-run}"
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH" "$OUT"
cd "$SCRATCH"
git init -q . && br init >/dev/null 2>&1
DB="$SCRATCH/.beads/beads.db"
b() { br "$@" --db "$DB"; }
id_of() { jq -r 'if type=="array" then .[0].id else .id end'; }

# create --json (plain, labelled): argv mirrors SystemBrRunner.build_action_argv(:create)
b create --title "Plain fixture issue" --type task --priority 2 --description "plain body" --agent-context '{"foreman":{"task_id":"t1"}}' --json > "$OUT/create_plain.json"
b create --title "Labelled fixture issue" --type bug --priority 1 --description "labelled body" --agent-context '{"foreman":{"task_id":"t2"}}' --labels foreman-exec,foreman-gap --json > "$OUT/create_labels.json"
PLAIN=$(id_of < "$OUT/create_plain.json"); LAB=$(id_of < "$OUT/create_labels.json")
b create --title "Dependency target" --type task --priority 2 --description "dep" --json > "$SCRATCH/dep.json"
DEP=$(id_of < "$SCRATCH/dep.json")
b create --title "Commented issue" --type task --priority 3 --description "c" --json > "$SCRATCH/com.json"
COM=$(id_of < "$SCRATCH/com.json")
b create --title "Lifecycle issue" --type task --priority 2 --description "l" --json > "$SCRATCH/life.json"
LIFE=$(id_of < "$SCRATCH/life.json")

# dep add: PLAIN depends on DEP  => show PLAIN has a dependency, show DEP has a dependent.
b dep add "$LAB" "$DEP" --json > "$OUT/dep_add.json"
# comments add --json (SystemBrRunner :comments_add)
b comments add "$COM" --message "first comment" --json > "$OUT/comments_add.json"
b comments add "$COM" --message "second comment" --json > /dev/null

b show "$PLAIN" --json > "$OUT/show_plain.json"
b show "$LAB" --json > "$OUT/show_labels_with_dependency.json"
b show "$DEP" --json > "$OUT/show_with_dependent.json"
b show "$COM" --json > "$OUT/show_with_comments.json"

b list --label foreman-exec --json > "$OUT/list_labels.json"
b ready --json > "$OUT/ready.json"

b update "$LIFE" --claim --json > "$OUT/update_claim.json"
b update "$LIFE" --status blocked --transition-comment "blocked for fixture" --json > "$OUT/update_blocked.json"
b update "$LIFE" --status open --transition-comment "reopened for fixture" --json > "$OUT/update_reopen.json"
b close "$LIFE" --reason "done for fixture" --json > "$OUT/close.json" || true
for s in ready-issue issue-details error commands; do b schema "$s" --json > "$OUT/schema_${s//-/_}.json" || true; done
# `br schema` embeds a timestamp and a version; they are kept verbatim.
echo "fixtures written to $OUT (br $(br --version))"
