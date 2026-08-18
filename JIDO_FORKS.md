# Jido Forks Manifest

This document records the Jido package forks under `Sunstone-Partners/*` that
back the Jido ecosystem migration described in
`docs/TRD/TRD-2026-4212be7e-jido-migration.md`. Every package is sourced from
a Sunstone-Partners fork pinned to a specific commit revision.

This manifest implements **JRM-T001** (fork creation) and **JRM-T002** (fork
URL + pinned commit revision record). It is the single source of truth for
which fork and which SHA each Foreman dependency must reference in
`packages/foreman_server/mix.exs` (task **JCR-T001**).

## How to use this manifest

`packages/foreman_server/mix.exs` (after JCR-T001) declares each Jido
package as a `:git` dependency pointing to `https://github.com/Sunstone-Partners/<repo>`
with `ref: "<sha>"`. To upgrade a package:

1. Bump the SHA in the table below to the new upstream HEAD.
2. Update the corresponding `ref:` in `mix.exs`.
3. Re-run `mix deps.get && mix compile && mix test`.

The `JRM-T003` CI workflow (PR 5 Story 5.1) runs the test suite on every
upstream release and adopts the upgrade only when the suite is green.

## Fork inventory (pinned 2026-08-18)

| # | Package | Fork URL | Parent | Upstream HEAD SHA | Pinned SHA | License | Notes |
|---|---------|----------|--------|-------------------|------------|---------|-------|
| 1 | `jido` | https://github.com/Sunstone-Partners/jido | `agentjido/jido` | `accea666713bda68e3d6802024584bfbd95aea2b` | `accea666713bda68e3d6802024584bfbd95aea2b` | Apache-2.0 | Core framework: `cmd/2` loop, struct, directives |
| 2 | `jido_action` | https://github.com/Sunstone-Partners/jido_action | `agentjido/jido_action` | `2b6dfb57441454d290cfc3552767fb177ea14a2d` | `2b6dfb57441454d290cfc3552767fb177ea14a2d` | Apache-2.0 | `Jido.Action` behaviour, validation middleware |
| 3 | `jido_signal` | https://github.com/Sunstone-Partners/jido_signal | `agentjido/jido_signal` | `e3f8a34184dfee60f765695d9ca65ac56426ef8a` | `e3f8a34184dfee60f765695d9ca65ac56426ef8a` | Apache-2.0 | CloudEvents pub/sub bus (`foreman/commands`, `foreman/operator`, `foreman/inbox`, `agents/<id>/directive`) |
| 4 | `jido_shell` | https://github.com/Sunstone-Partners/jido_shell | `agentjido/jido_shell` | `a180289345e3f2c5b659ed0ea2c4f20fabeeef2f` | `a180289345e3f2c5b659ed0ea2c4f20fabeeef2f` | Apache-2.0 | Command execution with VFS sandbox |
| 5 | `jido_vfs` | https://github.com/Sunstone-Partners/jido_vfs | `agentjido/jido_vfs` | `ca34ffb5a303313cf9b878fecb78e6d8bf7d7538` | `ca34ffb5a303313cf9b878fecb78e6d8bf7d7538` | Apache-2.0 | Sandbox virtual filesystem |
| 6 | `jido_ai` | https://github.com/Sunstone-Partners/jido_ai | `agentjido/jido_ai` | `7da2579d32e5ad8e946c06890ac50a793867b0f7` | `7da2579d32e5ad8e946c06890ac50a793867b0f7` | Apache-2.0 | ReAct/CoT reasoning strategies |
| 7 | `jido_harness` | https://github.com/Sunstone-Partners/jido_harness | `agentjido/jido_harness` | `e41fc1651282469f2db4219a48d9f7feef1b0dbc` | `e41fc1651282469f2db4219a48d9f7feef1b0dbc` | Apache-2.0 | `Jido.Harness.Adapters.Pi` — replaces `pi-sdk-runner.ts` |
| 8 | `jido_ecto` | https://github.com/Sunstone-Partners/jido_ecto | `agentjido/jido_ecto` | `d5993d93be7885f62336251b4b7eb95aa88eef52` | `d5993d93be7885f62336251b4b7eb95aa88eef52` | Apache-2.0 | Agent struct + checkpoint persistence (Postgres) |
| 9 | `req_llm` | https://github.com/Sunstone-Partners/req_llm | `agentjido/req_llm` | `e8d51edd24cf7bc08c3785f25f6bff95846f23e0` | `e8d51edd24cf7bc08c3785f25f6bff95846f23e0` | Apache-2.0 | LLM HTTP client used by `jido_ai` |
| 10 | `jido_otel` | https://github.com/Sunstone-Partners/jido_otel | `agentjido/jido_otel` | `e7b1c67ed841da642c38efdb62e884ff9a6c7588` | `e7b1c67ed841da642c38efdb62e884ff9a6c7588` | Apache-2.0 | OTEL spans (cmd/2, LLM, signals) |
| 11 | `jido_mcp` | https://github.com/Sunstone-Partners/jido_mcp | `agentjido/jido_mcp` | `8986c4cbf4f5e89d9f9a7a4c096d45e45a514863` | `8986c4cbf4f5e89d9f9a7a4c096d45e45a514863` | Apache-2.0 | MCP client pool with agent toolset sync |
| 12 | `jido_live_dashboard` | https://github.com/Sunstone-Partners/jido_live_dashboard | `agentjido/jido_live_dashboard` | `a2c27fa5c1a2ca7cf7f14b1ed0a1d498c5a45ccc` | `a2c27fa5c1a2ca7cf7f14b1ed0a1d498c5a45ccc` | Apache-2.0 | Phoenix LiveView dashboard for agent state |
| 13 | `jido_workspace` | https://github.com/Sunstone-Partners/jido_workspace | `agentjido/jido_workspace` | `fc1e4c11627ca0b9380a21cfa36f248523f5f38d` | `fc1e4c11627ca0b9380a21cfa36f248523f5f38d` | Apache-2.0 | Worktree binding + sandbox (spike candidate) |
| 14 | `litellm-langfuse-stack` | https://github.com/Sunstone-Partners/litellm-langfuse-stack | `langfuse/oss-llmops-stack` | `5af05d234cb27565e3fd7a603fd945d2e4c7ec5a` | `5af05d234cb27565e3fd7a603fd945d2e4c7ec5a` | MIT | LiteLLM gateway + Langfuse tracing stack |

## Companion packages (NOT under Sunstone-Partners)

The following packages remain sourced directly from upstream because they are
infrastructure, not framework code. They are listed for completeness:

- `zoi` — `packages/jido_harness/deps/zoi` (vendored) — jido_harness runtime dep
- `telemetry`, `req`, `jason`, `erlexec`, `nimble_*`, etc. — standard Hex
  packages used by jido_harness and its deps; vendored under
  `packages/jido_harness/deps/` for offline builds.

## Why fork?

Foreman owns the Jido ecosystem's release cadence for its own work. The fork
gives us:

1. **Deterministic, auditable pins** — every Jido package version is exactly
   one SHA, traceable to upstream commit metadata.
2. **CI-controlled upgrades** — `JRM-T003` runs the test suite on every
   upstream release before adopting the upgrade. No silent breakages.
3. **In-house patches** — we can carry Foreman-specific patches (e.g. extra
   telemetry, Foreman auth integration) on our own fork and rebase against
   upstream on our schedule.
4. **Independence from upstream org policy** — a deletion, rename, or access
   change at `agentjido` does not break our build.

## Re-syncing with upstream

The full `JRM-T003` upgrade protocol is described in
`docs/TRD/TRD-2026-4212be7e-jido-migration.md` Story 5.1. Summary:

1. Upstream release detected (webhook or scheduled poll).
2. `gh api repos/agentjido/<repo>/commits/main` fetches new HEAD SHA.
3. `git fetch upstream` in the local Sunstone-Partners fork clone; fast-forward
   `main` to upstream HEAD.
4. CI runs `mix test` against every package plus the full Foreman test suite.
5. Suite green → adopt (no PR needed; SHA in this manifest is bumped).
6. Suite red → leave `main` pinned to last-known-good; alert operator.
