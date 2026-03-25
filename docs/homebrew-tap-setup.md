# Homebrew Tap Setup Guide

This document explains how to set up the `oftheangels/homebrew-tap` GitHub repository
and configure the CI/CD deploy key so that foreman releases automatically update
the Homebrew formula.

## Overview

The release pipeline works like this:

```
Push feat/fix commit → release.yml (release-please)
  ↓
Creates / updates Release PR
  ↓
Merge Release PR
  ↓
release-please tags repo (e.g. v1.2.3)
  ↓
release-binaries.yml builds + uploads binaries
  ↓
update-homebrew-tap.yml updates foreman.rb + pushes to oftheangels/homebrew-tap
  ↓
Users: brew tap oftheangels/tap && brew install foreman
```

---

## Step 1: Create the `oftheangels/homebrew-tap` repository

1. Go to [github.com/new](https://github.com/new) (signed in as the `oftheangels` org account
   or any account where `brew tap oftheangels/tap` should resolve).

2. Fill in:
   - **Repository name:** `homebrew-tap`
   - **Description:** `Homebrew tap for tools from oftheangels`
   - **Visibility:** ✅ Public (required for `brew tap` to work without auth)
   - **Initialize with README:** Yes (we'll overwrite it in step 2)

3. Click **Create repository**.

---

## Step 2: Push the formula to the new repo

The `homebrew-tap/` directory in this repository contains the formula and README.
Push it to the new repo:

```bash
# From the foreman repo root
cd homebrew-tap

git init
git add .
git commit -m "feat: initial Foreman formula"
git branch -M main
git remote add origin https://github.com/oftheangels/homebrew-tap.git
git push -u origin main

cd ..
```

---

## Step 3: Generate the SSH deploy key

The `update-homebrew-tap.yml` workflow needs write access to push formula updates
to `oftheangels/homebrew-tap`. It uses an SSH deploy key for this.

Generate an SSH key pair (no passphrase — CI cannot interact):

```bash
ssh-keygen -t ed25519 \
  -f ~/.ssh/homebrew-tap-deploy-key \
  -N "" \
  -C "foreman-cd@github-actions"
```

This creates:
- `~/.ssh/homebrew-tap-deploy-key`       ← **private** key (goes into foreman secrets)
- `~/.ssh/homebrew-tap-deploy-key.pub`   ← **public** key (goes into tap repo deploy keys)

> ⚠️  **Security:** Never commit the private key. Delete it from disk after adding it
> to the GitHub secrets (or store it in a password manager).

---

## Step 4: Add the public key to `oftheangels/homebrew-tap`

1. Open `https://github.com/oftheangels/homebrew-tap/settings/keys/new`
2. Fill in:
   - **Title:** `foreman-cd`
   - **Key:** paste the contents of `~/.ssh/homebrew-tap-deploy-key.pub`
   - **Allow write access:** ✅ checked
3. Click **Add deploy key**.

---

## Step 5: Add the private key to the foreman repo secrets

1. Open `https://github.com/ldangelo/foreman/settings/secrets/actions/new`
2. Fill in:
   - **Name:** `TAP_DEPLOY_KEY`  ← exact case matters
   - **Secret:** paste the full contents of `~/.ssh/homebrew-tap-deploy-key`
     (multi-line, starting with `-----BEGIN OPENSSH PRIVATE KEY-----`)
3. Click **Add secret**.

---

## Step 6: Verify the workflow end-to-end

1. **Create a test release** by making a `feat:` commit and pushing to main:
   ```bash
   git commit --allow-empty -m "feat: trigger test release for homebrew tap"
   git push origin main
   ```

2. **Merge the Release PR** that `release.yml` creates.

3. **Monitor GitHub Actions:**
   - `release-binaries.yml` builds + uploads binaries (~15 min)
   - `update-homebrew-tap.yml` triggers on completion (~2 min)
   - Check the tap repo: the formula version + SHA256s should be updated

4. **Test the installation locally:**
   ```bash
   brew tap oftheangels/tap
   brew install foreman
   foreman --version
   foreman doctor
   ```

---

## Manual tap update (if CI fails)

If `update-homebrew-tap.yml` fails, you can trigger it manually:

1. Go to: `https://github.com/ldangelo/foreman/actions/workflows/update-homebrew-tap.yml`
2. Click **Run workflow**
3. Enter the release tag (e.g. `v1.2.3`)
4. Click **Run workflow**

Or update the formula locally and push directly:

```bash
cd homebrew-tap

# Update version
sed -i '' 's/version ".*"/version "1.2.3"/' Formula/foreman.rb

# Update SHA256s (use sha256sum or shasum -a 256 on macOS)
TAG="v1.2.3"
DARWIN_ARM64=$(curl -fsSL https://github.com/ldangelo/foreman/releases/download/${TAG}/foreman-${TAG}-darwin-arm64.tar.gz | shasum -a 256 | awk '{print $1}')
# ... repeat for other platforms ...

git add Formula/foreman.rb
git commit -m "chore: update foreman formula to v1.2.3"
git push origin main
```

---

## Troubleshooting

### `brew tap oftheangels/tap` fails

- Confirm the repo is **public**
- Confirm the repo name is exactly `homebrew-tap`
- Try: `brew update && brew tap oftheangels/tap`

### `update-homebrew-tap.yml` fails with permission denied

- Check `TAP_DEPLOY_KEY` secret is set correctly in `ldangelo/foreman` secrets
- Check the public key is added with **write access** in `oftheangels/homebrew-tap` deploy keys
- Verify the key pair matches: `ssh-keygen -y -f ~/.ssh/homebrew-tap-deploy-key` should output the same public key

### SHA256 mismatch error during `brew install`

- The formula's `sha256` doesn't match the downloaded archive
- Trigger `update-homebrew-tap.yml` manually (see above) to recompute checksums
- Alternatively, run: `brew install --debug foreman` to see which hash Homebrew computed

### `better_sqlite3.node` not found at runtime

- The native addon must be in the same directory as the `foreman` binary
- The formula installs both to `libexec/foreman/`, which is correct
- If you're running a manually downloaded binary, keep `better_sqlite3.node` in the same directory as the binary

### Formula audit failures

- Run `brew audit --strict oftheangels/tap/foreman` locally to see errors
- Common issues: URL format, missing `license`, SHA256 placeholder values
- Do **not** publish a formula with `PLACEHOLDER_*` SHA256 values — wait for the CD pipeline to fill them in

---

## Architecture Notes

### Why a separate tap repo?

Homebrew requires third-party taps to be separate GitHub repositories named
`homebrew-{tap-name}`. The formula lives in `Formula/` within that repo.

### Why an SSH deploy key instead of a PAT?

Deploy keys are scoped to a single repository (principle of least privilege).
A Personal Access Token would have broader access. SSH deploy keys are the
Homebrew community standard for automated tap updates.

### Why `libexec/foreman/` instead of `bin/` directly?

The `foreman` binary uses `import.meta.url` to locate `better_sqlite3.node`
at runtime. The binary must be co-located with the native addon. Homebrew's
`bin/` directory is for user-facing executables, but we can't guarantee
that `better_sqlite3.node` will be there too. `libexec/` is for private
binary files, and the thin shell wrapper in `bin/foreman` delegates to the
real binary in `libexec/foreman/`.
