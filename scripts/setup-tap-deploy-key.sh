#!/usr/bin/env bash
# scripts/setup-tap-deploy-key.sh
#
# Helper script to generate the SSH deploy key pair needed for the
# update-homebrew-tap.yml GitHub Actions workflow.
#
# Usage:
#   bash scripts/setup-tap-deploy-key.sh
#
# Prerequisites:
#   - GitHub CLI (gh) installed and authenticated
#   - Write access to both ldangelo/foreman and oftheangels/homebrew-tap
#
# What this script does:
#   1. Generates an ed25519 SSH key pair (no passphrase)
#   2. Adds the PUBLIC key to oftheangels/homebrew-tap as a deploy key (with write)
#   3. Adds the PRIVATE key to ldangelo/foreman as the TAP_DEPLOY_KEY secret
#   4. Deletes the key files from disk (no longer needed after upload)

set -euo pipefail

FOREMAN_REPO="ldangelo/foreman"
TAP_REPO="oftheangels/homebrew-tap"
KEY_COMMENT="foreman-cd@github-actions"
KEY_FILE="/tmp/homebrew-tap-deploy-key-$$"

# ── Colour helpers ──────────────────────────────────────────────────────────
info()    { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
success() { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn()    { printf '\033[1;33m⚠️  %s\033[0m\n' "$*"; }
error()   { printf '\033[1;31m✗ Error:\033[0m %s\n' "$*" >&2; }
die()     { error "$@"; exit 1; }

# ── Pre-flight ──────────────────────────────────────────────────────────────
command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen not found"
command -v gh >/dev/null 2>&1 || die "GitHub CLI (gh) not found. Install: https://cli.github.com"

info "Checking gh authentication..."
gh auth status >/dev/null 2>&1 || die "Not authenticated. Run: gh auth login"

# ── Generate key pair ────────────────────────────────────────────────────────
info "Generating ed25519 SSH deploy key..."
ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "$KEY_COMMENT"
success "Key pair generated: ${KEY_FILE} + ${KEY_FILE}.pub"

# ── Add public key to tap repo ───────────────────────────────────────────────
info "Adding public key to ${TAP_REPO} deploy keys (with write access)..."
gh repo deploy-key add "${KEY_FILE}.pub" \
  --repo "$TAP_REPO" \
  --title "foreman-cd" \
  --allow-write
success "Public key added to ${TAP_REPO}"

# ── Add private key as secret to foreman repo ────────────────────────────────
info "Adding private key as TAP_DEPLOY_KEY secret to ${FOREMAN_REPO}..."
gh secret set TAP_DEPLOY_KEY \
  --repo "$FOREMAN_REPO" \
  --body "$(cat "${KEY_FILE}")"
success "TAP_DEPLOY_KEY secret set in ${FOREMAN_REPO}"

# ── Cleanup ──────────────────────────────────────────────────────────────────
info "Deleting key files from disk..."
rm -f "$KEY_FILE" "${KEY_FILE}.pub"
success "Key files deleted — they exist only in GitHub now"

echo ""
echo "────────────────────────────────────────────────────────────────"
success "Deploy key setup complete!"
echo ""
echo "  Public key  → ${TAP_REPO} deploy keys (write access)"
echo "  Private key → ${FOREMAN_REPO} secret: TAP_DEPLOY_KEY"
echo ""
echo "Next steps:"
echo "  1. Verify the tap repo exists: https://github.com/${TAP_REPO}"
echo "  2. Trigger a test release or run update-homebrew-tap.yml manually"
echo "  3. Test: brew tap oftheangels/tap && brew install foreman"
echo "────────────────────────────────────────────────────────────────"
