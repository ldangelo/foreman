# Adding a jido_harness Provider

This guide explains how to onboard a new coding-agent provider (for
example, a Gemini CLI) into Foreman's `jido_harness` integration.

Both `:pi` and `:claude` already route through a single facade —
`ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter` — backed by the
vendored `Jido.Harness` runtime. Adding a provider is a matter of
declaring it in Foreman's provider list, giving it an install hint, and
covering it with one integration test. No new adapter module is needed.

## Architecture recap

```
AgentRuntime.execute/3  (facade: strategy + backend selection)
        │
        ▼
Router.manual(:jido_harness)  →  AdapterCatalog (availability cached at registration)
        │
        ▼
JidoHarnessAdapter.execute/2  (single facade for every provider)
        │  resolves provider via JidoHarness.request_provider/1
        │  gates on JidoHarness.ReadinessCheck.installed?/1
        ▼
Driver.run/3  →  Jido.Harness.run/3  →  vendored provider adapter
        │
        ▼
RunResult.normalize/1  →  {:ok, text, %{provider:, adapter: :jido_harness}}
```

The vendored `Jido.Harness.Registry` merges its built-in adapters
(`:pi`, `:claude`, `:gemini`, `:grok`, `:kimi`, `:opencode`, `:zai`, …)
with any `:jido_harness, :providers` override. Foreman only surfaces a
provider once it is declared in the two Foreman-side lists below.

## Steps

Assume the new provider atom is `:gemini`.

### 1. Add the provider to the canonical Foreman list

`packages/foreman_server/lib/foreman_server/agent_runtime/jido_harness.ex`

```elixir
@supported_providers [:pi, :claude, :gemini]
```

This one edit makes `JidoHarness.providers/0`, `JidoHarness.provider/1`,
and `JidoHarness.request_provider/1` recognise `:gemini`. Unknown atoms
still return `{:error, :unsupported_provider}` from the adapter.

### 2. Add readiness + install hint

`packages/foreman_server/lib/foreman_server/agent_runtime/jido_harness/readiness_check.ex`

```elixir
@supported_providers [:pi, :claude, :gemini]

def install_hint(:gemini), do: "npm install -g @google/gemini-cli"
```

`installed?/1` probes `Jido.Harness.status(:gemini)`; the vendored
adapter reports whether the provider binary is installed and
authenticated. `run/0` (the `foreman server doctor` source) automatically
iterates the new provider and renders a `✓ gemini available` /
`✗ gemini not found — install with: …` row.

### 3. Confirm the vendored adapter exists

The provider must be registered in the vendored `Jido.Harness.Registry`
(built in, or via the `:jido_harness, :providers` Application env). If the
provider is not one of the vendored built-ins, register its adapter
module there first; the adapter must implement the `Jido.Harness.Adapter`
behaviour (`spec/0`, `status/1`, `run/2`).

### 4. Add one integration test

`packages/foreman_server/test/foreman_server/agent_runtime/jido_harness_integration_test.exs`

Add a stub module for the provider and a test that drives
`AgentRuntime.execute/3` (or `JidoHarnessAdapter.execute/2` directly) and
asserts the normalized `RunResult` shape:

```elixir
assert {:ok, "pong", %{provider: :gemini, adapter: :jido_harness}} =
         JidoHarnessAdapter.execute(
           %{prompt: "ping", context: %{provider: :gemini}},
           []
         )
```

Follow the two-stub pattern already used for `:pi`/`:claude`: one stub
module per provider, each hard-coding its provider atom in `spec/0` and
`status/1`, with a per-module `:persistent_term` installed marker. This
keeps `Jido.Harness.Registry.spec/1`'s `spec.provider == queried`
invariant true when the doctor loop probes several providers in one
window.

## Backend selection

The JidoHarnessAdapter is the sole agent backend (TRD-2026-4212be7e).
The `:agent_runtime, :adapters` list in `config/config.exs` selects
which adapter modules are registered. To use a different backend,
override that list in your deployment config.

## Telemetry

Each run emits `[:foreman, :dispatch, :run, :stop]` with
`%{provider:, status:, run_id:, adapter: :jido_harness}`, and each
readiness probe emits `[:foreman, :dispatch, :provider, :check]` with
`%{provider:, installed:, install_hint:}`. The new provider is carried in
the `provider` metadata field automatically.
