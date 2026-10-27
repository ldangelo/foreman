#!/usr/bin/env bash
# Guard for @ever_shipped_workflow_names / @ever_shipped_prompt_names in
# packages/foreman_server/lib/foreman_server/workflow/install.ex.
#
#   ever-shipped-names.sh              compare git history with the lists in install.ex
#   ever-shipped-names.sh --self-test  check the comparison logic on fixtures (no history needed)
#
# Every `*.yaml` ever added under packages/foreman_server/priv/defaults/workflows or the TS-era
# src/defaults/workflows, and every `prompts/*.md` ever added under the former, that is no longer
# bundled MUST be in its list; otherwise `workflow remove --all` keeps leaving that manifest or
# prompt behind. Fails (exit 1) listing the missing names. A shallow clone cannot answer, so it
# SKIPS (exit 0, says so): CI runs it in a job with fetch-depth: 0.
set -euo pipefail

INSTALL_EX="packages/foreman_server/lib/foreman_server/workflow/install.ex"
PRIV="packages/foreman_server/priv/defaults/workflows"
SRC="src/defaults/workflows"

# stdin: repo paths. stdout: `workflow <name>` / `prompt <name>` lines, sorted unique.
classify_paths() {
  sed -E -n \
    -e "s#^${PRIV}/prompts/([^/]+)\\.md\$#prompt \\1#p" \
    -e "s#^${PRIV}/([^/]+)\\.yaml\$#workflow \\1#p" \
    -e "s#^${SRC}/([^/]+)\\.yaml\$#workflow \\1#p" | sort -u
}

# stdin: install.ex. arg: attribute name. stdout: `<kind> <name>` lines for its ~w(...) list.
list_names() {
  local attr=$1 kind=$2
  tr '\n' ' ' | grep -o "@${attr} ~w([^)]*)" | sed -e 's/.*~w(//' -e 's/)$//' |
    tr -s ' ' '\n' | grep . | sed "s/^/${kind} /" | sort -u || true
}

# args: historical-file bundled-file listed-file (each `<kind> <name>` lines). Prints the
# historical names that are neither still bundled nor listed.
missing_names() {
  comm -23 <(sort -u "$1") <(sort -u "$2" "$3")
}

self_test() {
  local d; d=$(mktemp -d); trap 'rm -rf "$d"' RETURN
  printf '%s\n' "workflow a" "workflow b" "workflow c" "prompt p" "prompt q" >"$d/hist"
  printf '%s\n' "workflow a" "prompt p" >"$d/bundled"
  printf '%s\n' "workflow b" "workflow c" "prompt q" "workflow zzz" >"$d/listed"
  [ -z "$(missing_names "$d/hist" "$d/bundled" "$d/listed")" ] || { echo "self-test: false positive"; exit 1; }
  printf '%s\n' "workflow b" "prompt q" >"$d/listed" # `workflow c` dropped
  [ "$(missing_names "$d/hist" "$d/bundled" "$d/listed")" = "workflow c" ] || { echo "self-test: missed removal"; exit 1; }
  printf '%s\n' "workflow b" "workflow c" >"$d/listed" # `prompt q` dropped: kinds are separate
  [ "$(missing_names "$d/hist" "$d/bundled" "$d/listed")" = "prompt q" ] || { echo "self-test: missed prompt"; exit 1; }
  [ "$(printf '%s\n' "$PRIV/x.yaml" "$PRIV/prompts/y.md" "$SRC/z.yaml" "$PRIV/prompts/n.yaml" "$SRC/sub/w.yaml" |
    classify_paths | tr '\n' ,)" = "prompt y,workflow x,workflow z," ] || { echo "self-test: classify"; exit 1; }
  [ "$(printf '@ever_shipped_workflow_names ~w(a b\n    c)\n@ever_shipped_prompt_names ~w(p)\n' |
    list_names ever_shipped_workflow_names workflow | tr '\n' ,)" = "workflow a,workflow b,workflow c," ] || { echo "self-test: list parse"; exit 1; }
  echo "ever-shipped-names self-test: ok"
}

if [ "${1:-}" = "--self-test" ]; then self_test; exit 0; fi

cd "$(git rev-parse --show-toplevel)"
if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
  echo "SKIP: shallow clone, git history is incomplete (CI runs this with fetch-depth: 0)"
  exit 0
fi

d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
git log --all --diff-filter=A --no-renames --name-only --pretty=format: -- "$PRIV" "$SRC" | classify_paths >"$d/hist"
git ls-tree -r --name-only HEAD -- "$PRIV" "$SRC" | classify_paths >"$d/bundled"
{ list_names ever_shipped_workflow_names workflow <"$INSTALL_EX"
  list_names ever_shipped_prompt_names prompt <"$INSTALL_EX"; } >"$d/listed"

[ -s "$d/hist" ] || { echo "::error::no workflow history found: the guard cannot see what it guards"; exit 1; }
[ -s "$d/listed" ] || { echo "::error::could not parse the ever-shipped lists in $INSTALL_EX"; exit 1; }

missing=$(missing_names "$d/hist" "$d/bundled" "$d/listed")
if [ -n "$missing" ]; then
  echo "::error::shipped once, no longer bundled, missing from $INSTALL_EX:"
  echo "$missing" | sed 's/^/  /'
  echo "Add each name to @ever_shipped_workflow_names (workflow) or @ever_shipped_prompt_names (prompt)."
  exit 1
fi
echo "ever-shipped lists cover all $(wc -l <"$d/hist" | tr -d ' ') historical names"
