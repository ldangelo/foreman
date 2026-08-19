# jido_workspace Spike (JSH-T005, TRD-2026-4212be7e)

Spike date: 2026-08-19
Bead: foreman-4mrx
TRD: TRD-036 (JSH-T005) — Spike jido_workspace worktree binding and sandbox enforcement
Branch: slices/jido-migration

## Scope

Evaluate `jido_workspace` against the five capabilities required by the
migration plan (in-memory VFS, snapshot semantics, host-path adapter,
worktree binding, sandbox enforcement with network deny-by-default and
command allowlist). Compare against the fallback stack `jido_shell` +
`jido_vfs` + custom host-path adapter (per AC-007-3 and TRD-037).

## Pre-condition: package availability

The spike requires reading `packages/foreman_server/deps/jido_workspace`
to evaluate the candidate. **The package is not present in this checkout:**

- `packages/foreman_server/deps/jido_workspace/` — directory does not exist.
- `packages/foreman_server/mix.lock` — no `:jido_workspace` entry.
- `packages/foreman_server/mix.exs` — not declared in `deps/`.
- `JIDO_FORKS.md` — lists `jido_workspace` as a spike candidate (`~> 0.1.0`,
  Apache-2.0, fork pin `fc1e4c11627ca0b9380a21cfa36f248523f5f38d`) but the
  dep is not on disk.
- A repo-wide grep for `jido_workspace` returns only:
  - PRD/TRD prose references (the risk-flagged beta declaration)
  - A single `:jido_workspace_id` variable in
    `packages/foreman_server/deps/jido_shell/lib/jido_shell/backend/bash/jido_interop.ex`
    — this is a session-namespacing identifier, not a git worktree binding.

Without the package on disk we cannot exercise its worktree binding, sandbox
policy, or revision surface. The first column of the capability table is
reported as **UNKNOWN — package not installed** (the gap is the spike result,
not a misread).

## Capabilities evaluated

| Capability                              | jido_workspace                                                                | jido_shell + jido_vfs                                                                                                                                                                              |
|-----------------------------------------|-------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| In-memory VFS                           | UNKNOWN — package not installed in `deps/`                                   | YES — `Jido.VFS.Adapter.InMemory` (Agent-backed, supports `write/read/list/streaming`; `unsupported: [:copy_between]`); mounted via `Jido.Shell.VFS.mount/4`; `Jido.Shell.Agent` is the in-memory-rooted shell session API |
| Snapshot semantics                      | UNKNOWN — package not installed                                              | YES — `Jido.VFS.Adapter.InMemory.Versioning` exposes `commit/2`, `revisions/3`, `read_revision/4`, `rollback/3` returning `%Jido.VFS.Revision{}`. Also: `Jido.VFS.Adapter.Git` (real commits, rollback) and `Jido.VFS.Adapter.Sprite.Versioning` (Sprite checkpoints) |
| Host-path adapter                       | UNKNOWN — package not installed                                              | YES — `Jido.VFS.Adapter.Local` configured with `prefix:` exposes the host filesystem. Documented pattern: `Jido.Shell.VFS.mount("ws", "/code", Jido.VFS.Adapter.Local, prefix: "/path/to/project")` (`Jido.Shell.VFS.mount/4`, `Jido.VFS.Adapter.Local.configure/1`) |
| Worktree binding                        | UNKNOWN — package not installed                                              | NO — neither `jido_shell` nor `jido_vfs` operates on `git worktree` directly. `Jido.Shell.VFS.MountTable` is an ETS-backed mount registry keyed by `workspace_id` (a session namespace, not a git worktree). The `Jido.VFS.Adapter.Git` adapter operates on a *path*; it does not call `git worktree add`. Foreman must wrap the host-path mount with a binding that resolves `worktreePath` -> prefix |
| Network deny-by-default                 | UNKNOWN — package not installed                                              | YES — `Jido.Shell.Sandbox.NetworkPolicy` enforces `default: :deny` on a hard-coded network-command list (`curl wget nc ncat telnet ssh scp sftp ftp ping dig nslookup`). Per-call override via `execution_context.network` with `:allow_domains` / `:block_domains` / `:allow_ports` / `:block_ports`. Default `:deny` is the module-level default (`@moduledoc` line 7) |
| Command allowlist                       | UNKNOWN — package not installed                                              | YES — `Jido.Shell.Command.Registry` is a closed allowlist of 15 registered commands (`echo, pwd, ls, cat, cd, mkdir, write, bash, sleep, seq, help, env, rm, cp`); any unregistered command returns `{:error, :not_found}`. The Bash backend's `JidoInterop` dispatches only registered commands and explicitly blocks host binaries (`grep, sed, curl, …`) |

## Verdict

**FALL BACK to `jido_shell` + `jido_vfs` + custom host-path adapter.**

## Reasoning

The spike cannot validate `jido_workspace` because the package is not
installable in the current tree (no `deps/jido_workspace`, no
`mix.lock` entry, no `mix.exs` declaration). Per the PRD's risk flag
(`jido_workspace ~> 0.1.0`, "in-memory VFS by default; snapshot semantics
evolving; validate worktree binding before production use"), pulling an
unsurfaced beta into the migration build is a net-risking move that the
TRD already anticipated — AC-007-3 and TRD-037 both enumerate the
fallback path explicitly. The installed stack already provides every
capability the migration needs: an in-memory VFS root with versioning
(`Jido.VFS.Adapter.InMemory` + `InMemory.Versioning`), a host-path mount
(`Jido.VFS.Adapter.Local` via `Jido.Shell.VFS.mount/4`), network
deny-by-default (`Jido.Shell.Sandbox.NetworkPolicy`), and a closed
command allowlist (`Jido.Shell.Command.Registry`). The only gap is
**worktree binding to Foreman's `worktreePath`**, which neither upstream
library provides — that is the "custom host-path adapter" piece. The
minimal adapter is a small wrapper that: (1) resolves the agent's
`worktreePath` to a `Jido.VFS.Adapter.Local` prefix, (2) mounts that
prefix at a stable shell path (e.g. `/code`), and (3) refuses to start
a session whose `worktreePath` is outside the Foreman-managed root. The
remaining TRD-098 verification (network deny-by-default + command
allowlisting on host-path worktree) can be re-exercised against this
wrapper unchanged.

## Follow-up

- [ ] TRD-037 (JSH-T006): **adopt fallback** — implement the custom
      host-path adapter that binds `Jido.VFS.Adapter.Local` to Foreman's
      `worktreePath`, wire it into `Jido.Shell.VFS.mount/4`, and enforce
      a path-prefix check before session start. Reuse
      `Jido.Shell.Sandbox.NetworkPolicy` and `Jido.Shell.Command.Registry`
      as the denial/allowlist layers (no fork needed).
- [ ] TRD-038 (JSH-T007): update JIDO_FORKS.md to mark `jido_workspace`
      as "spike-evaluated: rejected — package not present on disk; no
      production path until the upstream dep is installable and the
      worktree-binding contract is published". Update this file in
      `docs/JSH/jido_workspace_spike.md` and reference from the migration
      completion report.
- [ ] TRD-098 (LGC-T003): re-target the sandbox-verification task to the
      custom host-path adapter (the "host-path worktree" in AC-021-4 and
      TRD-098 maps to the wrapper's mounted prefix, not to a git
      worktree).

## Open questions

- Should the custom host-path adapter also persist commits via
  `Jido.VFS.Adapter.Git` (git-snapshot semantics) on top of the local
  prefix, or is the InMemory versioning surface sufficient for checkpoint
  semantics? PRD AC-007-3 names "snapshot semantics" as a required
  capability; InMemory covers it, but a Git-backed host-path mount gives
  durable cross-restart revisions. Decision needed before TRD-037
  implementation.

## Source files reviewed

- `packages/foreman_server/deps/jido_shell/README.md`
- `packages/foreman_server/deps/jido_shell/mix.exs`
- `packages/foreman_server/deps/jido_shell/lib/jido_shell.ex`
- `packages/foreman_server/deps/jido_shell/lib/jido_shell/agent.ex`
- `packages/foreman_server/deps/jido_shell/lib/jido_shell/command.ex`
- `packages/foreman_server/deps/jido_shell/lib/jido_shell/command_runner.ex`
- `packages/foreman_server/deps/jido_shell/lib/jido_shell/command/registry.ex`
- `packages/foreman_server/deps/jido_shell/lib/jido_shell/sandbox/network_policy.ex`
- `packages/foreman_server/deps/jido_shell/lib/jido_shell/sandbox/bash.ex`
- `packages/foreman_server/deps/jido_shell/lib/jido_shell/vfs.ex`
- `packages/foreman_server/deps/jido_shell/lib/jido_shell/vfs/mount.ex`
- `packages/foreman_server/deps/jido_shell/lib/jido_shell/vfs/mount_table.ex`
- `packages/foreman_server/deps/jido_shell/lib/jido_shell/guardrails.ex`
- `packages/foreman_server/deps/jido_shell/lib/jido_shell/application.ex`
- `packages/foreman_server/deps/jido_shell/lib/jido_shell/exec.ex`
- `packages/foreman_server/deps/jido_shell/lib/jido_shell/backend/bash/jido_interop.ex`
- `packages/foreman_server/deps/jido_vfs/README.md`
- `packages/foreman_server/deps/jido_vfs/mix.exs`
- `packages/foreman_server/deps/jido_vfs/lib/jido_vfs.ex`
- `packages/foreman_server/deps/jido_vfs/lib/jido_vfs/adapter/in_memory.ex`
- `packages/foreman_server/deps/jido_vfs/lib/jido_vfs/adapter/in_memory/versioning.ex`
- `packages/foreman_server/deps/jido_vfs/lib/jido_vfs/adapter/local.ex`
- `packages/foreman_server/deps/jido_vfs/lib/jido_vfs/adapter/git.ex`
- `packages/foreman_server/deps/jido_vfs/lib/jido_vfs/adapter/ets.ex`
- `packages/foreman_server/deps/jido_vfs/lib/jido_vfs/adapter/sprite.ex`
- `packages/foreman_server/deps/jido_vfs/lib/jido_vfs/adapter/github.ex`
- `packages/foreman_server/deps/jido_vfs/lib/jido_vfs/adapter/s3.ex`
- `packages/foreman_server/mix.lock`
- `docs/TRD/TRD-2026-4212be7e-jido-migration.md`
- `docs/PRD/PRD-2026-4212be7e-jido-migration.md`
- `JIDO_FORKS.md`

## Adoption Decision (JSH-T006)

Decision: FALL BACK to jido_shell + jido_vfs + custom host-path adapter.

Rationale: jido_workspace is not in deps/. Fallback stack covers in-memory VFS, snapshot semantics, host-path adapter, network deny-by-default, command allowlist. Custom host-path adapter binds to git worktreePath.

Follow-up: TRD-098 (LGC-T003) security isolation test; TRD-037 closed.
