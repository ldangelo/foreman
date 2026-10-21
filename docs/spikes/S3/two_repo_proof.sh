#!/usr/bin/env bash
# Throwaway proof for spike S3 (docs/spikes/S3.md). Needs only git, python3, jq.
# Models, with real git against scratch repos, what the multi-repo executor would do:
#   * one worktree per repo under the run directory, same branch name in each repo
#   * per-repo base branch (a on `main`, b on `develop`, c untouched)
#   * the env contract of two phases (legacy vars = primary; FOREMAN_REPOS = all)
#   * per-repo "touched" detection, diff capture, push, and partial push failure + retry
#   * rollback when the SECOND worktree cannot be created
#   * the VfsIsolation prefix pitfall (`String.starts_with?`) and the list-of-roots fix
# Exits non-zero naming the failing assertion.
set -u
ROOT="$(mktemp -d /tmp/s3-proof.XXXXXX)"
trap 'chmod -R u+rwx "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT
export GIT_AUTHOR_NAME=s3 GIT_AUTHOR_EMAIL=s3@example.com GIT_COMMITTER_NAME=s3 GIT_COMMITTER_EMAIL=s3@example.com
FAILS=0
ok()   { echo "  ok   - $1"; }
fail() { echo "  FAIL - $1"; FAILS=$((FAILS+1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected '$3' got '$2')"; fi; }

PROJECT=proj; TASK=task-1; RUN=run-abc
RUN_DIR="$ROOT/worktrees/$PROJECT/$TASK/$RUN"
BRANCH="foreman/$TASK/$RUN"

mkrepo() { # id default_branch
  local id="$1" br="$2"
  git init -q --bare "$ROOT/origin-$id.git"
  git init -q -b "$br" "$ROOT/repo-$id"
  ( cd "$ROOT/repo-$id" && echo "v0 $id" > README && git add README && git commit -qm init \
    && git remote add origin "$ROOT/origin-$id.git" && git push -q origin "$br" )
}
mkrepo a main; mkrepo b develop; mkrepo c main

# ---- repositories[] as the project would hold it (id, path, default_branch, primary) ----
cat > "$ROOT/repositories.json" <<JSON
[{"id":"a","path":"$ROOT/repo-a","default_branch":null,"primary":true},
 {"id":"b","path":"$ROOT/repo-b","default_branch":null,"primary":false},
 {"id":"c","path":"$ROOT/repo-c","default_branch":null,"primary":false}]
JSON

echo "== 1. provision worktrees (primary at <run>/workspace, others at <run>/repos/<id>)"
declare -A WT BASE_BRANCH BASE_REF OPID
provision() { # id primary?
  local id="$1" prim="$2" path repo="$ROOT/repo-$1"
  if [ "$prim" = true ]; then path="$RUN_DIR/workspace"; OPID[$id]="wt-$RUN"; else path="$RUN_DIR/repos/$id"; OPID[$id]="wt-$RUN-$id"; fi
  BASE_BRANCH[$id]="$(git -C "$repo" symbolic-ref --quiet --short HEAD)"      # = RunExecutor.checkout_branch/1
  BASE_REF[$id]="$(git -C "$repo" rev-parse --verify 'HEAD^{commit}')"        # = resolve_revision(root,"HEAD")
  mkdir -p "$(dirname "$path")"
  git -C "$repo" worktree add -q -b "$BRANCH" "$path" "${BASE_REF[$id]}" || return 1
  WT[$id]="$path"
}
provision a true && provision b false && provision c false && ok "3 worktrees created" || fail "provision"
assert_eq "primary worktree path keeps legacy leaf 'workspace'" "${WT[a]}" "$RUN_DIR/workspace"
assert_eq "op id of primary unchanged" "${OPID[a]}" "wt-$RUN"
assert_eq "base branch of b is its own checkout branch" "${BASE_BRANCH[b]}" "develop"
sorted="$(printf '%s\n' "${OPID[a]}" "${OPID[b]}" "${OPID[c]}" | LC_ALL=C sort | head -1)"
assert_eq "worktrees_for_run sort (by operation_id) lists primary first" "$sorted" "wt-$RUN"

echo "== 2. env contract, phase 1 and phase 2 (legacy vars are the PRIMARY's)"
repos_json() {
  python3 - "$ROOT" "$BRANCH" "$RUN_DIR" <<'PY'
import json,sys,os,subprocess
root,branch,run_dir=sys.argv[1:4]
repos=json.load(open(root+"/repositories.json"))
out={}
for r in repos:
    i=r["id"]
    wt=(run_dir+"/workspace") if r["primary"] else (run_dir+"/repos/"+i)
    base_branch=subprocess.check_output(["git","-C",r["path"],"symbolic-ref","--quiet","--short","HEAD"],text=True).strip()
    base_ref=subprocess.check_output(["git","-C",r["path"],"rev-parse","HEAD"],text=True).strip()
    out[i]={"path":wt,"repo_path":r["path"],"branch":branch,"base_branch":base_branch,"base_ref":base_ref,"primary":r["primary"]}
print(json.dumps(out,separators=(",",":"),sort_keys=True))
PY
}
phase_env() { # prints env as KEY=VALUE lines (what foreman_env/4 would return)
  local rj; rj="$(repos_json)"
  echo "FOREMAN_WORKTREE=1"
  echo "FOREMAN_RUN_ID=$RUN"
  echo "FOREMAN_WORKTREE_PATH=${WT[a]}"
  echo "FOREMAN_EXPECTED_BRANCH=$BRANCH"
  echo "FOREMAN_BASE_BRANCH=${BASE_BRANCH[a]}"
  echo "FOREMAN_SOURCE_REVISION=${BASE_REF[a]}"
  echo "FOREMAN_PRIMARY_REPO=a"
  echo "FOREMAN_REPOS=$rj"
  # per-repo convenience vars: FOREMAN_REPO_<ID>_WORKTREE with ID upper-cased, [^A-Z0-9] -> _
  echo "$rj" | jq -r 'to_entries[] | "FOREMAN_REPO_\(.key|ascii_upcase|gsub("[^A-Z0-9]";"_"))_WORKTREE=\(.value.path)"'
}
p1="$(phase_env)"; p2="$(phase_env)"
assert_eq "phase 1 == phase 2 env (repo set is run-scoped)" "$p1" "$p2"
get() { echo "$1" | grep "^$2=" | cut -d= -f2-; }
assert_eq "FOREMAN_WORKTREE_PATH is primary" "$(get "$p1" FOREMAN_WORKTREE_PATH)" "${WT[a]}"
assert_eq "FOREMAN_REPO_B_WORKTREE" "$(get "$p1" FOREMAN_REPO_B_WORKTREE)" "${WT[b]}"
n="$(get "$p1" FOREMAN_REPOS | jq 'length')"; assert_eq "FOREMAN_REPOS lists 3 repos" "$n" "3"
assert_eq "FOREMAN_REPOS.b.base_branch" "$(get "$p1" FOREMAN_REPOS | jq -r .b.base_branch)" "develop"
# single-repo project: FOREMAN_REPOS still emitted with one entry, legacy vars identical
echo "$p1" | grep -E '^FOREMAN_REPO_[A-C]_WORKTREE' | sed 's/^/     /'

echo "== 3. the agent, cwd = primary worktree, edits siblings via env paths"
( cd "${WT[a]}" && echo "VERSION=2" > VERSION && git add VERSION && git commit -qm "a: bump" )
bpath="$(get "$p1" FOREMAN_REPOS | jq -r .b.path)"
( cd "$bpath" && echo "VERSION=2" > VERSION && git add VERSION && git commit -qm "b: bump" )
ok "commits made in a and b; c untouched"

echo "== 4. per-repo touched detection + diff capture (Review.Capture archive layout)"
ahead() { git -C "${WT[$1]}" rev-list --count "${BASE_REF[$1]}..HEAD"; }
assert_eq "a ahead" "$(ahead a)" "1"; assert_eq "b ahead" "$(ahead b)" "1"; assert_eq "c ahead (no PR)" "$(ahead c)" "0"
ARCH="$ROOT/archive/run/$RUN"; mkdir -p "$ARCH/diffs"
git -C "${WT[a]}" diff --find-renames "${BASE_REF[a]}..HEAD" > "$ARCH/diff.patch"
git -C "${WT[a]}" diff --name-status --find-renames "${BASE_REF[a]}..HEAD" > "$ARCH/changed-files.txt"
for i in b c; do
  git -C "${WT[$i]}" diff --find-renames "${BASE_REF[$i]}..HEAD" > "$ARCH/diffs/$i.patch"
  git -C "${WT[$i]}" diff --name-status --find-renames "${BASE_REF[$i]}..HEAD" > "$ARCH/diffs/$i.files.txt"
done
[ -s "$ARCH/diff.patch" ] && ok "diff.patch (primary) non-empty" || fail "diff.patch empty"
[ -s "$ARCH/diffs/b.patch" ] && ok "diffs/b.patch non-empty" || fail "diffs/b.patch empty"
[ ! -s "$ARCH/diffs/c.patch" ] && ok "diffs/c.patch empty -> diff_status 'empty' (untouched)" || fail "c diff not empty"

echo "== 5. per-repo push; b's origin made read-only => partial failure"
chmod -R a-w "$ROOT/origin-b.git"
declare -A PUSH
for i in a b; do
  if git -C "$ROOT/repo-$i" push -q origin "$BRANCH" 2>"$ROOT/push-$i.err"; then PUSH[$i]=pushed; else PUSH[$i]=create_failed; fi
done
assert_eq "a pushed" "${PUSH[a]}" "pushed"; assert_eq "b create_failed (typed per-repo state)" "${PUSH[b]}" "create_failed"
completed_with_errors=false; for i in a b; do [ "${PUSH[$i]}" = create_failed ] && completed_with_errors=true; done
assert_eq "derived completed_with_errors" "$completed_with_errors" "true"
[ -d "${WT[b]}" ] && ok "b worktree RETAINED for retry (cleanup deferred)" || fail "b worktree gone"
git -C "$ROOT/origin-a.git" rev-parse --verify -q "refs/heads/$BRANCH" >/dev/null && ok "a branch exists on origin-a" || fail "a not on origin"
git -C "$ROOT/origin-b.git" rev-parse --verify -q "refs/heads/$BRANCH" >/dev/null && fail "b should NOT be on origin-b" || ok "b not on origin-b"
echo "== 6. operator fixes permissions; run.pr.retry --repo-id b (re-runs push for b only)"
chmod -R u+w "$ROOT/origin-b.git"
if git -C "$ROOT/repo-b" push -q origin "$BRANCH" 2>/dev/null; then ok "retry for b pushed"; else fail "retry for b failed"; fi
git -C "$ROOT/origin-a.git" rev-parse "refs/heads/$BRANCH" > "$ROOT/a.sha"
assert_eq "a untouched by b's retry" "$(cat "$ROOT/a.sha")" "$(git -C "${WT[a]}" rev-parse HEAD)"

echo "== 7. cleanup removes every worktree and branch"
for i in a b c; do git -C "$ROOT/repo-$i" worktree remove --force "${WT[$i]}" && git -C "$ROOT/repo-$i" branch -D -q "$BRANCH"; done
for i in a b c; do [ -d "${WT[$i]}" ] && fail "$i worktree remains"; done; ok "all worktrees removed"

echo "== 8. rollback: second worktree creation fails (branch already exists in b)"
git -C "$ROOT/repo-b" branch "$BRANCH"        # simulate a stale branch
RUN2=run-def; RUN_DIR="$ROOT/worktrees/$PROJECT/$TASK/$RUN2"; BRANCH2="$BRANCH"; RUN=$RUN2
git -C "$ROOT/repo-a" branch -q -D "$BRANCH" 2>/dev/null
created=()
rollback() { for i in "${created[@]}"; do git -C "$ROOT/repo-$i" worktree remove --force "${WT[$i]}"; git -C "$ROOT/repo-$i" branch -D -q "$BRANCH"; done; }
for spec in "a true" "b false"; do
  set -- $spec
  if provision "$1" "$2" 2>/dev/null; then created+=("$1"); else echo "     provisioning $1 failed -> {:multi_repo_worktree_failed, \"$1\", reason}"; rollback; break; fi
done
[ -d "${WT[a]}" ] && fail "a worktree leaked after rollback" || ok "a compensated (no half-provisioned run)"
git -C "$ROOT/repo-a" rev-parse --verify -q "refs/heads/$BRANCH" >/dev/null && fail "a branch leaked" || ok "a branch deleted"
git -C "$ROOT/repo-b" branch -D -q "$BRANCH"

echo "== 9. VfsIsolation: prefix check vs list of roots"
python3 - <<'PY'
import sys
def allowed_prefix(root,path): return path.startswith(root)                   # today: String.starts_with?
def allowed_roots(roots,path): return any(path==r or path.startswith(r.rstrip('/')+'/') for r in roots)
primary="/w/run/workspace"; sib="/w/run/repos/b"
assert allowed_prefix(primary,"/w/run/workspace-evil/x"), "today's check passes a sibling-named dir"
assert not allowed_roots([primary,sib],"/w/run/workspace-evil/x")
assert allowed_roots([primary,sib],sib+"/src/a.ex")
assert not allowed_prefix(primary,sib+"/src/a.ex"), "single-root bind (and rebind-replaces) denies the sibling worktree"
print("  ok   - single-root bind denies sibling repos; starts_with? admits 'workspace-evil'; list-of-roots with '/' boundary fixes both")
PY
[ $? -eq 0 ] || fail "vfs model"

echo
if [ "$FAILS" -eq 0 ]; then echo "S3 PROOF: ALL ASSERTIONS PASSED"; else echo "S3 PROOF: $FAILS FAILED"; exit 1; fi
