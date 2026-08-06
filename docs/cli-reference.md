# CLI reference

This slice ships `foreman`, a thin Go CLI around the Elixir/Phoenix
HTTP boundary. The CLI is **not** an alternate write path to the
event store. Task mutations (`task create`, `task approve`) route
through the server's `CommandRouter`; asset materialisation
(`workflow install`) is an admin endpoint that writes files on
disk and is observed by `Workflow.Catalog` on its next poll tick
or via `Catalog.reload/0`.

## Environment

| Variable | Default | Description |
|---|---|---|
| `FOREMAN_API_URL` | `http://127.0.0.1:4000` | Base URL of the Phoenix API. |
| `FOREMAN_API_TOKEN` | _unset_ | Optional Bearer credential. When unset the server bypasses auth (dev only). |

The CLI exposes no global flags; command-specific flags are listed
below. Run `foreman <command> -h` for per-command usage.

## Commands

### `foreman task create`

Register a new task. Issues `POST /api/commands` with
`type=task.create`.

### `foreman task approve`

Approve a task and bind it to a workflow. Issues
`POST /api/commands` with `type=task.approve`.

### `foreman task get <id>`

Fetch a task projection. Issues `GET /api/tasks/:id`.

### `foreman run get <id>`

Fetch a run projection. Issues `GET /api/runs/:id`.

### `foreman workflow install`

The CLI resolves the flag values to absolute paths via
`filepath.Abs` and POSTs them to the server in a JSON body. The
server's `WorkflowInstallController` forwards them to
`ForemanServer.WorkflowTemplate.Installer`, which performs all
file I/O via `File.cp/2` and `File.write/2`. The CLI never writes
to disk itself — `--target` and `--source` must therefore be paths
**on the server host**, not on the operator's local machine.

The catalog observes the install only when `--target` is the
catalog's configured root (hardcoded to `~/.foreman/workflows` by
`AssetCatalog.default/0`); installs to other paths are written to
disk but never picked up by the catalog. A successful install is
visible to consumers on the next catalog poll tick (default 2 s)
or immediately after `ForemanServer.Workflow.Catalog.reload/0`.

| Flag | Description |
|---|---|
| `--target PATH` | **Required.** Absolute path on the **server** (resolved via `filepath.Abs` in the CLI; `File.cp/2`/`File.write/2` in `WorkflowTemplate.Installer`). Must equal the catalog's configured root (`~/.foreman/workflows` by default) for the catalog to observe the install. |
| `--source PATH` | Absolute path on the server of the source `*.yaml` and `prompts/*.md` directory. |
| `--remote URL` | Remote URL of a workflow bundle. |
| `--retries N` | Retry attempts for remote installs (default `3`). |
| `--retry-delay-ms MS` | Delay between retries (default `250`). |

At least one of `--source` or `--remote` is required; both may be
set in the same invocation. The installer uses `File.cp/2` and
`File.write/2`; if the target already contains a same-named file,
it will be overwritten. Place custom templates under their own
filenames.

Example:

```
foreman workflow install \
  --target ~/.foreman/workflows \
  --source ./bundled-templates
```

The auto-install performed by `Workflow.Catalog.init/1` at boot is
a **no-op** when this command (or any other process) has already
materialised at least one `*.yaml` manifest under the target — see
`docs/user-guide.md` §7 for the exact condition.