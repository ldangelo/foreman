#!/usr/bin/env bash
# scripts/e2e/claude_resume_cwd_probe.sh
#
# Measures how the claude CLI resumes a session from a DIFFERENT working directory (spike E9-SP2, point 6).
# pi refuses: a pi session is bound to the directory it was created in and pi asks "Fork this session into
# the current directory? [y/N]". This probe asks the same question of claude, with a real claude (haiku) and
# plain `--resume <id>` (no --fork-session), the way Foreman's claude adapter resumes
# (packages/jido_harness/lib/jido_harness/adapters/claude.ex build_argv):
#
#   A  a git repository: the session is created here and told a random secret word
#   B  a git worktree of A (what a Foreman run worktree is)
#   C  an unrelated empty directory
#   D  another worktree of A that is DELETED after the session was created (Foreman reclaims a run
#      worktree on success), then resumed from C, and again from D recreated at the same path
#
# Every resume asks for the secret word; the only place the agent can know it from is the resumed session.
# A fresh session (no --resume) in the same directory is the control: it must NOT know the word, or the
# question proves nothing. claude runs through a private HOME (scripts/e2e/claude_projects/claude_home.sh):
# stock settings, its own session store, only the operator's login. Nothing here needs a Foreman server.
#
#     bash scripts/e2e/claude_resume_cwd_probe.sh
#
# Environment (all optional): E2E_WORK_DIR (default <repo>/tmp/e2e-claude-resume-cwd; never /tmp), E2E_MODEL_CLAUDE
# (default haiku), E2E_KEEP=1 (keep the work dir). Exit status: 0 every assertion passed (or UNVERIFIED because
# no logged-in claude), 1 environment problem, 3 an assertion failed.

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
E2E_NAME=${E2E_NAME:-rcwd}
E2E_WORK_DIR=${E2E_WORK_DIR:-$ROOT/tmp/e2e-claude-resume-cwd}
E2E_MODEL_CLAUDE=${E2E_MODEL_CLAUDE:-haiku}
# shellcheck source=claude_projects/lib.sh
. "$HERE/claude_projects/lib.sh"
# shellcheck source=claude_projects/claude_home.sh
. "$HERE/claude_projects/claude_home.sh"

for tool in git jq claude; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' is required" 1
done
case "$WORK" in
  /tmp/*|/private/tmp/*|/var/folders/*|/private/var/*) die "E2E_WORK_DIR=$WORK is in a volatile location" 1 ;;
esac
if [ -e "$WORK" ] && [ ! -f "$WORK/.e2e-claude-projects" ] && [ -n "$(ls -A "$WORK" 2>/dev/null)" ]; then
  die "refusing to reuse non-empty $WORK: it lacks the .e2e-claude-projects marker of a previous harness run" 1
fi
install_traps
rm -rf "$WORK"
mkdir -p "$WORK/home" || die "cannot create $WORK" 1
: > "$WORK/.e2e-claude-projects"

say "claude: resuming a session from another working directory (model $E2E_MODEL_CLAUDE)"
claude_private_home || { unverified "claude cross-directory resume" "$CLAUDE_UNAVAILABLE"; summary; exit $?; }
if ! claude_ready; then
  unverified "claude cross-directory resume" "$CLAUDE_UNAVAILABLE"
  summary
  exit $?
fi
note "claude $(claude --version 2>&1 | head -n 1) answers through the private HOME $WORK/home"

# ask <dir> <resume id | ""> <prompt> [extra claude args...] -> ASK_JSON (the --output-format json result), ASK_RC
ask() {
  ask_dir=$1; ask_id=$2; ask_prompt=$3; shift 3
  if [ -n "$ask_id" ]; then
    ASK_JSON=$(cd "$ask_dir" && claude_env claude -p --model "$E2E_MODEL_CLAUDE" --output-format json --resume "$ask_id" "$@" -- "$ask_prompt" </dev/null 2>"$WORK/ask.err")
  else
    ASK_JSON=$(cd "$ask_dir" && claude_env claude -p --model "$E2E_MODEL_CLAUDE" --output-format json "$@" -- "$ask_prompt" </dev/null 2>"$WORK/ask.err")
  fi
  ASK_RC=$?
}
answer() { printf '%s' "$ASK_JSON" | jq -r '.result // empty' 2>/dev/null; }
sid() { printf '%s' "$ASK_JSON" | jq -r '.session_id // empty' 2>/dev/null; }

QUESTION="What was the secret word I told you at the start of this conversation? Reply with only the word, or with the single word unknown if you were not told one."

A="$WORK/A"; B="$WORK/B"; C="$WORK/C"; D="$WORK/D"
mkdir -p "$A" "$C"
git -C "$A" init -q -b main
git -C "$A" config user.name probe
git -C "$A" config user.email probe@example.com
printf 'probe\n' > "$A/README.md"
git -C "$A" add README.md
git -C "$A" commit -q -m init
git -C "$A" worktree add -q "$B" -b probe-b
git -C "$A" worktree add -q "$D" -b probe-d
note "A=$A  B=$B (git worktree of A)  C=$C (unrelated directory)  D=$D (git worktree of A, deleted later)"

# ---------------------------------------------------------------- session 1 (A): resumed from A, B, C
WORD="kiwi-$RANDOM-$RANDOM-$(date +%s)"
ask "$A" "" "Remember this secret word exactly: $WORD . Reply with just: stored"
SID=$(sid)
assert_eq "A: the session was created (exit status)" "$ASK_RC" "0"
[ -n "$SID" ] || die "no session id came back from claude: $(printf '%s' "$ASK_JSON" | head -c 300)" 2
note "session $SID created in A; secret word $WORD"

ask "$C" "" "$QUESTION"
case "$(answer)" in
  *"$WORD"*) fail "control: a FRESH session in C knows the secret word, the question proves nothing" ;;
  *) pass "control: a fresh session (no --resume) does NOT know the secret word ($(answer | head -c 60 | tr '\n' ' '))" ;;
esac

for d in A B C; do
  case "$d" in A) dir=$A; what="the original directory A" ;; B) dir=$B; what="B, a git worktree of A" ;; C) dir=$C; what="C, an unrelated directory" ;; esac
  ask "$dir" "$SID" "$QUESTION"
  got=$(answer)
  if [ "$ASK_RC" = 0 ] && [ "$(sid)" = "$SID" ] && [ "$got" = "$WORD" ]; then
    pass "plain --resume from $what: resumed the SAME session ($SID) and recalled the word"
  else
    fail "plain --resume from $what: exit $ASK_RC, session '$(sid)', answer '$(printf '%s' "$got" | head -c 100 | tr '\n' ' ')', stderr '$(head -c 200 "$WORK/ask.err" | tr '\n' ' ')'"
  fi
done

# ---------------------------------------------------------------- session 2 (D): the original directory is gone
WORD_D="mango-$RANDOM-$RANDOM-$(date +%s)"
ask "$D" "" "Remember this secret word exactly: $WORD_D . Reply with just: stored"
SID_D=$(sid)
[ -n "$SID_D" ] || die "no session id came back from claude for D" 2
git -C "$A" worktree remove --force "$D"
assert_eq "D: the original working directory is gone" "$([ -e "$D" ] && echo present || echo gone)" "gone"
ask "$C" "$SID_D" "$QUESTION"
if [ "$ASK_RC" = 0 ] && [ "$(sid)" = "$SID_D" ] && [ "$(answer)" = "$WORD_D" ]; then
  pass "plain --resume from C after D was DELETED: resumed the same session ($SID_D) and recalled the word"
else
  fail "plain --resume from C after D was deleted: exit $ASK_RC, session '$(sid)', answer '$(answer | head -c 100 | tr '\n' ' ')', stderr '$(head -c 200 "$WORK/ask.err" | tr '\n' ' ')'"
fi
git -C "$A" worktree add -q "$D" probe-d
ask "$D" "$SID_D" "$QUESTION"
if [ "$ASK_RC" = 0 ] && [ "$(sid)" = "$SID_D" ] && [ "$(answer)" = "$WORD_D" ]; then
  pass "plain --resume at D recreated at the same path (what Foreman's fix thread does): same session, word recalled"
else
  fail "plain --resume at D recreated: exit $ASK_RC, session '$(sid)', answer '$(answer | head -c 100 | tr '\n' ' ')'"
fi

# ---------------------------------------------------------------- --fork-session from C (for completeness)
ask "$C" "$SID" "$QUESTION" --fork-session
if [ "$ASK_RC" = 0 ] && [ -n "$(sid)" ] && [ "$(sid)" != "$SID" ] && [ "$(answer)" = "$WORD" ]; then
  pass "--resume --fork-session from C: a NEW session ($(sid)) that still recalls the word"
else
  fail "--resume --fork-session from C: exit $ASK_RC, session '$(sid)', answer '$(answer | head -c 100 | tr '\n' ' ')'"
fi

# ---------------------------------------------------------------- where claude keeps the session
say "evidence: where the session lives and which directories it ran in"
for f in $(claude_session_files); do
  case "$(basename "$f" .jsonl)" in "$SID") ;; *) continue ;; esac
  note "session file: ${f#"$WORK"/home/.claude/projects/}"
  note "cwd recorded per record (count): $(jq -r 'select(.cwd != null) | .cwd' "$f" | sed "s|$WORK/||" | sort | uniq -c | tr '\n' ';')"
done
assert_eq "the session file stays under the project directory of A (not copied to B's or C's)" \
  "$(claude_session_files | while read -r f; do [ "$(basename "$f" .jsonl)" = "$SID" ] && basename "$(dirname "$f")"; done | sed 's/.*-//' | tr '\n' ' ')" "A "

summary
exit $?
