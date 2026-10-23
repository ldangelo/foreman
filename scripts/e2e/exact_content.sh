#!/bin/sh
# Shared by scripts/e2e/claude_projects_flow.sh, failure_injection.sh (through claude_projects/lib.sh)
# and multi_repo.sh: the one place that decides whether a file an agent wrote "contains exactly" a word.
# POSIX sh, sourced, never needed by anything else. Executed directly it runs only its self-test, which
# needs no stack:
#
#     sh scripts/e2e/exact_content.sh
#
# Rule: the content must equal the expected text; only TRAILING newlines may differ (an editor or `echo`
# adds one). Nothing else is dropped: not interior or leading spaces, not a trailing space or carriage
# return, not extra lines. (Comparing after `tr -d ' \n\r'` would accept 'ALPHA -7' for 'ALPHA-7'.)
#
# Needs the harness's pass/fail (lib.sh and multi_repo.sh define them) when called through
# assert_content_exactly.

# content_exactly <actual> <expected>: status 0 when equal up to trailing newlines of <actual>
content_exactly() {
  ce_nl='
'
  ce_actual=$1
  while [ "${ce_actual%"$ce_nl"}" != "$ce_actual" ]; do ce_actual=${ce_actual%"$ce_nl"}; done
  [ "$ce_actual" = "$2" ]
}

# assert_content_exactly <what> <actual> <expected>: PASS/FAIL line through the harness
assert_content_exactly() {
  if content_exactly "$2" "$3"; then
    pass "$1 (= $3, exact content)"
  else
    fail "$1: expected exactly '$3', got '$(printf '%s' "$2" | head -c 200 | tr '\n' ' ')'"
  fi
}

# exact_content_selftest: the comparison must accept the word with trailing newlines and reject anything else
exact_content_selftest() {
  ec_nl='
'
  for ec_probe in \
    'ALPHA-7|ALPHA-7|yes' 'ALPHA-7\n|ALPHA-7|yes' 'ALPHA-7\n\n|ALPHA-7|yes' \
    'ALPHA -7|ALPHA-7|no' 'ALPHA-7\n\n extra|ALPHA-7|no' 'ALPHA-7 \n|ALPHA-7|no' ' ALPHA-7|ALPHA-7|no' \
    'ALPHA-7\r\n|ALPHA-7|no' 'ALPHA-7\nB|ALPHA-7|no' '|ALPHA-7|no' 'ALPHA-7|ALPHA-8|no'; do
    ec_content=${ec_probe%%|*}; ec_rest=${ec_probe#*|}; ec_want=${ec_rest%%|*}; ec_expect=${ec_rest##*|}
    ec_actual=$(printf "$ec_content"; printf x); ec_actual=${ec_actual%x}
    if content_exactly "$ec_actual" "$ec_want"; then ec_got=yes; else ec_got=no; fi
    assert_eq "exact content: '$ec_content' vs '$ec_want'" "$ec_got" "$ec_expect"
  done
}

case "$0" in
  */exact_content.sh | exact_content.sh)
    ec_passed=0; ec_failed=0
    out() { printf '%s\n' "$*"; }
    pass() { out "  PASS  $*"; ec_passed=$((ec_passed + 1)); }
    fail() { out "  FAIL  $*"; ec_failed=$((ec_failed + 1)); }
    assert_eq() { if [ "$2" = "$3" ]; then pass "$1 (= $3)"; else fail "$1: expected '$3', got '$2'"; fi; }
    exact_content_selftest
    out "passed=$ec_passed failed=$ec_failed"
    [ "$ec_failed" -eq 0 ]
    exit $?
    ;;
esac
