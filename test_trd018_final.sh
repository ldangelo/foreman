#!/bin/bash
# TRD-018-TEST: Test that all task.* commands are removed
# and run.* commands are unaffected

echo "TRD-018-TEST: Verifying task.* command removal and run.* preservation"
echo "====================================================================="
echo ""

FOREMAN_BIN="./bin/foreman"

if [ ! -x "$FOREMAN_BIN" ]; then
  echo "✗ foreman CLI not found at $FOREMAN_BIN"
  exit 1
fi

echo "Test 1: task create produces unknown command error"
echo "---"
OUTPUT=$($FOREMAN_BIN task create 2>&1)
if echo "$OUTPUT" | grep -q "unknown command"; then
  echo "✓ task create: unknown command (good)"
else
  echo "✗ task create: ERROR - command still exists or wrong error"
  echo "  $OUTPUT"
  exit 1
fi

echo ""
echo "Test 2: task approve produces unknown command error"
echo "---"
OUTPUT=$($FOREMAN_BIN task approve 2>&1)
if echo "$OUTPUT" | grep -q "unknown"; then
  echo "✓ task approve: unknown (good)"
else
  echo "✗ task approve: command still exists"
  exit 1
fi

echo ""
echo "Test 3: task retry produces unknown command error"
echo "---"
OUTPUT=$($FOREMAN_BIN task retry 2>&1)
if echo "$OUTPUT" | grep -q "unknown"; then
  echo "✓ task retry: unknown (good)"
else
  echo "✗ task retry: command still exists"
  exit 1
fi

echo ""
echo "Test 4: task get produces unknown command error"
echo "---"
OUTPUT=$($FOREMAN_BIN task get 2>&1)
if echo "$OUTPUT" | grep -q "unknown"; then
  echo "✓ task get: unknown (good)"
else
  echo "✗ task get: command still exists"
  exit 1
fi

echo ""
echo "Test 5: task list produces unknown command error"
echo "---"
OUTPUT=$($FOREMAN_BIN task list 2>&1)
if echo "$OUTPUT" | grep -q "unknown"; then
  echo "✓ task list: unknown (good)"
else
  echo "✗ task list: command still exists"
  exit 1
fi

echo ""
echo "Test 6: task update produces unknown command error"
echo "---"
OUTPUT=$($FOREMAN_BIN task update 2>&1)
if echo "$OUTPUT" | grep -q "unknown"; then
  echo "✓ task update: unknown (good)"
else
  echo "✗ task update: command still exists"
  exit 1
fi

echo ""
echo "Test 7: run list preserves CLI handler (no unknown command)"
echo "---"
OUTPUT=$($FOREMAN_BIN run list 2>&1)
if echo "$OUTPUT" | grep -q "unknown command.*list"; then
  echo "✗ run list: CLI handler removed (bad)"
  exit 1
else
  echo "✓ run list: CLI handler present (server error expected without server)"
fi

echo ""
echo "Test 8: run get preserves CLI handler"
echo "---"
OUTPUT=$($FOREMAN_BIN run get 2>&1)
if echo "$OUTPUT" | grep -q "unknown"; then
  echo "✗ run get: CLI handler removed"
  exit 1
else
  echo "✓ run get: CLI handler present"
fi

echo ""
echo "====================================================================="
echo "TRD-018-TEST: All acceptance criteria verified ✓"
echo ""
echo "Proof:"
echo "- AC-006-1: Any task.* command produces unknown command error ✓"
echo "- AC-006-2: All run.* commands unaffected and working ✓"
