#!/usr/bin/env bash
# scripts/e2e/claude_projects/github_scan_proof.sh
#
# Mutation proof for the content scan that guards the temporary public window of the branch-protection stage
# (github_extras.sh: gh_public_scan_history, gh_public_foreign_identities, gh_account_identity; bead foreman-ksy0q). A scan that
# passes proves nothing unless it also fails on what it exists to stop.
#
# A. Builds a LOCAL history shaped like the scratch repository's (the seed commit, a run commit by Foreman
#    <foreman@localhost>, a squash commit on main and a refs/pull/1/merge commit attributed to the account and committed by
#    GitHub), runs the real scan on it (it must pass), plants ONE violation at a time into a fresh copy (the scan must fail and
#    name it), and runs the clean history again.
# B. The identity allowlist line by line, including look-alikes.
# C. How the account identity is derived from `gh api user` (a profile without a public email yields none).
#
# Nothing is pushed anywhere: the "remote" is a bare repository in a temporary directory. The only network call is the
# read-only `gh api user` the scan itself makes. The account's real name and email are masked in the output.
#
# Usage:  bash scripts/e2e/claude_projects/github_scan_proof.sh     (git, jq and a logged-in gh; no devbox needed)
# Exit:   0 every expectation held, 1 environment problem, 3 an expectation broke.

# shellcheck disable=SC2034 # ROOT, E2E_NAME, GH_REPO, E2E_API_TOKEN... are read by the sourced libraries
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
E2E_NAME=scanproof
# shellcheck source=lib.sh
. "$HERE/lib.sh"
# shellcheck source=github_extras.sh
. "$HERE/github_extras.sh"

for tool in git jq gh; do command -v "$tool" >/dev/null 2>&1 || die "'$tool' is required" 1; done

PROOF_OK=0
PROOF_BAD=0
proof_ok() { out "  PROOF PASS  $*"; PROOF_OK=$((PROOF_OK + 1)); }
proof_bad() { out "  PROOF FAIL  $*"; PROOF_BAD=$((PROOF_BAD + 1)); }
proof_rand() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$1"; }

PROOF_ACCOUNT=$(gh_account_identity)
[ -n "$PROOF_ACCOUNT" ] || die "gh api user shows no public name and email: the allowed path (the account's own profile identity) cannot be proven with this login" 1
PROOF_NAME=${PROOF_ACCOUNT% <*}
PROOF_EMAIL=${PROOF_ACCOUNT##*<}
PROOF_EMAIL=${PROOF_EMAIL%>}
# the operator's local git name, when it differs from the profile's: an identity the allowlist must NOT accept
PROOF_GITNAME=$(git config --global user.name 2>/dev/null)
[ "$PROOF_GITNAME" != "$PROOF_NAME" ] || PROOF_GITNAME=""

PROOF_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ghscan-proof.XXXXXX") || die "mktemp failed" 1
trap 'rm -rf "$PROOF_DIR"' EXIT
GH_REPO=proof/foreman-scratch-proof # named in messages only, never contacted
GH_OP="$PROOF_DIR/op"
EVID="$PROOF_DIR/evidence"
mkdir -p "$EVID"
E2E_API_TOKEN="proof-api-$(proof_rand 24)"
GH_HOOK_SECRET="proof-hook-$(proof_rand 24)"

# proof_commit <dir> <message> [author name] [author email] [committer name] [committer email]: commit what is staged
# (default identity: the synthetic seed one; the committer defaults to the author)
proof_commit() {
  pc_an=${3:-seed}
  pc_ae=${4:-seed@example.com}
  GIT_AUTHOR_NAME=$pc_an GIT_AUTHOR_EMAIL=$pc_ae GIT_COMMITTER_NAME=${5:-$pc_an} GIT_COMMITTER_EMAIL=${6:-$pc_ae} \
    git -C "$1" -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q --no-verify --allow-empty -m "$2"
}

# proof_build_origin: $PROOF_DIR/base.git, the clean history
proof_build_origin() {
  pb="$PROOF_DIR/seed"
  git init -q --bare -b main "$PROOF_DIR/base.git" && git init -q -b main "$pb" || return 1
  cp -R "$HERE/github-fixture/." "$pb/" || return 1
  git -C "$pb" add -A && proof_commit "$pb" "seed: the synthetic fixture" || return 1
  git -C "$pb" remote add origin "$PROOF_DIR/base.git"
  git -C "$pb" push -q origin main || return 1
  # the run's branch: Foreman's phase-commit identity
  git -C "$pb" checkout -q -b foreman/run-1
  printf 'note p1\n' > "$pb/note_p1.txt"
  git -C "$pb" add note_p1.txt && proof_commit "$pb" "e2e-skip: add note_p1.txt" Foreman foreman@localhost || return 1
  git -C "$pb" push -q origin foreman/run-1 && git -C "$pb" push -q origin foreman/run-1:refs/pull/1/head || return 1
  # the test merge GitHub keeps at refs/pull/1/merge: attributed to the PR author, committed by GitHub
  git -C "$pb" checkout -q -b test-merge main
  git -C "$pb" merge -q --no-ff --no-commit foreman/run-1 >/dev/null 2>&1
  proof_commit "$pb" "Merge pull request #1" "$PROOF_NAME" "$PROOF_EMAIL" GitHub noreply@github.com || return 1
  git -C "$pb" push -q origin test-merge:refs/pull/1/merge || return 1
  # the squash commit `gh pr merge --squash` leaves on main: author = the PR author, committer = GitHub
  git -C "$pb" checkout -q main
  printf 'note p1\n' > "$pb/note_p1.txt"
  git -C "$pb" add note_p1.txt
  proof_commit "$pb" "e2e-skip: add note_p1.txt (#1)

Co-authored-by: Foreman <foreman@localhost>" "$PROOF_NAME" "$PROOF_EMAIL" GitHub noreply@github.com || return 1
  git -C "$pb" push -q origin main
}

# --- the mutators: each plants ONE violation in a work clone ($PROOF_DIR/mut) and commits it; pushed to PROOF_PUSH_REF
proof_add() { git -C "$PROOF_DIR/mut" add -A && proof_commit "$PROOF_DIR/mut" "$@"; }
proof_note() { printf '%s\n' "$1" > "$PROOF_DIR/mut/note_p9.txt"; }
mut_token_file() { printf 'API_KEY=ghp_%s\n' "$(proof_rand 36)" >> "$PROOF_DIR/mut/app.py"; proof_add "plant a GitHub-token-shaped string in app.py"; }
mut_token_message() { proof_add "plant a token in a commit message only: ghp_$(proof_rand 36)"; }
mut_token_identity() { proof_note "note p9"; proof_add "token as the author name" "ghp_$(proof_rand 36)" token@example.com; }
mut_hook_secret() { proof_note "$GH_HOOK_SECRET"; proof_add "plant this run's webhook secret in a note file"; }
mut_foreign_identity() { proof_note "note p9"; proof_add "a foreign author and committer" "Someone Else" someone@corp.test; }
mut_foreign_pr_ref() {
  proof_note "note p9"
  proof_add "a foreign committer reachable only from a PR ref" seed seed@example.com "Someone Else" someone@corp.test
  PROOF_PUSH_REF=refs/pull/9/head
}
mut_local_path() { proof_note "see /Users/jdoe/Development/project/notes.md"; proof_add "plant a local path in a note file"; }
mut_env_dump() { proof_note "FOREMAN_API_TOKEN=abc"; proof_add "plant a FOREMAN_* dump in a note file"; }
mut_transcript() { proof_note '{"role": "assistant", "content": "hello"}'; proof_add "plant a transcript line in a note file"; }
mut_outside_path() { printf 'x=1\n' > "$PROOF_DIR/mut/secrets.env"; proof_add "a path outside the synthetic fixture"; }
mut_account_email_file() { proof_note "$PROOF_EMAIL"; proof_add "plant the account's email in a note file"; }
mut_account_in_message() { proof_add "name the account in a message: Signed-off-by: $PROOF_ACCOUNT"; }
mut_git_identity() { proof_note "note p9"; proof_add "the operator's local git name with the profile email" "$PROOF_GITNAME" "$PROOF_EMAIL"; }

# proof_fresh [mutator]: a fresh copy of the clean origin (+ the mutation, pushed to PROOF_PUSH_REF) and a fresh operator clone
proof_fresh() {
  rm -rf "$PROOF_DIR/scen.git" "$PROOF_DIR/mut" "$GH_OP"
  cp -R "$PROOF_DIR/base.git" "$PROOF_DIR/scen.git" || return 1
  PROOF_PUSH_REF=refs/heads/mutation
  if [ -n "${1:-}" ]; then
    git clone -q "$PROOF_DIR/scen.git" "$PROOF_DIR/mut" || return 1
    "$1" || return 1
    git -C "$PROOF_DIR/mut" push -q origin "HEAD:$PROOF_PUSH_REF" || return 1
  fi
  git clone -q "$PROOF_DIR/scen.git" "$GH_OP"
}

# proof_judge <label> <pass | fail:<text the scan must print>>: run the real scan on the current $GH_OP and compare
proof_judge() {
  pj_f0=$FAILED; pj_p0=$PASSED; pj_fl0=$FAILURES
  gh_public_scan_history > "$PROOF_DIR/scan.out" 2>&1
  pj_rc=$?
  FAILED=$pj_f0; PASSED=$pj_p0; FAILURES=$pj_fl0 # the scan's own counters are not the proof's verdict
  case "$2" in
    pass)
      sed -e 's/^/    | /' "$PROOF_DIR/scan.out"
      if [ "$pj_rc" = 0 ]; then proof_ok "$1: the scan passed"; else proof_bad "$1: the scan rejected a history that must pass"; fi
      ;;
    fail:*)
      grep -E '^  FAIL' "$PROOF_DIR/scan.out" | cut -c1-230 | sed -e 's/^/    | /'
      if [ "$pj_rc" != 0 ] && grep -qF -- "${2#fail:}" "$PROOF_DIR/scan.out"; then
        proof_ok "$1: the scan FAILED it, as required (printed: ${2#fail:})"
      else
        proof_bad "$1: expected the scan to fail with '${2#fail:}' (rc=$pj_rc)"
      fi
      ;;
  esac
}

# proof_scenario <label> <pass | fail:<text>> [mutator]
proof_scenario() {
  say "$1"
  proof_fresh "${3:-}" || { proof_bad "$1: cannot build the scenario"; return 0; }
  proof_judge "$1" "$2"
}

# proof_hidden_profile: the clean history, but the profile publishes no email: the account identity is allowed nowhere
proof_hidden_profile() {
  say "A-hidden. the clean history again, but the account profile publishes no public email"
  proof_fresh || { proof_bad "A-hidden: cannot build the scenario"; return 0; }
  ph_saved=$(declare -f gh_account_identity)
  gh_account_identity() { return 0; }
  proof_judge "A-hidden" "fail:commit identity outside the allowlist"
  eval "$ph_saved"
}

# proof_identity_case <allowed|foreign> <identity line> [account identity to allow]
proof_identity_case() {
  printf '%s\n' "$2" > "$PROOF_DIR/one.txt"
  pi_got=$(gh_public_foreign_identities "$PROOF_DIR/one.txt" "${3-$PROOF_ACCOUNT}")
  case "$1" in
    allowed) if [ -z "$pi_got" ]; then proof_ok "allowed: '$2'"; else proof_bad "'$2' must be allowed"; fi ;;
    foreign) if [ "$pi_got" = "$2" ]; then proof_ok "rejected: '$2'"; else proof_bad "'$2' must be rejected"; fi ;;
  esac
}

# proof_derive_case <label> <expected> <gh stdout> <gh exit status>: gh_account_identity against a faked `gh api user`
proof_derive_case() {
  PROOF_GH_OUT=$3
  PROOF_GH_RC=$4
  gh() { printf '%s' "$PROOF_GH_OUT"; return "$PROOF_GH_RC"; }
  pd_got=$(gh_account_identity)
  unset -f gh
  if [ "$pd_got" = "$2" ]; then proof_ok "$1 -> '${pd_got:-<none>}'"; else proof_bad "$1: expected '${2:-<none>}', got '${pd_got:-<none>}'"; fi
}

proof_main() {
  proof_build_origin || { proof_bad "cannot build the local origin"; return 1; }
  gh_public_secrets
  say "A. gh_public_scan_history on a local history shaped like the scratch repository's"
  proof_scenario "A0. clean: seed commit, a Foreman run commit, a squash commit and a refs/pull/1/merge commit by the account (committer GitHub)" pass
  proof_scenario "A1. (i) a token-shaped string in a file" "fail:the TOKEN class matches file contents" mut_token_file
  proof_scenario "A2. (i) a token-shaped string in a commit message only" "fail:git log --all -p: the TOKEN class matches" mut_token_message
  proof_scenario "A3. (i) a token-shaped string as an author name (identity fields are scanned as free text too)" "fail:commit identities: the TOKEN class matches" mut_token_identity
  proof_scenario "A4. (i) this run's exact webhook secret in a file" "fail:an exact secret or identity of this run appears in file contents" mut_hook_secret
  proof_scenario "A5. (ii) a commit by the foreign identity Someone Else <someone@corp.test>" "fail:commit identity outside the allowlist" mut_foreign_identity
  proof_scenario "A6. (ii) the same foreign identity, reachable only from refs/pull/9/head" "fail:commit identity outside the allowlist" mut_foreign_pr_ref
  proof_scenario "A7. (iii) a local path /Users/jdoe/... in a file" "fail:the PATH class matches file contents" mut_local_path
  proof_scenario "A8. a FOREMAN_* dump in a file" "fail:the ENV class matches file contents" mut_env_dump
  proof_scenario "A9. a transcript line in a file" "fail:the TRANSCRIPT class matches file contents" mut_transcript
  proof_scenario "A10. a path outside the synthetic fixture" "fail:paths outside the synthetic fixture" mut_outside_path
  proof_scenario "A11. the account's email in a file (allowed in commit identity fields only)" "fail:an exact secret or identity of this run appears in file contents" mut_account_email_file
  proof_scenario "A12. the account's identity in a commit message (allowed in commit identity fields only)" "fail:an exact secret or identity of this run appears in history-all.patch" mut_account_in_message
  if [ -n "$PROOF_GITNAME" ]; then
    proof_scenario "A13. the operator's local git name (not the profile's) with the profile email as author" "fail:commit identity outside the allowlist" mut_git_identity
  fi
  proof_hidden_profile
  proof_scenario "A-clean-again. the clean history again: it passes only because nothing was planted" pass

  say "B. gh_public_foreign_identities, one identity per line (the account identity is given)"
  proof_identity_case allowed "seed <seed@example.com>"
  proof_identity_case allowed "operator <operator@example.com>"
  proof_identity_case allowed "GitHub <noreply@github.com>"
  proof_identity_case allowed "Foreman <foreman@localhost>"
  proof_identity_case allowed "$PROOF_ACCOUNT"
  proof_identity_case foreign "Someone Else <someone@corp.test>"
  proof_identity_case foreign "foreman <foreman@localhost>"
  proof_identity_case foreign "Foreman <foreman@localhost.corp.test>"
  proof_identity_case foreign "Foreman <someone@localhost>"
  proof_identity_case foreign "github <noreply@github.com>"
  proof_identity_case foreign "GitHub <noreply@github.com.corp.test>"
  proof_identity_case foreign "GitHub <someone@github.com>"
  proof_identity_case foreign "x <x@notexample.com>"
  proof_identity_case foreign "x <x@evil.example.com>"
  proof_identity_case foreign "x <x@example.com.corp.test>"
  proof_identity_case foreign "x <a@b@example.com>"
  proof_identity_case foreign "Evil <e@corp.test> <a@example.com>"
  proof_identity_case foreign "$PROOF_NAME <someone@corp.test>"
  [ -z "$PROOF_GITNAME" ] || proof_identity_case foreign "$PROOF_GITNAME <$PROOF_EMAIL>"
  proof_identity_case foreign "$PROOF_ACCOUNT "
  proof_identity_case foreign " $PROOF_ACCOUNT"
  proof_identity_case foreign "$PROOF_ACCOUNT"  "" # the profile publishes no email: nothing is allowed for the account
  proof_identity_case allowed "Foreman <foreman@localhost>" ""

  say "C. gh_account_identity against a faked gh api user"
  proof_derive_case "name and public email" "Pat Example <pat@example.org>" '{"login":"pat","name":"Pat Example","email":"pat@example.org"}' 0
  proof_derive_case "email null (not published)" "" '{"login":"pat","name":"Pat Example","email":null}' 0
  proof_derive_case "name null" "" '{"login":"pat","name":null,"email":"pat@example.org"}' 0
  proof_derive_case "empty name and email" "" '{"login":"pat","name":"","email":""}' 0
  proof_derive_case "an error object" "" '{"message":"Bad credentials"}' 0
  proof_derive_case "gh failing" "" 'gh: Bad credentials (HTTP 401)' 1

  say "proof summary"
  out "   expectations held: $PROOF_OK, broken: $PROOF_BAD"
  [ "$PROOF_BAD" = 0 ]
}

# the account's real values never reach the output
proof_mask() {
  while IFS= read -r pm_line; do
    pm_line=${pm_line//"$PROOF_ACCOUNT"/<account identity>}
    [ -z "$PROOF_GITNAME" ] || pm_line=${pm_line//"$PROOF_GITNAME"/<operator git name>}
    pm_line=${pm_line//"$PROOF_EMAIL"/<account email>}
    pm_line=${pm_line//"$PROOF_NAME"/<account name>}
    printf '%s\n' "$pm_line"
  done
}

proof_main > "$PROOF_DIR/proof.out" 2>&1
pm_rc=$?
proof_mask < "$PROOF_DIR/proof.out"
[ "$pm_rc" = 0 ] || exit 3
exit 0
