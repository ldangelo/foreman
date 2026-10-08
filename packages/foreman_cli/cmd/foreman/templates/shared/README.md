# Foreman Jobsite scripts

This directory was scaffolded by `foreman init --template <name>`. Each
`.foreman/<name>.exs` file is a complete, runnable Jobsite script. There are
two kinds, and the script's header says which it is.

## Client scripts: `basic`, `iterate`, `parallel`

These drive a **running `foreman_server`** over HTTP through
`foreman_client.exs` (a single file with no dependencies beyond Erlang/OTP 27+).
They run with plain Elixir: no Foreman checkout, no database, no `mix`.

```bash
export FOREMAN_API_TOKEN=...           # the server's bearer token
export FOREMAN_PROJECT_ID=my-project   # a project registered on the server
elixir .foreman/<name>.exs             # FOREMAN_API_URL defaults to http://127.0.0.1:4766
```

The agent runs on the **server**, in the server's checkout of the registered
project; the script only sends a spec and waits, so anything the script does
itself (calling Jira or `gh`, deciding how many jobsites to start) runs on your
machine. The server never runs code from the script, and it must enable remote
start (`config :foreman_server, :jobsites, allow_remote_start: true`). The
`host` sandbox is refused unless the server also sets `allow_host_sandbox: true`;
the default is `docker`.

## Foreman-checkout scripts: `review`, `triage`

These drive a live sandbox step by step, which the HTTP API does not expose, so
they call `ForemanServer.Jobsite` directly and must run inside a booted
`foreman_server` application (not a bare `elixir` script and not
`mix run --no-start`) with Postgres up (`devbox run up`):

```bash
cd packages/foreman_server && mix run ../../.foreman/<name>.exs
```

Each such script resolves its own `repo_path` from `__DIR__` (this directory),
so it targets the repo containing `.foreman/`, not the Foreman checkout's own
working directory.

## Layout

- `<name>.exs` — the script.
- `foreman_client.exs` — the HTTP client the client scripts load (unused by
  `review` and `triage`).
- `prompts/` — prompt files the scripts read. Client scripts send the prompt as
  text, so any `{{PLACEHOLDER}}` is filled in by the script itself.
- `Dockerfile` — optional sandbox image for the `docker` sandbox, built on the
  machine that runs the server:
  `docker build --build-arg AGENT_UID=$(id -u) --build-arg AGENT_GID=$(id -g) -t foreman-jobsite:<name> .foreman`.
- `logs/`, `state/`, `worktrees/`, `runs/` — reserved, gitignored working
  directories Jobsite writes into at run time. `runs/` in particular is
  reserved for future per-run artifact output; do not create files there by
  hand.
