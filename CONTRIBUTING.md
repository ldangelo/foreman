# Contributing to Foreman

Thank you for your interest in contributing to **@oftheangels/foreman**! This document covers development setup, the release process, and how to configure the required secrets for npm publishing.

---

## Table of Contents

1. [Development Setup](#development-setup)
2. [Running Tests](#running-tests)
3. [Publishing to npm](#publishing-to-npm)
   - [One-time Setup: npm Organisation](#one-time-setup-npm-organisation)
   - [One-time Setup: GitHub Secrets](#one-time-setup-github-secrets)
   - [Local .npmrc Configuration](#local-npmrc-configuration)
   - [Release Checklist](#release-checklist)
4. [Binary Releases](#binary-releases)
5. [Troubleshooting](#troubleshooting)

---

## Development Setup

### Prerequisites

- **Node.js ≥ 20** — required by `engines` in `package.json`
- **npm ≥ 9** — for workspaces and `npm ci`
- **[br (beads_rust)](https://github.com/Dicklesworthstone/beads_rust)** — task tracking CLI
- **Anthropic API key** — set `ANTHROPIC_API_KEY` in your environment

### Install and build

```bash
git clone https://github.com/oftheangels/foreman.git
cd foreman
npm install
npm run build
```

### Verify the CLI

```bash
node dist/cli/index.js --help
# or, after `npm link` or global install:
foreman --help
```

---

## Running Tests

```bash
# Run the full test suite (Vitest)
npm test

# Watch mode during development
npm run test:watch

# Type-check without emitting (fast feedback)
npx tsc --noEmit

# Run a single test file
npx vitest run scripts/__tests__/release-workflow.test.ts
```

---

## Publishing to npm

Foreman is published as **`@oftheangels/foreman`** to the public npm registry.  
Publishing is automated via `.github/workflows/publish-npm.yml` and triggered by pushing a git version tag (e.g. `v0.2.0`).

The steps below are **one-time setup** tasks that a project maintainer must complete before the first publish.

---

### One-time Setup: npm Organisation

#### 1. Create (or verify) the `@oftheangels` npm organisation

1. Log in to [npmjs.com](https://www.npmjs.com/) with your personal account.
2. Click your avatar → **Add Organization**.
3. Enter `oftheangels` as the organisation name and select the **free** plan.
4. If the org already exists and you are an owner, skip this step.

#### 2. Enable Two-Factor Authentication (2FA)

npm requires 2FA on accounts that publish scoped packages.

1. Go to **Account Settings → Two-Factor Authentication**.
2. Choose **Authorization and Publishing** mode (strongest protection).
3. Follow the prompts to link an authenticator app.

> **Note:** Once 2FA is enabled at the "Authorization and Publishing" level, manual `npm publish` commands require an OTP. The **automation token** used in GitHub Actions bypasses this requirement automatically.

#### 3. Generate an Automation Token

1. Go to **Account Settings → Access Tokens**.
2. Click **Generate New Token → Classic Token**.
3. Set **Token type** to **Automation** (this bypasses 2FA for CI/CD).
4. Under **Permissions**, ensure **Read and Publish** is selected.
5. Click **Generate Token** and **copy the token immediately** — it is shown only once.

> Keep this token secret. Store it in a password manager until you add it as a GitHub secret (next step).

---

### One-time Setup: GitHub Secrets

You need to add one repository secret. GitHub provides `GITHUB_TOKEN` automatically.

#### Add `NPM_TOKEN`

1. Go to your GitHub repository → **Settings → Secrets and variables → Actions**.
2. Click **New repository secret**.
3. Name: `NPM_TOKEN`
4. Value: paste the automation token copied in the previous step.
5. Click **Add secret**.

#### Secrets reference

| Secret | Source | Purpose |
|--------|--------|---------|
| `NPM_TOKEN` | npmjs.com → Account Settings → Access Tokens | Authenticates `npm publish` in CI/CD |
| `GITHUB_TOKEN` | Auto-provided by GitHub Actions | Not needed for npm publish; used by other workflows |

> **Token rotation:** Automation tokens do not have a built-in expiry, but it is good practice to rotate them annually or whenever a team member with access leaves the project. Repeat step 3 above and update the `NPM_TOKEN` secret.

---

### Local `.npmrc` Configuration

For **local development** (running `npm publish` from your machine), authenticate via the npm CLI rather than editing `.npmrc` directly:

```bash
# Log in once; credentials are stored in ~/.npmrc automatically
npm login --scope=@oftheangels --registry=https://registry.npmjs.org
```

The repository `.npmrc` file uses `${NPM_TOKEN}` interpolation for GitHub Actions. It is safe to commit because it contains no real token — the variable must be set in the environment at publish time.

If you prefer to keep a local token in `.npmrc` for offline workflows, add it to your **user-level** `~/.npmrc` (never the repository `.npmrc`):

```ini
# ~/.npmrc  (user-level — never commit this)
//registry.npmjs.org/:_authToken=npm_YOUR_TOKEN_HERE
```

---

### Release Checklist

Follow these steps every time you release a new version:

```bash
# 1. Ensure you are on the main/dev branch and up-to-date
git checkout dev
git pull origin dev

# 2. Bump the version in package.json
#    Choose: patch (bug fix), minor (new feature), major (breaking change)
npm version patch        # 0.1.0 → 0.1.1
# or: npm version minor  # 0.1.0 → 0.2.0
# or: npm version major  # 0.1.0 → 1.0.0
# This creates a git commit AND a local tag (e.g. v0.1.1)

# 3. Push the commit AND the tag
git push origin dev
git push origin --tags   # triggers publish-npm.yml + release-binaries.yml

# 4. Verify the release
#    • Check https://github.com/<org>/foreman/actions for workflow status
#    • Check https://www.npmjs.com/package/@oftheangels/foreman for the new version
```

#### Manual / dry-run publish

You can trigger a publish manually from the GitHub Actions UI:

1. Go to **Actions → Publish to npm → Run workflow**.
2. Enter the tag name (e.g. `v0.1.1`).
3. Set **dry_run** to `true` to inspect the tarball without publishing.

#### Version pinning rule

The git tag **must** match `package.json` `version` (prefixed with `v`).  
For example, `package.json` version `0.1.1` requires tag `v0.1.1`.  
The publish workflow enforces this and will fail with a clear error if they diverge.

---

## Binary Releases

Standalone binaries (no Node.js required) are built and uploaded to GitHub Releases by `.github/workflows/release-binaries.yml`. This workflow also triggers on version tags.

Both workflows (npm + binaries) run in parallel when you push a version tag. There is no dependency between them — npm publishes the ESM package; binaries workflow compiles platform-specific executables.

See the [README](README.md) for installation instructions for each distribution method.

---

## Troubleshooting

### `npm publish` fails with `E403 Forbidden`

- Verify `NPM_TOKEN` is set correctly in GitHub repository secrets.
- Ensure the token type is **Automation** (not Publish-only or Read-only).
- Check that your account is an owner of the `@oftheangels` organisation on npmjs.com.
- Confirm 2FA is enabled on your npmjs.com account.

### `npm publish` fails with `You cannot publish over the previously published versions`

- The version in `package.json` was already published. Bump the version with `npm version <patch|minor|major>` and push a new tag.

### `Version check failed: git tag (vX.Y.Z) does not match package.json version (vA.B.C)`

- The git tag and `package.json` version are out of sync.
- Run `npm version <new-version>` locally, which updates `package.json` and creates the matching tag, then push both.

### `E401 Unauthorized` during `npm install` in CI

- The `NPM_TOKEN` secret may have expired or been revoked. Generate a new automation token on npmjs.com and update the secret.

### `npm login` prompts for OTP even for automation token

- Make sure you generated an **Automation** token (not a **Publish** token). Automation tokens bypass 2FA.

### Publishing to wrong registry

- The `.npmrc` in this repository sets `registry=https://registry.npmjs.org/`. If your `~/.npmrc` points to a private registry, it may override project settings. Use `npm publish --registry https://registry.npmjs.org` to override explicitly.
