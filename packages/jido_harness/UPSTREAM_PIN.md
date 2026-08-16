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

Functional behavior of the upstream code is unchanged. The package name
remains `:jido_harness`.

## Deviations from upstream

None. The vendored copy is byte-identical to upstream at the pinned SHA
for `mix.exs`, `mix.lock`, `lib/`, `test/`, `config/`, `LICENSE`, and
`.formatter.exs`. The only additions are:

- `UPSTREAM_PIN.md` — this file.
- `deps/` — vendored hex packages extracted from upstream's `mix.lock`,
  committed so that `mix deps.get` and `mix compile` succeed offline.
- `smoke_test.exs` — a standalone runnable smoke check
  (`mix run smoke_test.exs`) that exercises `Jido.Harness.run(:pi, "ping", [])`
  through a stub adapter and asserts a normalized `RunResult`.

`mix.exs` still declares the app as `:jido_harness`. No upstream code paths
have been edited; the local surface required by the monorepo is satisfied by
the path dependency from `packages/foreman_server/`.

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