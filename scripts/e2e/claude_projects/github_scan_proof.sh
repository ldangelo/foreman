#!/usr/bin/env bash
# scripts/e2e/claude_projects/github_scan_proof.sh
#
# Mutation proof for the content scan that guards the temporary public window of the branch-protection stage
# (github_extras.sh: gh_public_scan_history, gh_public_foreign_identities, gh_account_identity; bead foreman-ksy0q). A scan that
# passes proves nothing unless it also fails on what it exists to stop.
#
# A. Builds a LOCAL history shaped like the scratch repository's (the seed commit, a run commit by Foreman
#    <foreman@localhost>, a squash commit on main and a refs/pull/1/merge commit attributed to the account and committed by
#    GitHub), makes the operator clone of it, runs the real scan on it (it must pass), plants ONE violation at a time into a fresh
#    copy AFTER that clone (a token, a foreign identity, a local path, a binary blob, a commit only a tag or another ref class
#    reaches, an annotated tag, ...: the scan must fail and name it), and runs the clean history again.
# B. The identity allowlist line by line, including look-alikes.
# C. How the account identity is derived from `gh api user` (a profile without a public email yields none).
# D. gh_retry_locked, which keeps the repository from staying public: it retries exactly the two refusals GitHub gives while a
#    visibility change is processed ("Repository has been locked.", "A previous visibility change is still in progress"), never another.
#
# The number of expectations is fixed (PROOF_EXPECTED): a scenario that is skipped, dropped or added without updating it makes the
# proof FAIL instead of letting it pass with fewer expectations. Nothing here reads the operator's git configuration.
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
# a name that is not the profile's, for the identities the allowlist must NOT accept: fixed, never read from the operator's git
# config (a scenario that depended on it would be skipped on a host where it is unset or equal to the profile name)
PROOF_OTHER_NAME="Operator Local Name"
[ "$PROOF_OTHER_NAME" != "$PROOF_NAME" ] || PROOF_OTHER_NAME="$PROOF_OTHER_NAME (synthetic)" # distinct from the profile name by construction
# the documented number of expectations (docs/acceptance/live-github-branch-protection.md): change it with the scenarios
PROOF_EXPECTED=61

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

# --- the mutators: each plants ONE violation in a work clone ($PROOF_DIR/mut) and commits it; pushed to PROOF_PUSH_SRC:PROOF_PUSH_REF
# (HEAD:refs/heads/mutation unless the mutator says otherwise)
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
mut_git_identity() { proof_note "note p9"; proof_add "another name with the profile email" "$PROOF_OTHER_NAME" "$PROOF_EMAIL"; }
mut_secret_identity() { proof_note "note p9"; proof_add "this run's webhook secret as the author name" "$GH_HOOK_SECRET" secret@example.com; }
# binary blobs: the NUL sits on its own line so the secrets on the other lines match on any regex engine
mut_binary_clean() { printf '\211PNG\r\n\032\n\0\0\0\rIHDR\0\0\0\001\n' > "$PROOF_DIR/mut/note_p9.txt"; proof_add "a binary blob holding no secret"; }
mut_binary_secret() {
  printf '\0\n%s\nghp_%s\n' "$GH_HOOK_SECRET" "$(proof_rand 36)" > "$PROOF_DIR/mut/note_p9.txt"
  proof_add "a binary blob holding this run's webhook secret and a token-shaped string"
}
mut_binary_pr_ref() { mut_binary_secret && PROOF_PUSH_REF=refs/pull/9/head; }
mut_late_nul() {
  { LC_ALL=C head -c 9000 /dev/zero | LC_ALL=C tr '\0' 'a'; printf '\0\n'; } > "$PROOF_DIR/mut/note_p9.txt"
  proof_add "a NUL byte after 9000 text bytes (git's own binary heuristic reads only the first 8000)"
}

# reachable ONLY from a tag (or a ref of another class) that no branch and no PR ref contains: the operator clone is made before the
# push, as the harness clones at setup and scans later, and a fetch with explicit refspecs follows no tag that points outside the
# fetched history
mut_tag_text() { proof_note "$GH_HOOK_SECRET"; proof_add "a commit only a tag reaches, holding this run's webhook secret"; PROOF_PUSH_REF=refs/tags/v9-leak; }
mut_tag_binary() { mut_binary_secret && PROOF_PUSH_REF=refs/tags/v9-leak; }
mut_other_ref() { mut_token_file && PROOF_PUSH_REF=refs/changes/9/1; }
# an annotated tag has its own message and tagger: <name> <tagger name> <tagger email> <message>, on a commit only the tag reaches
proof_tag() {
  proof_commit "$PROOF_DIR/mut" "a commit only the annotated tag $1 reaches" || return 1
  GIT_COMMITTER_NAME=$2 GIT_COMMITTER_EMAIL=$3 git -C "$PROOF_DIR/mut" -c tag.gpgsign=false -c core.hooksPath=/dev/null tag -a -m "$4" "$1" || return 1
  PROOF_PUSH_SRC=refs/tags/$1
  PROOF_PUSH_REF=refs/tags/$1
}
mut_tag_message() { proof_tag v9-ann seed seed@example.com "release notes ghp_$(proof_rand 36)"; }
mut_tag_tagger() { proof_tag v9-ann "Someone Else" someone@corp.test "release notes"; }
# a tag that points straight at a blob: the content checks read commits only
mut_tag_blob() {
  mt_blob=$(printf '%s\n' "$GH_HOOK_SECRET" | git -C "$PROOF_DIR/mut" hash-object -w --stdin) || return 1
  git -C "$PROOF_DIR/mut" tag v9-blob "$mt_blob" || return 1
  PROOF_PUSH_SRC=refs/tags/v9-blob
  PROOF_PUSH_REF=refs/tags/v9-blob
}

# proof_fresh [mutator]: a fresh copy of the clean origin, a fresh operator clone of it and THEN the mutation, pushed to the origin. The
# clone comes first, as in the harness (it clones at setup and scans much later): whatever the scan sees beyond the clean history, it
# had to fetch itself
proof_fresh() {
  rm -rf "$PROOF_DIR/scen.git" "$PROOF_DIR/mut" "$GH_OP"
  cp -R "$PROOF_DIR/base.git" "$PROOF_DIR/scen.git" || return 1
  git clone -q "$PROOF_DIR/scen.git" "$GH_OP" || return 1
  PROOF_PUSH_SRC=HEAD
  PROOF_PUSH_REF=refs/heads/mutation
  if [ -n "${1:-}" ]; then
    git clone -q "$PROOF_DIR/scen.git" "$PROOF_DIR/mut" || return 1
    "$1" || return 1
    git -C "$PROOF_DIR/mut" push -q origin "$PROOF_PUSH_SRC:$PROOF_PUSH_REF" || return 1
  fi
}

# proof_judge <label> <pass[:<text the scan must print>] | fail:<text the scan must print>[;;<more text>...]>: run the real scan on the
# current $GH_OP and compare
proof_judge() {
  pj_f0=$FAILED; pj_p0=$PASSED; pj_fl0=$FAILURES
  gh_public_scan_history > "$PROOF_DIR/scan.out" 2>&1
  pj_rc=$?
  FAILED=$pj_f0; PASSED=$pj_p0; FAILURES=$pj_fl0 # the scan's own counters are not the proof's verdict
  case "$2" in
    pass | pass:*)
      sed -e 's/^/    | /' "$PROOF_DIR/scan.out"
      pj_want=${2#pass}
      pj_want=${pj_want#:}
      if [ "$pj_rc" = 0 ] && { [ -z "$pj_want" ] || grep -qF -- "$pj_want" "$PROOF_DIR/scan.out"; }; then
        proof_ok "$1: the scan passed${pj_want:+ (printed: $pj_want)}"
      else
        proof_bad "$1: the scan did not pass a history that must pass (rc=$pj_rc${pj_want:+, expected it to print: $pj_want})"
      fi
      ;;
    fail:*)
      grep -E '^  FAIL' "$PROOF_DIR/scan.out" | cut -c1-230 | sed -e 's/^/    | /'
      pj_all=1
      pj_rest=${2#fail:}
      while [ -n "$pj_rest" ]; do
        pj_one=${pj_rest%%;;*}
        grep -qF -- "$pj_one" "$PROOF_DIR/scan.out" || pj_all=0
        case "$pj_rest" in *';;'*) pj_rest=${pj_rest#*;;} ;; *) pj_rest="" ;; esac
      done
      if [ "$pj_rc" != 0 ] && [ "$pj_all" = 1 ]; then
        proof_ok "$1: the scan FAILED it, as required (printed: ${2#fail:})"
      else
        proof_bad "$1: expected the scan to fail with '${2#fail:}' (rc=$pj_rc)"
      fi
      ;;
  esac
}

# proof_scenario <label> <pass[:<text>] | fail:<text>[;;<text>...]> [mutator]
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

# proof_flaky <counter file> <refuse the first N attempts> <refusal text>: a command that refuses its first N attempts
proof_flaky() {
  pf_n=$(($(cat "$1" 2>/dev/null || echo 0) + 1))
  echo "$pf_n" > "$1"
  if [ "$pf_n" -le "$2" ]; then echo "$3"; return 1; fi
  echo "accepted on attempt $pf_n"
}

# proof_retry_case <label> <refuse N attempts> <refusal text> <lock cap seconds> <expect: accepted|gave-up> <attempts: a case pattern>
proof_retry_case() {
  rm -f "$PROOF_DIR/attempts"
  E2E_GH_LOCK_SECS=$4 gh_retry_locked proof_flaky "$PROOF_DIR/attempts" "$2" "$3"
  pr_rc=$?
  pr_n=$(cat "$PROOF_DIR/attempts")
  case "$pr_rc" in 0) pr_got=accepted ;; *) pr_got=gave-up ;; esac
  pr_n_ok=0
  # shellcheck disable=SC2254 # $6 is a case pattern on purpose: a count, or a range of counts (whole-second clocks make the cap approximate)
  case "$pr_n" in $6) pr_n_ok=1 ;; esac
  if [ "$pr_got" = "$5" ] && [ "$pr_n_ok" = 1 ]; then proof_ok "$1: $pr_got after $pr_n attempt(s)"; else proof_bad "$1: expected $5 after $6 attempt(s), got $pr_got after $pr_n"; fi
}

proof_main() {
  proof_build_origin || { proof_bad "cannot build the local origin"; return 1; }
  gh_public_secrets
  # the blobs of the clean history: the fixture's files and the one note file; the clean scenarios must say the scan READ them
  PROOF_NBLOBS=$(($(find "$HERE/github-fixture" -type f | wc -l | tr -d ' ') + 1))
  say "A. gh_public_scan_history on a local history shaped like the scratch repository's"
  proof_scenario "A0. clean: seed commit, a Foreman run commit, a squash commit and a refs/pull/1/merge commit by the account (committer GitHub)" "pass:every blob reachable from any ref ($PROOF_NBLOBS) is text"
  proof_scenario "A1. (i) a token-shaped string in a file" "fail:the TOKEN class matches file contents" mut_token_file
  proof_scenario "A2. (i) a token-shaped string in a commit message only" "fail:git log --all -p: the TOKEN class matches" mut_token_message
  proof_scenario "A3. (i) a token-shaped string as an author name (identity fields are scanned as free text too)" "fail:commit identities: the TOKEN class matches" mut_token_identity
  proof_scenario "A3b. (i) this run's exact webhook secret as an author name (identity fields are checked against the secrets too)" "fail:commit identities: an exact secret or identity of this run appears in identities-scan.txt" mut_secret_identity
  proof_scenario "A4. (i) this run's exact webhook secret in a file" "fail:an exact secret or identity of this run appears in file contents" mut_hook_secret
  proof_scenario "A5. (ii) a commit by the foreign identity Someone Else <someone@corp.test>" "fail:commit identity outside the allowlist" mut_foreign_identity
  proof_scenario "A6. (ii) the same foreign identity, reachable only from refs/pull/9/head" "fail:commit identity outside the allowlist" mut_foreign_pr_ref
  proof_scenario "A7. (iii) a local path /Users/jdoe/... in a file" "fail:the PATH class matches file contents" mut_local_path
  proof_scenario "A8. a FOREMAN_* dump in a file" "fail:the ENV class matches file contents" mut_env_dump
  proof_scenario "A9. a transcript line in a file" "fail:the TRANSCRIPT class matches file contents" mut_transcript
  proof_scenario "A10. a path outside the synthetic fixture" "fail:paths outside the synthetic fixture" mut_outside_path
  proof_scenario "A11. the account's email in a file (allowed in commit identity fields only)" "fail:an exact secret or identity of this run appears in file contents" mut_account_email_file
  proof_scenario "A12. the account's identity in a commit message (allowed in commit identity fields only)" "fail:an exact secret or identity of this run appears in history-all.patch" mut_account_in_message
  proof_scenario "A13. another name (fixed, not from git config) with the profile email as author" "fail:commit identity outside the allowlist;;commit identities: an exact secret or identity of this run appears in identities-scan.txt" mut_git_identity
  proof_scenario "A14. a binary blob (NUL bytes) holding no secret: rejected, not skipped" "fail:binary blob(s) in the history" mut_binary_clean
  proof_scenario "A15. a binary blob holding this run's webhook secret and a token-shaped string: rejected, and its contents are still read" "fail:binary blob(s) in the history;;the TOKEN class matches file contents;;an exact secret or identity of this run appears in file contents" mut_binary_secret
  proof_scenario "A16. the same binary blob, reachable only from refs/pull/9/head" "fail:binary blob(s) in the history;;the TOKEN class matches file contents;;an exact secret or identity of this run appears in file contents" mut_binary_pr_ref
  proof_scenario "A17. a NUL byte after 9000 text bytes (git's own heuristic calls the blob text): rejected all the same" "fail:binary blob(s) in the history" mut_late_nul
  proof_scenario "A18. a commit that only a TAG reaches (no branch, no PR ref) holds this run's webhook secret" "fail:an exact secret or identity of this run appears in file contents" mut_tag_text
  proof_scenario "A19. the binary blob with the exact secret and a token-shaped string, reachable only from a tag" "fail:binary blob(s) in the history;;the TOKEN class matches file contents;;an exact secret or identity of this run appears in file contents" mut_tag_binary
  proof_scenario "A20. a token-shaped string in a commit reachable only from refs/changes/9/1 (neither branch, PR ref nor tag)" "fail:the TOKEN class matches file contents" mut_other_ref
  proof_scenario "A21. an annotated tag whose message holds a token-shaped string (the tagged commit is clean)" "fail:annotated tag messages: the TOKEN class matches" mut_tag_message
  proof_scenario "A22. an annotated tag by the foreign identity Someone Else <someone@corp.test> (the tagged commit is clean)" "fail:commit identity outside the allowlist in the history: Someone Else <someone@corp.test>" mut_tag_tagger
  proof_scenario "A23. a tag that points straight at a blob holding the exact secret" "fail:ref(s) that do not point at a commit" mut_tag_blob
  proof_hidden_profile
  proof_scenario "A-clean-again. the clean history again: it passes only because nothing was planted" "pass:every blob reachable from any ref ($PROOF_NBLOBS) is text"

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
  proof_identity_case foreign "$PROOF_OTHER_NAME <$PROOF_EMAIL>"
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

  say "D. gh_retry_locked: only GitHub's two visibility-change refusals are retried"
  proof_retry_case "no refusal" 0 "unused" 30 accepted 1
  proof_retry_case "403 Repository has been locked (twice), then accepted" 2 "HTTP 403: Repository has been locked." 30 accepted 3
  proof_retry_case "422 a previous visibility change is still in progress (once), then accepted" 1 "HTTP 422: Failed to update visibility. A previous visibility change is still in progress." 30 accepted 2
  proof_retry_case "another error (404) is not retried" 5 "HTTP 404: Not Found" 30 gave-up 1
  proof_retry_case "locked for longer than the cap: gives up (the caller then warns)" 99 "HTTP 403: Repository has been locked." 3 gave-up "[2-4]"

  say "proof summary"
  pn_total=$((PROOF_OK + PROOF_BAD))
  if [ "$pn_total" != "$PROOF_EXPECTED" ]; then
    proof_bad "the proof ran $pn_total expectations but PROOF_EXPECTED (the documented number) is $PROOF_EXPECTED: a scenario was skipped, dropped or added without updating it"
  fi
  out "   expectations held: $PROOF_OK, broken: $PROOF_BAD (documented: $PROOF_EXPECTED)"
  [ "$PROOF_BAD" = 0 ]
}

# the account's real values never reach the output
proof_mask() {
  while IFS= read -r pm_line; do
    pm_line=${pm_line//"$PROOF_ACCOUNT"/<account identity>}
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
