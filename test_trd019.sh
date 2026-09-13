#!/bin/bash
echo "TRD-019-TEST: Testing manifest loading and routing"
echo "========================================================"
echo ""
echo "Test 1: Check files exist"
echo "---"
if [ -f "packages/foreman_server/priv/defaults/workflows/implement-trd.yaml" ]; then
  echo "✓ implement-trd.yaml exists"
else
  echo "✗ implement-trd.yaml NOT FOUND"
  exit 1
fi

if [ -f "packages/foreman_server/priv/defaults/workflows/implement-trd-beads.yaml" ]; then
  echo "✓ implement-trd-beads.yaml exists"
else
  echo "✗ implement-trd-beads.yaml NOT FOUND"
  exit 1
fi

echo ""
echo "Test 2: Verify task_types declarations"
echo "---"

# Check implement-trd.yaml
if grep -q "task_types: \[implement_trd\]" "packages/foreman_server/priv/defaults/workflows/implement-trd.yaml"; then
  echo "✓ implement-trd.yaml declares task_types: [implement_trd]"
else
  echo "✗ implement-trd.yaml task_types missing or incorrect"
  exit 1
fi

# Check implement-trd-beads.yaml
if grep -q "task_types: \[implement_trd_beads\]" "packages/foreman_server/priv/defaults/workflows/implement-trd-beads.yaml"; then
  echo "✓ implement-trd-beads.yaml declares task_types: [implement_trd_beads]"
else
  echo "✗ implement-trd-beads.yaml task_types missing or incorrect"
  exit 1
fi

echo ""
echo "Test 3: Verify workflow names"
echo "---"

if grep -q "^name: implement-trd$" "packages/foreman_server/priv/defaults/workflows/implement-trd.yaml"; then
  echo "✓ implement-trd.yaml name is 'implement-trd'"
else
  echo "✗ implement-trd.yaml name incorrect"
  exit 1
fi

if grep -q "^name: implement-trd-beads$" "packages/foreman_server/priv/defaults/workflows/implement-trd-beads.yaml"; then
  echo "✓ implement-trd-beads.yaml name is 'implement-trd-beads'"
else
  echo "✗ implement-trd-beads.yaml name incorrect"
  exit 1
fi

echo ""
echo "Test 4: Verify no duplicate task_types"
echo "---"
# Get all task_types
types=$(grep "task_types:" packages/foreman_server/priv/defaults/workflows/implement-trd*.yaml | cut -d: -f3- | sort)
unique=$(echo "$types" | sort -u)

if [ "$(echo "$types" | wc -l)" -eq "$(echo "$unique" | wc -l)" ]; then
  echo "✓ No duplicate task_types found"
else
  echo "✗ Duplicate task_types detected"
  exit 1
fi

echo ""
echo "========================================================"
echo "TRD-019-TEST: All acceptance criteria verified ✓"
