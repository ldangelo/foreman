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
b dep add "$LAB" "$DEP" --json > "$OUT/dep_add_exists.json"   # repeat: exit 0, status "exists"
b dep add "$DEP" "$LAB" --json > "$OUT/dep_add_cycle_error.json" || true   # exit 5, error envelope on STDOUT
b comments add "$COM" --message "first comment" --json > "$OUT/comments_add.json"
b comments add "$COM" --message "second comment" --json > /dev/null

b show "$PLAIN" --json > "$OUT/show_plain.json"
b show "$LAB" --json > "$OUT/show_labels_with_dependency.json"
b show "$DEP" --json > "$OUT/show_with_dependent.json"
b show "$COM" --json > "$OUT/show_with_comments.json"

b list --label foreman-exec --json > "$OUT/list_labels.json"
b ready --json > "$OUT/ready.json"

b coordination status --json > "$OUT/coordination_status_empty.json"
b update "$LIFE" --claim --json > "$OUT/update_claim.json"
b coordination status --json > "$OUT/coordination_status_claimed.json"
b update "$LIFE" --priority 1 --json > "$OUT/update_priority.json"
b update "$LIFE" --status blocked --transition-comment "blocked for fixture" --json > "$OUT/update_blocked.json"
b update "$LIFE" --status open --transition-comment "reopened for fixture" --json > "$OUT/update_reopen.json"
b close "$LIFE" --reason "done for fixture" --json > "$OUT/close.json" || true
b sync --status --json > "$OUT/sync_status.json"
b where --json > "$OUT/where.json"
for s in ready-issue issue-details error commands; do b schema "$s" --json > "$OUT/schema_${s//-/_}.json" || true; done
# `br schema` embeds a timestamp and a version; they are kept verbatim.

# A parent-child tree for Workflow.BeadsTreeCompletion (TRD-2026-72f477ca TRD-004):
# epic -> 2 stories -> 3 tasks. T3 (under S2) is also blocked by T1 (under S1): a `blocks`
# edge BETWEEN tree members. OUTSIDE is not in the tree and is blocked by T2: a `blocks`
# edge OUT of it. The completion check issues one `br show <ids...>` per tree level.
# Created last so the captures above never see these issues.
mk() { b create --title "$1" --type "$2" --priority 2 --json | id_of; }
EPIC=$(mk "Tree epic" epic); S1=$(mk "Tree story one" feature); S2=$(mk "Tree story two" feature)
T1=$(mk "Tree task one" task); T2=$(mk "Tree task two" task); T3=$(mk "Tree task three" task)
OUTSIDE=$(mk "Outside the tree" task)
for pair in "$S1 $EPIC" "$S2 $EPIC" "$T1 $S1" "$T2 $S1" "$T3 $S2"; do
  b dep add $pair --type parent-child --json > /dev/null
done
b dep add "$T3" "$T1" --json > /dev/null
b dep add "$OUTSIDE" "$T2" --json > /dev/null
# incomplete: T1 closed, T2 in_progress, T3 open, both stories open
b close "$T1" --reason "fixture" --json > /dev/null
b update "$T2" --status in_progress --json > /dev/null
b show "$EPIC" --json > "$OUT/show_tree_incomplete_epic.json"
b show "$S1" "$S2" --json > "$OUT/show_tree_incomplete_stories.json"
b show "$T1" "$T2" "$T3" --json > "$OUT/show_tree_incomplete_tasks.json"
b show "$EPIC" nope-0 --json > "$OUT/show_tree_missing_id.json" || true   # exit 3, error envelope on STDOUT
# complete: every descendant closed, the root epic itself still open
b close "$T2" "$T3" --reason "fixture" --json > /dev/null
b close "$S1" "$S2" --reason "fixture" --json > /dev/null
b show "$EPIC" --json > "$OUT/show_tree_complete_epic.json"
b show "$S1" "$S2" --json > "$OUT/show_tree_complete_stories.json"
b show "$T1" "$T2" "$T3" --json > "$OUT/show_tree_complete_tasks.json"
echo "fixtures written to $OUT (br $(br --version))"
