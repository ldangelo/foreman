# Devbox, otel-collector, SigNoz, toolchain pin

> Archived from the former monolithic `AGENTS.md` (2026-10-18), with accuracy corrections from the PR #561 review, to keep the always-loaded agent context small. `devbox run` catalog and Elixir/OTP pin.
> Section-number references inside (e.g. "section 4", "§5.4") point at the pre-split `AGENTS.md`; the §5 rules are summarised in `AGENTS.md` and full text is in `typed-boundaries-full.md`.

## Devbox — single entry point for the full dev environment

A new dev cloning this repo should be productive with `devbox` alone. The
`devbox.json` at the repo root declares Nix packages (elixir/erlang/postgres/
redis/docker-client/jq/openssl/python3/git/gh/watch/direnv) and a script
catalog that orchestrates the Langfuse stack + otel-collector + the foreman
app from one place.

Prereqs: [Devbox](https://www.jetpack.io/devbox/) (which installs Nix on
macOS/Linux). Once devbox is on PATH, every script below is one
`devbox run X` invocation from the repo root.

The Langfuse/litellm observability stack itself lives in a separate repo
(`~/Development/Sunstone/litellm-langfuse-stack/`). Override that path via
`export LITELLM_LANGFUSE_STACK=/path/to/stack` if yours is elsewhere. The
default works for `~/Development/<org>/<repo>` side-by-side checkouts.

### Common dev workflows

```bash
# ONE-TIME bootstrap (after cloning):
devbox run setup            # copy .env, install mix deps, ensure stack .env

# DAILY:
devbox run up               # bring up Langfuse stack + otel-collector
devbox run server           # start the Phoenix server (foreground)
devbox run iex              # start with iex for interactivity
devbox run ps               # show all services across both repos
devbox run logs             # tail otel-collector logs
devbox run logs:stack       # tail litellm-langfuse stack logs

# TEAR DOWN (preserves volumes):
devbox run down

# FULL RESET (DROPS all data — will prompt):
devbox run reset

# TESTING:
devbox run test             # all tests
devbox run test:langfuse    # only :langfuse-tagged (the OTel+Langfuse e2e path)
devbox run test:unit        # everything except :langfuse

# DATABASE:
devbox run db:migrate
devbox run db:reset
devbox run db:console       # psql on foreman-postgres

# QUICK REFERENCE:
devbox run info             # all commands + status summary
devbox run env:list         # current env vars + endpoints
```

### What `devbox run up` does

1. Sources the litellm-langfuse-stack's `.env` so it can find
   `LANGFUSE_PUBLIC_KEY`/`LANGFUSE_SECRET_KEY`.
2. `cd $LITELLM_LANGFUSE_STACK && docker compose up -d --build` — brings up
   litellm + langfuse-web + langfuse-worker + headroom + postgres + redis
   - clickhouse + minio. (Host ports already pre-remapped in the stack repo
   to avoid analytics-postgres on 5432 and analytics-redis on 6379.)
3. Polls `http://127.0.0.1:3000/api/public/health` up to 30 times (each
   attempt `curl -m 2`, then `sleep 2` after a failure — roughly 120 s worst
   case). If every attempt fails the loop does not abort: startup still
   proceeds to the collector.
4. `cd $DEVBOX_PROJECT_ROOT && docker compose -f ops/otel-collector/docker-compose.yml up -d --build`
   — brings up the in-repo OTel collector (Foreman -> collector -> Langfuse).
5. `devbox run ps` — final status.

### What the otel-collector does

The collector at `ops/otel-collector/` is the bridge between Foreman's OTLP
exporter (`packages/foreman_server/config/config.exs`,
`packages/foreman_server/config/prod.exs`) and Langfuse v3's OTLP ingest
endpoint. Foreman exports to `http://127.0.0.1:4318`; the collector batches,
retries, and forwards to `http://langfuse-web:3000/api/public/otel/v1/traces`
with HTTP Basic auth (`base64(public:secret)`).

Why this exists:

- Langfuse v3's OTLP ingest requires Basic auth with both the public AND
  secret keys — Bearer-with-public-only returns 403. Earlier this session
  shipped that broken shape against real Langfuse; `prod.exs` was patched
  (commit 5296992).
- In dev, Foreman points at the collector; prod deployment points
  directly at the Langfuse ingest URL via the same `OTEL_EXPORTER_OTLP_ENDPOINT`
  env var (see `packages/foreman_server/config/prod.exs`).

### SigNoz operational logs (separate from the Langfuse path above)

`FOREMAN_SIGNOZ_LOGS_ENABLED`, `FOREMAN_SIGNOZ_OTLP_ENDPOINT`,
`FOREMAN_SIGNOZ_OTLP_HEADERS`, and `FOREMAN_SIGNOZ_LOG_LEVEL` configure an
opt-in `:logger` handler (`ForemanServer.Observability.OtelLogBridge`,
parsed once into `config :foreman_server, :signoz_logs` in
`packages/foreman_server/config/config.exs`) that exports
redacted operational logs to SigNoz over OTLP/HTTP. Off by default and
forced off in `config/test.exs`; console logging is unaffected either way.
See `docs/user-guide.md` for the full operator contract and defaults.

### Lint warning

`devbox.json` is in legacy format (the warning at every `devbox run`).
Running `devbox update` rewrites it to the modern `{packages: [{name: ...}]}`
shape; safe but cosmetic. Will be addressed in a follow-up.

### `devbox run -- bash -c '…'` expands `$` in the string, so `echo $?` lies

`devbox run -- <command string>` expands `$VARS` in the string at the devbox layer, before the inner shell runs it (verified 2026-10-19: `devbox run -- bash -c 'false; echo inner=$?'` prints `inner=0`, `rc=$?; echo rc=$rc` prints an empty `rc=`, and escaping as `\$?` does not help). A test run captured like `devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test > log 2>&1; echo exit=$?'` therefore always reports `exit=0`, even when `mix test` failed. The command's REAL exit status does propagate to the caller when the string has no `$`: the canonical `devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors'` exits non-zero on a failing test (devbox then prints "error running script"). When you must redirect or post-process output, check the exit status of the `devbox run` invocation itself, or read the `Result: N passed` line (a failure shows as `Result: 3197/3198 passed`); never trust an `echo $?` written inside the quoted string.

---

### Toolchain pin and environmental workarounds in devbox.json

**Toolchain: Elixir 1.20.4 on Erlang/OTP 28**, pinned natively in
`devbox.json` (`beam28Packages.elixir_1_20@1.20.4` + `erlang_28@latest`,
resolved in `devbox.lock`) and mirrored in `.github/workflows/ci.yml` and
`jido-upstream-upgrade.yml` (`elixir-version: '1.20.4'`, `otp-version: '28'`).
Change all three together. The `mix.exs` floor stays `~> 1.18`; the pin is what
CI and devbox run, not a compatibility claim. Elixir 1.20's type checker is
stricter than 1.18's, and `mix test --warnings-as-errors` (the CI command)
treats its warnings as failures — a toolchain bump is not done until that
command is green under the new pin, so verify with
`devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors'`
rather than whichever `elixir` is first on `PATH` (a Homebrew Elixir 1.20.4 on
OTP 29 is not CI's toolchain).

The agent-container images (`.foreman/Dockerfile`, the `foreman_cli` templates'
`Dockerfile`) are deliberately NOT part of this pin: they are `elixir:1.18-otp-27-slim`
and run the jobsite scripts, which need only OTP 27+. Do not bump them as a side
effect of a devbox/CI toolchain change.

The former interim workaround — a `/nix/store/*-elixir-1.18.4` PATH override
for the broken 1.18.1 devbox-search resolved (`foreman-w4b`) — is deleted;
nothing replaces it.

One `init_hook` line still carries an environmental workaround for
`devbox run test:langfuse`:

1. **`SHELL` export** — `erlexec` (transitive dep) starts an `:exec` port
   driver at app boot that requires `SHELL` in env. Defaulted to
   `/bin/sh` if unset.

A second change: the `init_hook` no longer sources the litellm-langfuse stack's
whole `.env` (that leaked its `ANTHROPIC_API_KEY` into every dev shell and
overrode the operator's own credentials). It exports only `LITELLM_MASTER_KEY`;
`test:langfuse`/`test:all` source the stack `.env` themselves.

---

