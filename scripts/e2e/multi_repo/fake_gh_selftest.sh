#!/bin/sh
# Stack-free self-test of scripts/e2e/multi_repo/fake-gh, in particular its REAL-GIT MODE (foreman-w0tnj): no server, no agent, no
# network, no provider; only git and POSIX sh against throwaway bare repositories under <checkout>/tmp (never /tmp).
#
#     sh scripts/e2e/multi_repo/fake_gh_selftest.sh        # prints passed=N failed=N, exit 0 only when nothing failed
#
# Every behaviour the `realgit` stage of scripts/e2e/multi_repo.sh relies on is checked here first, with its negative control (a
# refusal must really refuse, a merge must really change the right origin and only that one), so a failure of the live stage cannot
# be the shim's fault.
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
GH=${FAKE_GH:-$HERE/fake-gh}
T="$ROOT/tmp/fake-gh-selftest-$$"
PASSED=0
FAILED=0
out() { printf '%s\n' "$*"; }
pass() { out "  PASS  $*"; PASSED=$((PASSED + 1)); }
fail() { out "  FAIL  $*"; FAILED=$((FAILED + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1 (= $3)"; else fail "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1: '$3' not found in: $(printf '%s' "$2" | cut -c1-200)" ;; esac; }

cleanup() { rm -rf "$T"; }
trap cleanup EXIT INT TERM HUP
case "$T" in /tmp/*|/private/tmp/*|/var/folders/*) out "refusing a scratch dir in a volatile location: $T"; exit 1 ;; esac
rm -rf "$T"; mkdir -p "$T"

mk() { # <name>: <T>/<name> checkout with the bare origin <T>/origins/<name>.git
  git init -q --bare -b main "$T/origins/$1.git" && git init -q -b main "$T/$1" || exit 1
  git -C "$T/$1" config user.name e2e; git -C "$T/$1" config user.email e2e@example.com; git -C "$T/$1" config commit.gpgsign false
  printf '# %s\nline one\n' "$1" > "$T/$1/README.md"; git -C "$T/$1" add README.md; git -C "$T/$1" commit -q -m initial
  git -C "$T/$1" remote add origin "$T/origins/$1.git"; git -C "$T/$1" push -q -u origin main
}
branch_commit() { # <repo> <branch> <file> <content> <message> [push 0|1]: a commit on <branch> (created from main), pushed unless 0
  git -C "$T/$1" checkout -q -B "$2" main
  printf '%s\n' "$4" > "$T/$1/$3"; git -C "$T/$1" add "$3"; git -C "$T/$1" commit -q -m "$5"
  [ "${6:-1}" = 1 ] && git -C "$T/$1" push -q -f origin "$2"
  git -C "$T/$1" checkout -q main
}
origin_tip() { git --git-dir="$T/origins/$1.git" rev-parse --verify -q "refs/heads/$2" 2>/dev/null; }
gh_in() { # <state> <cwd> <args...>
  g_state=$1; g_cwd=$2; shift 2
  (cd "$g_cwd" && E2E_GH_STATE="$g_state" sh "$GH" "$@")
}
view() { gh_in "$1" "$2" pr view "$3" --json state,mergeable,headRefOid,headRefName,baseRefName,statusCheckRollup,reviewDecision,reviews,comments,mergeStateStatus; }

mkdir -p "$T/origins"
mk repo-a; mk repo-b

# ---------------------------------------------------------------- default mode (no marker): nothing is validated against git
out "== default mode keeps its old behaviour =="
S0="$T/state-default"
branch_commit repo-a only-local f.txt one "local only" 0
url0=$(gh_in "$S0" "$T/repo-a" pr create --base main --head only-local --title t --body b 2>&1)
eq "a PR for a branch that is NOT on the origin is accepted (the old fake)" "$url0" "https://github.com/e2e-owner/repo-a/pull/1"
out0=$(gh_in "$S0" "$T/repo-a" pr merge "$url0" --squash --match-head-commit "$(git -C "$T/repo-a" rev-parse only-local)" 2>&1)
has "merge only flips a stored state" "$out0" "(fake)"
eq "...and the origin's main did not move" "$(origin_tip repo-a main)" "$(git -C "$T/repo-a" rev-parse main)"

# ---------------------------------------------------------------- real-git mode
out "== real-git mode =="
S="$T/state-real"; mkdir -p "$S"; : > "$S/real-git"
main_a0=$(origin_tip repo-a main); main_b0=$(origin_tip repo-b main)

err=$(gh_in "$S" "$T/repo-a" pr create --base main --head only-local --title t --body b 2>&1); rc=$?
eq "create refuses a head branch that is not on the origin (exit)" "$([ "$rc" -ne 0 ] && echo refused || echo accepted)" "refused"
has "...and says so" "$err" "is not on"
git -C "$T/repo-a" push -q origin main:refs/heads/same-as-main
err=$(gh_in "$S" "$T/repo-a" pr create --base main --head same-as-main --title t --body b 2>&1); rc=$?
eq "create refuses a branch with no commits ahead of the base" "$([ "$rc" -ne 0 ] && echo refused || echo accepted)" "refused"
has "...with GitHub's words" "$err" "No commits between"

branch_commit repo-a feat VERSION 1.4.2 "feat a"
branch_commit repo-b feat VERSION 1.4.2 "feat b"
ua=$(gh_in "$S" "$T/repo-a" pr create --base main --head feat --title "A: add VERSION" --body ba 2>&1)
ub=$(gh_in "$S" "$T/repo-b" pr create --base main --head feat --title "B: add VERSION" --body bb 2>&1)
eq "the PR of repo-a" "$ua" "https://github.com/e2e-owner/repo-a/pull/1"
eq "the PR of repo-b is its own (repo-b/pull/1)" "$ub" "https://github.com/e2e-owner/repo-b/pull/1"
va=$(view "$S" "$T/repo-a" "$ua")
eq "view: headRefOid is the origin's tip of the head branch" "$(printf '%s' "$va" | jq -r .headRefOid)" "$(origin_tip repo-a feat)"
eq "view: state OPEN" "$(printf '%s' "$va" | jq -r .state)" "OPEN"
eq "view: MERGEABLE" "$(printf '%s' "$va" | jq -r .mergeable)" "MERGEABLE"
eq "view: no checks without a CI marker" "$(printf '%s' "$va" | jq -c .statusCheckRollup)" "[]"
eq "repo-a's PR does not read repo-b's origin (different tips)" "$([ "$(origin_tip repo-a feat)" != "$(origin_tip repo-b feat)" ] && echo different || echo same)" "different"

printf 'more\n' > "$T/repo-a/MORE"; git -C "$T/repo-a" checkout -q feat; git -C "$T/repo-a" add MORE; git -C "$T/repo-a" commit -q -m "second"; git -C "$T/repo-a" push -q origin feat; git -C "$T/repo-a" checkout -q main
eq "view follows the branch: the new tip shows up" "$(view "$S" "$T/repo-a" "$ua" | jq -r .headRefOid)" "$(origin_tip repo-a feat)"

# a real conflict
branch_commit repo-a clash README.md "changed on the branch" "clash"
uc=$(gh_in "$S" "$T/repo-a" pr create --base main --head clash --title clash --body c 2>&1)
eq "a branch that does not conflict is MERGEABLE" "$(view "$S" "$T/repo-a" "$uc" | jq -r .mergeable)" "MERGEABLE"
git -C "$T/repo-a" checkout -q main; printf 'changed on main\n' > "$T/repo-a/README.md"; git -C "$T/repo-a" commit -q -am "main moves"; git -C "$T/repo-a" push -q origin main
eq "after main changes the same lines the PR is CONFLICTING" "$(view "$S" "$T/repo-a" "$uc" | jq -r .mergeable)" "CONFLICTING"
git -C "$T/repo-a" reset -q --hard HEAD~1; git -C "$T/repo-a" push -q -f origin main   # put main back for the merge tests below
main_a0=$(origin_tip repo-a main)

# a real check
mkdir -p "$S/ci"; : > "$S/ci/repo-b"
vb=$(view "$S" "$T/repo-b" "$ub")
eq "CI marker on repo-b: the check is FAILING without CI_OK" "$(printf '%s' "$vb" | jq -r '.statusCheckRollup[0].conclusion')" "FAILURE"
eq "...it is named e2e-ci and points at an actions run" "$(printf '%s' "$vb" | jq -r '.statusCheckRollup[0] | "\(.name) \(.detailsUrl)"')" "e2e-ci https://github.com/e2e-owner/repo-b/actions/runs/1"
eq "repo-a has no marker: still no checks" "$(view "$S" "$T/repo-a" "$ua" | jq -c .statusCheckRollup)" "[]"
log=$(gh_in "$S" "$T/repo-a" run view 1 --log-failed -R e2e-owner/repo-b 2>&1)
has "gh run view --log-failed explains the failure" "$log" "CI_OK is missing"
git -C "$T/repo-b" checkout -q feat; printf 'no\n' > "$T/repo-b/CI_OK"; git -C "$T/repo-b" add CI_OK; git -C "$T/repo-b" commit -q -m "wrong"; git -C "$T/repo-b" push -q origin feat
eq "CI_OK with the wrong content keeps it FAILING" "$(view "$S" "$T/repo-b" "$ub" | jq -r '.statusCheckRollup[0].conclusion')" "FAILURE"
printf 'ok\n' > "$T/repo-b/CI_OK"; git -C "$T/repo-b" commit -q -am "fix"; git -C "$T/repo-b" push -q origin feat; git -C "$T/repo-b" checkout -q main
eq "CI_OK containing ok makes it SUCCESS on the new head" "$(view "$S" "$T/repo-b" "$ub" | jq -r '.statusCheckRollup[0].conclusion')" "SUCCESS"
eq "...and the head moved with the fix" "$(view "$S" "$T/repo-b" "$ub" | jq -r .headRefOid)" "$(origin_tip repo-b feat)"

# merges: only the right origin changes
tip_a=$(origin_tip repo-a feat)
err=$(gh_in "$S" "$T/repo-a" pr merge "$ua" --squash --match-head-commit "$main_a0" 2>&1); rc=$?
eq "merge with a wrong head pin is refused (exit)" "$([ "$rc" -ne 0 ] && echo refused || echo accepted)" "refused"
has "...saying the head changed" "$err" "head commit changed"
eq "...and the origin's main did not move" "$(origin_tip repo-a main)" "$main_a0"
eq "...the PR is still OPEN" "$(view "$S" "$T/repo-a" "$ua" | jq -r .state)" "OPEN"
out_m=$(gh_in "$S" "$T/repo-a" pr merge "$ua" --squash --match-head-commit "$tip_a" 2>&1); rc=$?
eq "merge with the real head pin succeeds" "$rc" "0"
has "...and names the squash commit" "$out_m" "squash commit"
main_a1=$(origin_tip repo-a main)
eq "repo-a's main moved" "$([ "$main_a1" != "$main_a0" ] && echo moved || echo same)" "moved"
eq "...by exactly ONE commit" "$(git --git-dir="$T/origins/repo-a.git" rev-list --count "$main_a0..$main_a1")" "1"
eq "...a squash: ONE parent, the old main" "$(git --git-dir="$T/origins/repo-a.git" rev-list --parents -n 1 "$main_a1" | wc -w | tr -d ' ')" "2"
eq "...whose tree has the PR's VERSION" "$(git --git-dir="$T/origins/repo-a.git" show "$main_a1:VERSION")" "1.4.2"
eq "...and the PR's second file" "$(git --git-dir="$T/origins/repo-a.git" show "$main_a1:MORE")" "more"
eq "...titled like the PR" "$(git --git-dir="$T/origins/repo-a.git" log -1 --format=%s "$main_a1")" "A: add VERSION (#1)"
eq "the PR of repo-a is MERGED" "$(view "$S" "$T/repo-a" "$ua" | jq -r .state)" "MERGED"
eq "repo-b's origin main did NOT move" "$(origin_tip repo-b main)" "$main_b0"
eq "repo-b's PR is still OPEN" "$(view "$S" "$T/repo-b" "$ub" | jq -r .state)" "OPEN"
err=$(gh_in "$S" "$T/repo-a" pr merge "$ua" --squash --match-head-commit "$tip_a" 2>&1); rc=$?
eq "a PR that is already merged cannot be merged again" "$([ "$rc" -ne 0 ] && echo refused || echo accepted)" "refused"
out_b=$(gh_in "$S" "$T/repo-b" pr merge "$ub" --squash --match-head-commit "$(origin_tip repo-b feat)" 2>&1); rc=$?
eq "repo-b's PR merges with ITS own head pin" "$rc" "0"
eq "repo-b's main moved by one commit" "$(git --git-dir="$T/origins/repo-b.git" rev-list --count "$main_b0..$(origin_tip repo-b main)")" "1"
eq "...and carries the fix (CI_OK)" "$(git --git-dir="$T/origins/repo-b.git" show "$(origin_tip repo-b main):CI_OK")" "ok"
eq "repo-a's main did not move again" "$(origin_tip repo-a main)" "$main_a1"
eq "no unsupported call was recorded" "$(ls "$S/unsupported.log" 2>/dev/null | wc -l | tr -d ' ')" "0"

out ""
out "passed=$PASSED failed=$FAILED"
[ "$FAILED" -eq 0 ]
