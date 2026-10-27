#!/usr/bin/env bash
# Decide whether a change set needs the heavy CI jobs (foreman_server, jido_harness, foreman_cli).
#
#   changed-code.sh <base> <head>   diff two commits; print and export `code=true|false`
#   changed-code.sh --self-test     check the classification table below (no git needed)
#
# FAIL SAFE: only the paths on the allowlist in `is_non_code` are "not code". Any other path,
# an empty change set, or a diff that cannot be computed all answer `code=true`, so the worst
# a mistake in this file can do is run the full suite for a change that did not need it.
#
# The allowlist is explicit on purpose. A tree belongs on it only if nothing under it is read
# by a test or a build step. Checked 2026-10-27 by grepping packages/*/{test,lib,config,mix.exs}
# for each path: the suites read README.md, CLAUDE.md, docs/user-guide.md,
# docs/cli-reference.md, docs/ADT/, docs/spikes/ and ops/otel-collector/, so those are code.
# Everything else mentioned in the suites is a string inside a fixture or a comment. Adding a
# test that reads a file under an allowlisted tree means removing that tree from the list.
set -euo pipefail

is_non_code() {
  case "$1" in
    .beads/* | .coderabbit.yaml) return 0 ;;
    docs/acceptance/* | docs/plans/* | docs/lessons/* | docs/PRD/* | docs/TRD/*) return 0 ;;
    docs/reports/* | docs/decisions/* | docs/audit/* | docs/verification/*) return 0 ;;
    docs/architecture/* | docs/guides/* | docs/standards/* | docs/prompts/*) return 0 ;;
    docs/HLW/* | docs/JSH/* | docs/LGC/*) return 0 ;;
    scripts/e2e/*) return 0 ;;
    *) return 1 ;;
  esac
}

# NUL-separated paths on stdin -> `true` if any is code, `false` if all are not. Reads all of
# stdin so the `git diff` feeding it is never killed by SIGPIPE.
classify() {
  local path first_code="" total=0
  while IFS= read -r -d '' path; do
    total=$((total + 1))
    if [ -z "$first_code" ] && ! is_non_code "$path"; then
      first_code=$path
    fi
  done
  if [ -n "$first_code" ]; then
    echo "code: $first_code is not on the non-code allowlist" >&2
    echo true
  elif [ "$total" -eq 0 ]; then
    echo "code: empty change set, running everything" >&2
    echo true
  else
    echo "docs-only: all $total changed paths are on the non-code allowlist" >&2
    echo false
  fi
}

emit() {
  echo "code=$1"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "code=$1" >>"$GITHUB_OUTPUT"
  fi
}

self_test() {
  local failed=0 expected path got
  while IFS='|' read -r expected path; do
    [ -n "$expected" ] || continue
    got=$(printf '%s\0' "$path" | classify 2>/dev/null)
    if [ "$got" != "$expected" ]; then
      echo "FAIL: $path -> $got, expected $expected" >&2
      failed=1
    fi
  done <<'TABLE'
false|.beads/issues.jsonl
false|.coderabbit.yaml
false|docs/acceptance/README.md
false|docs/plans/live-steering.md
false|docs/lessons/devbox-and-toolchain.md
false|docs/PRD/PRD-2026-x.md
false|docs/TRD/TRD-2026-x.md
false|scripts/e2e/claude_projects/lib.sh
true|README.md
true|CLAUDE.md
true|AGENTS.md
true|docs/user-guide.md
true|docs/cli-reference.md
true|docs/ADT/representative-action-run.md
true|docs/spikes/S4/pr_status_checks.json
true|ops/otel-collector/signoz-logs.example.yaml
true|.github/workflows/ci.yml
true|scripts/ci/changed-code.sh
true|scripts/patch_erlexec.exs
true|devbox.json
true|packages/foreman_server/lib/foreman_server.ex
true|packages/foreman_cli/cmd/foreman/main.go
true|packages/jido_harness/mix.lock
true|.beads
true|docs/acceptance
true|xdocs/acceptance/README.md
TABLE
  # One code path among docs-only paths still means code; no paths at all means code.
  got=$(printf '%s\0' .beads/issues.jsonl docs/acceptance/a.md packages/foreman_server/mix.exs | classify 2>/dev/null)
  [ "$got" = true ] || { echo "FAIL: mixed change set -> $got, expected true" >&2; failed=1; }
  got=$(printf '' | classify 2>/dev/null)
  [ "$got" = true ] || { echo "FAIL: empty change set -> $got, expected true" >&2; failed=1; }
  got=$(printf '%s\0' .beads/issues.jsonl docs/lessons/a.md | classify 2>/dev/null)
  [ "$got" = false ] || { echo "FAIL: docs-only change set -> $got, expected false" >&2; failed=1; }
  [ "$failed" -eq 0 ] || exit 1
  echo "changed-code.sh self-test: ok"
}

main() {
  if [ "${1:-}" = "--self-test" ]; then
    self_test
    return
  fi
  if [ "$#" -ne 2 ]; then
    echo "usage: $0 <base> <head> | --self-test" >&2
    exit 2
  fi
  local base=$1 head=$2 result

  # A base that is not in the (shallow) checkout is fetched; a base that cannot be had at all
  # (first push of a branch, all-zero sha, force-pushed away) means "run everything".
  if ! git cat-file -e "$base^{commit}" 2>/dev/null; then
    git fetch --no-tags --depth=1 origin "$base" 2>/dev/null || true
  fi
  if ! git cat-file -e "$base^{commit}" 2>/dev/null; then
    echo "code: cannot resolve base $base, running everything" >&2
    emit true
    return
  fi

  # --no-renames lists BOTH sides of a rename, so moving a file out of a code path into a
  # docs path still counts as touching code.
  if ! result=$(git diff --no-renames --name-only -z "$base" "$head" | classify); then
    echo "code: git diff failed, running everything" >&2
    emit true
    return
  fi
  emit "$result"
}

main "$@"
