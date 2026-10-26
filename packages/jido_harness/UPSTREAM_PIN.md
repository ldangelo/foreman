# Upstream Pin — jido_harness

This package is a vendored fork of the upstream Elixir library
[`jido_harness`](https://github.com/agentjido/jido_harness).

## Pinned reference

| Field            | Value                                                      |
| ---------------- | ---------------------------------------------------------- |
| Upstream URL     | `https://github.com/agentjido/jido_harness`                |
| Upstream branch  | `main`                                                     |
| Upstream SHA     | `8bf0d52f4fed0d8a9d2594000d8b3a775da16f8b`                 |
| Upstream version | `2.0.0` (per `mix.exs` `@version`)                         |
| Pinned on        | 2026-08-16                                                 |
| License          | Apache License 2.0 — see `LICENSE`                         |

## Build role and sync to the Sunstone fork (2026-10)

`packages/foreman_server` now compiles THIS directory (`{:jido_harness, path:
"../jido_harness", override: true}`), not the Sunstone-Partners fork. To keep
behaviour identical to the previously pinned fork, `lib/`, `test/` and
`mix.exs` were synced verbatim from `Sunstone-Partners/jido_harness` at
`e41fc1651282469f2db4219a48d9f7feef1b0dbc` (adds the Grok 1.0 mapper and
`Jido.Harness.Escript` on top of the upstream SHA above; `mix.lock` and
`config/` were already identical). `smoke_test.exs` is local to this repo.
`test/jido_harness/escript_test.exs` and `fixtures/escript_fixture/` are deliberately NOT
vendored: that test runs `mix escript.build` into this package's shared `_build/test`,
which overwrites the compiled test-support adapters and makes unrelated tests
(`RunManagerTest`, `SessionManagerTest`) fail depending on order, and its fixture
resolves erlexec independently of `mix.lock`. It stays covered in the fork.
Foreman-specific changes (live-input runs, `Run.send_input/3`) land as
ordinary commits here; re-syncing against the fork or upstream must be done
as a deliberate commit that preserves them.

## License (verbatim, first 200 characters)

```
Copyright 2026 Mike Hostetler <mike.hostetler@gmail.com>

Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPR
```

The full license text is preserved verbatim in the `LICENSE` file alongside
this document.

## Vendored source

The following upstream contents are copied verbatim into this directory:

- `mix.exs`
- `lib/`
- `test/`
- `config/`
- `LICENSE`

Functional behavior of the upstream code is NOT unchanged: see the next section.
The package name remains `:jido_harness`.

## Deviations from upstream

This tree is not byte-identical to upstream at the pinned SHA. It differs in
three ways; the first two are described under "Build role and sync" above.

1. **Sync from the Sunstone-Partners fork** (`e41fc165`): the Grok 1.0 mapper
   and `Jido.Harness.Escript`, in neither upstream SHA `8bf0d52f` nor 2.0.0.
2. **Foreman live-input work** (#641, `ecf0e94f`): `Jido.Harness.Run.send_input/3`,
   the optional `live_input_line/2` adapter callback, the `live_input` option in
   `adapters/cli_stream.ex`, and the matching changes in `run/worker.ex`,
   `run/manager.ex` and the `claude` and `pi` adapters, with tests and fixtures.
   Upstream `main` (3.0.0-rc.1) has no `Run.send_input/3`; its steering is ACP-based. A live run's CLI exits only when its stdin
   closes, so `run/worker.ex` also closes it on a terminal event and stops a CLI that outlives the close (`live_exit_grace_ms`),
   and the pi adapter maps a failed `prompt` response to `run_failed` (2026-10-26, see `docs/lessons/run-logs-known-issues.md`).
3. **erlexec process-group startup patch** (below), plus the `deps.get` /
   `deps.loadpaths` / `deps.compile` aliases and a `Code.require_file` line it
   adds to `mix.exs`, and a patched `deps/erlexec/c_src/exec_impl.cpp`.

Local-only additions: `UPSTREAM_PIN.md`, `patches/erlexec/` (the patch above),
`deps/` (committed so `mix deps.get` and `mix compile` succeed offline) and
`smoke_test.exs` (a standalone smoke check, `mix run smoke_test.exs`, that runs
`Jido.Harness.run(:pi, "ping", [])` through a stub adapter and asserts a normalized
`RunResult`).

This repo carries no upstream history, so `8bf0d52f` does not exist here. The delta
introduced inside this repo since the import (`d0af9fb9`) is
`git diff --stat d0af9fb9 -- packages/jido_harness/lib packages/jido_harness/test packages/jido_harness/mix.exs`;
the delta against upstream itself needs a checkout of `agentjido/jido_harness` at
`8bf0d52f` (plus the fork sync at `e41fc165`) to diff against.

### erlexec process-group startup patch

`erlexec` 2.3.4 (hex) lets the parent and the child both call `setpgid()` after
`fork()`, and the child treats any failure as fatal. The harness starts every
process with `{:group, 0}` (`lib/jido_harness/process/driver/erlexec.ex`), so on
macOS a child that exits immediately can die at startup with stderr
`Cannot set effective group to 0: Operation not permitted` and exit status 1; the
harness reports the process as `:failed` instead of `:exited`. This was seen once
as a `ProcessManagerTest` "runs concurrent processes" failure and reproduced in a
300-round, 8-concurrent-`/bin/echo` run (3 failing rounds, clustered within about
four seconds). It could not be re-measured afterwards: the unpatched build showed
0 failures in roughly 24,000 spawns, including under CPU load, so the failure
rate is not established, only the mechanism (the stderr text is exactly the child
fatal path the patch removes).

The fix is a hand port, onto 2.3.4, of upstream `agentjido/jido_harness` commit
`e109aa5` ("synchronize native process group startup"): the parent finishes its
`setpgid()` first and releases a pipe, the child waits on that pipe, then calls
`setpgid()` and tolerates an already-established group (`getpgrp() == gid`). The
patch applies to `c_src/exec_impl.cpp` and is kept as
`patches/erlexec/process-group-startup.patch`.

- `deps/erlexec` here is tracked and committed patched, but the committed copy alone
  does not guarantee a patched build. In PR #662's CI the `jido_harness` job logged
  `* patched erlexec`, i.e. the file was pristine when the script ran. The job restores
  `packages/jido_harness/deps` from an `actions/cache` entry keyed only on `mix.lock`,
  which most likely overwrote the checkout with an older pristine copy (inferred from
  the workflow, not inspected in the cache). The apply script is what guarantees a
  patched build.
- `packages/foreman_server/deps` is gitignored and fetched from hex, so a fresh
  checkout gets stock `erlexec` (confirmed: CI logged the patch step there too).
  `scripts/patch_erlexec.exs` applies the patch from the `deps.get`, `deps.loadpaths`
  and `deps.compile` aliases in both packages' `mix.exs`. It is idempotent (two
  markers), dry-runs first, rebuilds a port that predates already-patched source, and
  fails the build loudly if the patch cannot be applied. That loud failure and the
  tracked patched copy are the guard; there is deliberately no regression test,
  because the race is too rare to reproduce reliably (see above).
- A `mix deps.update` / hex bump of `erlexec` will bring a new base file: re-port
  the patch (or drop it if `saleyn/erlexec` ships the fix), and refresh the markers
  in `scripts/patch_erlexec.exs` if the patched text changes.
- Not observed on Linux, and not tested there, so CI does not exercise the race;
  it does exercise the apply step and a build of the patched C.

## Vendored dependencies

The full transitive dependency tree required to build this package offline
is committed under `deps/`. Both runtime and dev/test deps are vendored
as extracted tarballs (with their original `mix.exs` / `rebar.config` and
source trees intact) so that `mix deps.get` and `mix compile` succeed
without any network access.

Runtime deps (from upstream `mix.exs`):

- `zoi` (`>= 0.17.1 and < 0.19.0`)
- `jason` (`~> 1.4`)
- `telemetry` (`~> 1.3`)
- `erlexec` (`~> 2.3`)

Dev/test deps are vendored as well to keep the upstream `mix test`
reproducible offline (credo, dialyxir, ex_doc, doctor, excoveralls,
git_hooks, git_ops, plus their transitive deps).

## Re-syncing with upstream

To refresh this fork against a newer upstream commit:

1. Clone upstream: `git clone https://github.com/agentjido/jido_harness /tmp/jido_harness_upstream`
2. Copy `mix.exs`, `lib/`, `test/`, `config/`, `LICENSE` over this directory
3. Update the SHA, date, version, and license snippet in this file
4. Re-run `mix deps.get` to refresh `mix.lock` and `deps/`
5. Re-run `mix compile` and `mix test` to confirm parity
6. Re-run `mix run smoke_test.exs` to confirm the local integration point
   still produces a normalized `RunResult`