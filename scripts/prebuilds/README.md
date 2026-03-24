# better-sqlite3 Prebuilt Native Addons

This directory contains prebuilt `better_sqlite3.node` native addon files for
all 5 target platforms. These enable cross-platform binary compilation via
`scripts/compile-binary.ts` without requiring native compilation on each target.

## Contents

| Directory       | Platform          | ABI   | Node version |
|-----------------|-------------------|-------|--------------|
| `darwin-arm64/` | macOS Apple Silicon | v115  | Node 20      |
| `darwin-x64/`   | macOS Intel         | v115  | Node 20      |
| `linux-x64/`    | Linux x86_64        | v115  | Node 20      |
| `linux-arm64/`  | Linux ARM64         | v115  | Node 20      |
| `win-x64/`      | Windows 64-bit      | v115  | Node 20      |

## Why Node 20?

The `compile-binary.ts` script uses `pkg` with `node20-*` targets, which embeds
the Node 20 runtime into the compiled binary. The native addon must match the
embedded runtime's ABI (Node Module Version 115).

## Updating

When upgrading `better-sqlite3`, re-run the download script:

```bash
# Download for the installed version automatically
npm run prebuilds:download

# Force re-download all
npm run prebuilds:download:force

# Download for a specific Node.js version
tsx scripts/download-prebuilds.ts --node 22

# Check status
npm run prebuilds:status
```

## Source

Downloaded from [better-sqlite3 GitHub Releases](https://github.com/WiseLibs/better-sqlite3/releases)
via `scripts/download-prebuilds.ts`.
