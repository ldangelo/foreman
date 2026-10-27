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

### CI layout (`.github/workflows/ci.yml`)

`main` requires three status checks, matched by job NAME (non-strict, app github-actions):
`foreman_server`, `jido_harness`, `foreman_cli`. Each name must be reported by exactly one job
that is green only when its work was, on every run, or auto-merge waits forever. Read the check
list like this:

| Check run | Role |
| --- | --- |
| `changes` | classifies the change set (`scripts/ci/changed-code.sh`); not required |
| `foreman_server_p1` … `foreman_server_p4` | the four test partitions; not required, never the name to put in branch protection |
| `foreman_server` | **required**. Aggregate job: `needs:` every partition, `if: always()`. Fails when any partition failed or was cancelled; passes when all four passed, or when the change set was docs-only and the partitions were skipped on purpose |
| `jido_harness`, `foreman_cli` | **required**, names unchanged; reported `skipped` for a docs-only change set |

A required check that is skipped by a job-level `if` counts as passing. A workflow-level
`paths:`/`paths-ignore:` filter would leave the required checks pending forever, so it is never
used for this workflow.

**Partitions.** Each leg runs `mix test --partitions 4` with `MIX_TEST_PARTITION=n`. Mix sorts the
test files and deals them round-robin by index (index mod 4), not by hash and not by duration, so a
new file moves the files after it into another leg. Every leg has its own runner AND its own
Postgres container, which is why `config/test.exs` needs no per-partition database name and
`reset_event_store/1` empties the right event store. To reproduce leg `n` locally give it a
private database (`createdb`, then `ecto.migrate` and `event_store.init`) and run
`MIX_TEST_PARTITION=n DATABASE_URL=... mix test --partitions 4 --seed <seed in the leg's log>`; a
leg that fails only when partitioned has found a hidden dependency between test files, which is a
bug in the tests, never a reason to reshuffle the split. `format`, `credo` and `doctor` run in
leg 1 only.

**Docs-only change sets** skip the partitions, `jido_harness` and `foreman_cli` (job-level `if`
on the `changes` output). `scripts/ci/changed-code.sh` decides from an explicit allowlist of trees
no test or build step reads (`.beads/`, `.coderabbit.yaml`, most of `docs/`, `scripts/e2e/`); any
other path, an empty diff or a diff it cannot compute means "run everything". The suites DO read
`README.md`, `CLAUDE.md`, `docs/user-guide.md`, `docs/cli-reference.md`, `docs/ADT/`,
`docs/spikes/` and `ops/otel-collector/`, so those count as code. A test that starts reading a file
under an allowlisted tree must take that tree off the list (the script's header says how it was
checked; `scripts/ci/changed-code.sh --self-test` runs in every `changes` job).

**Caches.** The key starts with the resolved OS image, OTP and Elixir versions (outputs of
`erlef/setup-beam`) followed by the hash of `mix.lock`; `restore-keys` is the same prefix without
the hash, so an entry built by another toolchain can neither hit nor be restored. (The key used to
be the `mix.lock` hash alone: an entry made before the 10-14 toolchain pin hit on every run and 98
deps were recompiled each time for nine days.) `jido_harness` caches `deps/`, `_build` and its
dialyzer PLTs (the core and Elixir PLTs live in `~/.mix`, the project PLT in `_build/dev`; dialyxir
re-checks a restored PLT against the current deps) under an exact key with no `restore-keys`: an
older `deps/` restored over a checkout whose vendored deps moved on would clobber them. `deps/` is
vendored in git but its build outputs are not (erlexec's `exec-port`, rebar `_build`s), so a
restored `_build` without `deps/` cannot start erlexec. One more file is missing from a checkout:
`.gitignore` keeps `packages/*/deps/**/.credo.exs` out of git on purpose (credo's own config would
be taken for a project root), yet credo cannot compile without it, so the job drops `deps/credo`
before `mix deps.get` and Hex supplies it.

**Concurrency.** A newer push to a PR cancels the older run of that PR. Runs on `main` are keyed by
SHA, so they are never cancelled and never wait behind each other.

**Slow tests.** Every leg ends its log with `SlowestReport` (the slowest 30 tests and 15
`async: false` modules). It is a formatter, not `mix test --slowest`: `--slowest` implies
`--trace`, which runs every module one at a time and switches test timeouts off, so it measures a
different run than the one CI executes. Use it the same way locally:
`mix test --formatter ForemanServer.TestSupport.SlowestReport`.

**Coverage** is not collected by default (`mix test --cover` still works). Measured on the same
files and seed, ExCoveralls made a partition's test step 69-84% slower (92-98 s to 161-180 s) and
nothing reads its table: there is no threshold and no `coveralls.json`.

**Measured effect** (PR runs of #681; the "before" is the median of 93 runs in 10-23..10-26,
`foreman_server` job 11.1 min, p90 16.7): a fully warm run takes about 2.3 minutes from push to the
last required check (changes 7 s, partitions 87-120 s each, aggregate 4 s); `jido_harness` `mix
quality` drops from 132-190 s to 9 s with the PLT cache. A cold-cache run is about 10 minutes (the
98 deps compile once) and happens on a new toolchain or `mix.lock`. Test work per partition is
60-90 s (was 525-650 s for the single job, of which ExCoveralls was ~40%); no test waits 5 s or more
any more (the slowest is about 2 s).

**Two things that were tried for balance and did not pay (foreman-iyikt, 10-27).** Round-robin
leaves the legs uneven on average (test step 53/73/67/91 s on one run, partition 4 slowest in
three of four warm main runs), but a single run's spread is mostly runner noise: the same
commit, same split, five runs, gave per-leg test steps of 64-97 s. (1) A size-weighted split
(greedy by per-file test time, measured on the CI legs; predicted legs equal within 0.1%, round-robin
would have been 51/53/68/61 s of test time) gave job maxima of 134-150 s over five runs against
136-145 s for round-robin over four: no gain that the noise does not hide, so it was not kept
(`mix test --partitions 4` stays). (2) Sharing one parsed copy of `lib/` between the
source-scanning architecture tests (`:persistent_term` behind a `:global` lock) made those tests
*slower* (1-1.5 s became 5-9 s: the lock serialises the first parse and every other test waits
for it on a 4-vCPU runner) and left the async phase at ~11 s per leg. The scanners are CPU
work on the async phase, not on the critical path: the legs are bound by the `async: false`
modules (55-85 s of the 65-90 s test step), so only a cut in those modules (real executor,
worktrees, Postgres) moves the wall time. What is left there is on purpose: `ResumeTest`,
`RunExecutorTest` and the multi-repo modules drive a real executor, real git worktrees and
Postgres (0.5-1 s per test, no cheaper honest setup found); `BeadsDbLeaseCallerDeathTest` has a 2 s
window in which something must NOT happen and `RunExecutorTest`'s 1.1 s is a retry backoff.

**A timed-out `br` kills its whole process tree.** `SystemBrRunner` snapshots the tree below the
port's OS pid (`pgrep -P`, recursively) before the first signal, sends SIGTERM to all of it, waits,
then SIGKILLs what is left. Signalling only the pid the port started left the children of a `br`
wrapper script (one that forks instead of `exec`ing) running, and holding the port's stdout pipe
open for the 5 s kill grace. There is no process group to signal instead: erlang's port spawn
gives the child none and macOS has no `setsid` (the same limit as `Jobsite.Git`); a child forked
after the snapshot can survive.

### erlexec is patched in-repo (process-group startup race, macOS)

Symptom: a process started through `Jido.Harness.Process` ends `:failed` with exit status 1 and stderr
`Cannot set effective group to 0: Operation not permitted`; in the suite it shows up as a rare
`ProcessManagerTest` / `DirectCLIAdapterTest` failure, in production as an agent CLI that never starts.

Cause: hex `erlexec` 2.3.4 has the parent and the child both call `setpgid()` after `fork()` and the child treats any
failure as fatal. The harness always spawns with `{:group, 0}` (`jido_harness/lib/jido_harness/process/driver/erlexec.ex`).
Observed once on macOS and not re-measured afterwards (the unpatched build showed 0 failures in ~24k spawns, also under
load). Not observed on Linux and not tested there, so CI does not exercise it.

Fix: `packages/jido_harness/patches/erlexec/process-group-startup.patch`, a hand port of upstream
`agentjido/jido_harness` `e109aa5`. The parent assigns the group, then closes the write end of a pipe; the child blocks on
`read` until EOF (EOF means "released", never write a byte), then calls `setpgid()` and accepts an already-established group.

Mechanics, because the dep is a hex copy and easy to revert silently:

- `packages/jido_harness/deps/erlexec` is tracked and committed already patched, but do not rely on that:
  CI restores `packages/jido_harness/deps` from a `mix.lock`-keyed cache that can bring back a pristine copy
  (the job logged `* patched erlexec`). `packages/foreman_server/deps` is gitignored and fetched from hex.
- `scripts/patch_erlexec.exs` (loaded from both `mix.exs`) applies the patch from the `deps.get`, `deps.loadpaths` and
  `deps.compile` aliases. It dry-runs first, recognises a patched file by two strings, deletes `_build/*/lib/erlexec` plus
  the dep's `*.o`, `*.d` and `exec-port` so the port is rebuilt, and raises if the patch cannot be applied.
- Mix does not track a hex dep's sources: after hand-editing `exec_impl.cpp` run `mix deps.compile erlexec --force`.
  Check the built port with `strings deps/erlexec/priv/*/exec-port | grep 'Process group startup'`.
- A new `erlexec` version means a new base file: re-port the patch or drop it once `saleyn/erlexec` carries the fix.

---
