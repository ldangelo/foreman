# The Remote Jobsite spec contract

Source of truth: `packages/foreman_server/lib/foreman_server/jobsite/spec.ex`
(`Jobsite.Spec.from_json/2`) and the `Remote Jobsite API` entry in
`docs/lessons/phase-execution-and-pr-mechanics.md`. This file is a derived cheat sheet — when it disagrees with
`spec.ex`, `spec.ex` wins, so re-read those two functions rather than trusting
this page.

## Accepted top-level keys

| Key | Type | Notes |
| --- | --- | --- |
| `project_id` | string, required | a project **registered on the server**, never a filesystem path |
| `prompt` | non-blank string, required | inline text only |
| `agent` | object, required | sub-keys below, nothing else |
| `strategy` | `"head"` \| `{"branch": name}` \| `{"type": "branch", "name": name}` | default is the engine default, not `head` |
| `sandbox` | `"docker"` \| `"host"` | `host` refused unless the server allows host sandboxes |
| `name` | non-empty string | label for the jobsite |
| `max_iterations` | positive integer — `optional_pos_int` requires `is_integer(n) and n > 0`, so `0` is refused, never clamped | the `iterate` loop bound; default `1` |
| `completion_signal` | non-empty string or non-empty list of them | e.g. `<promise>COMPLETE</promise>` |
| `idle_timeout_seconds` | positive integer (`optional_pos_int`, so `0` refused) | agent-stall window |
| `completion_timeout_seconds` | positive integer (`optional_pos_int`, so `0` refused) | grace window after the signal |
| `hooks` | object, `sandbox` target only | see below |
| `exclude_paths` | list of relative paths | must stay inside the project (no `..`) |
| `copy_to_worktree` | list of relative paths | same |
| `resume_session` | string | |
| `push` | boolean | `true` requires a named-branch `strategy` |

## Forbidden keys — each has its own error

`on_event`, `reply_to`, `logging`, `resume?`, `resume`, `repo_path`, `path`, `base`
→ `spec_forbidden_key`.
`prompt_file` → `spec_prompt_file_forbidden`.

Anything not in the table above → `spec_unknown_key`. The whitelist never mints
an atom from caller input, and any non-JSON value (tuple, pid, function, struct)
→ `spec_non_json_value`. **`nil` is JSON `null` and is legal where the key is
optional; but in an `.exs` script leave the key out instead of sending null** —
OTP `:json` encodes `nil` as a string in some call paths, and the validator
rejects the wrong type rather than treating it as absent.

## `agent` object

Exactly these keys: `provider`, `model`, `effort`, `approval_mode`, `env`.

- `provider` — string, one of `JidoHarness.providers()`. **Do not hardcode this
  set:** the source has `@supported_providers [:pi, :claude]`, while AGENTS.md
  names `litellm` as a supported provider. The server rejects anything outside its own
  list and returns the live set in the error `details` — read that rather than
  trusting either doc.
- `model` — non-empty string, required. **Never infer the provider from the
  model name**; set both explicitly.
- `effort` — `minimal` | `low` | `medium` | `high` | `xhigh`.
- `approval_mode` — the spec accepts `default` | `prompt` | `auto_edit` |
  `auto_approve`, but **the provider adapter decides what actually runs**, and
  the accepted set is narrower per adapter (`normalized_values` in
  `packages/jido_harness/lib/jido_harness/adapters/*.ex`):

  | Adapter | accepted `approval_mode` |
  | --- | --- |
  | `pi` | `default`, `auto_approve` (`normalized_values`) |
  | `opencode` | `default`, `prompt`, `auto_approve` (`auto_edit` explicitly refused) |
  | `kimi` | `default` |
  | `claude` | all four (`auto_edit` → `--permission-mode acceptEdits`) |
  | `codex`, `gemini` | declared as `normalized_options` but no `normalized_values` map in the adapter — verify against the adapter source before relying on a mode there |

  A mode the adapter rejects passes `from_json` and then fails the jobsite with
  `agent_start_failed` / "provider does not support normalized option value",
  naming the field and value — verified live. Default to `auto_approve`: a headless
  phase left on `default` cannot write and fails `{:permission_denied,
  [tool_names]}` having produced nothing.
- `env` — map, and **only** when every key is in the server's
  `agent_env_allowlist` (`FOREMAN_JOBSITES_AGENT_ENV_ALLOWLIST`). Values are
  deliberately never persisted on `JobsiteStarted`, so a **resumed jobsite runs
  without them**; `approval_mode` is persisted.

  This is the agent's only credential channel on the docker path: the container
  sees neither your `~/.claude` nor your `~/.pi` auth, so a spec with no `env`
  fails at the first turn with `agent_failed` / "Not logged in" (verified live).
  For docker the keys land in an env-file passed with `docker exec --env-file`
  (`sandboxes/docker.ex:153-163`); a `host` sandbox instead inherits the server
  BEAM's environment, so its agent can be authenticated with no `env` at all.

## `hooks`

`{"sandbox": {"on_worktree_ready": cmd, "on_sandbox_ready": cmd}}` — target must
be `sandbox`, phase must be one of those two. `hooks.host.*` → `spec_hooks_forbidden`,
because `Hooks.run_host/3` is `sh -c` on the server. No exceptions, no "just this once".

## `push`

`push: true` publishes the branch to the remote named `origin` — fixed, never
caller-chosen — after the commit step. It requires `{"branch": name}`; any other
strategy (`head`, the default) has no branch of its own to publish →
`spec_push_requires_branch`. A failed push fails the jobsite with `push_failed`
and keeps the commits local. `push` is persisted on `JobsiteStarted` so a
resumed run does not silently skip it.

## Branch naming

`strategy.branch` must match the worktree branch rules: starts alnum, may contain
`A-Za-z0-9._/-`, and must not end in `.lock`, `/`, or `.`.

## Server-side gates that look like spec errors but aren't

Check these before debugging the spec:

1. 401 with no useful body → no `:api_bearer_token` configured (`RequireAuthenticated` fails closed) or wrong token. This request is **not** audited.
2. Refused start/resume → `allow_remote_start` not `true`. Capped by `max_concurrent_jobsites` (default 3).
3. `spec_env_not_allowed` → key missing from the env allowlist.
4. `spec_sandbox_not_allowed` → `"host"` requested, `allow_host_sandbox` off.
5. `spec_project_not_found` / `spec_project_unavailable` → not registered / archived. Register with `foreman project create`; the worktree's git dir must be resolvable on the server.
6. Git fails *inside* the container → the sandbox did not get the repo's git dir bind-mounted (fixed by the worktree git-dir mount). See `foreman-jobsite-debug` if that's where you ended up.

## What the Docker sandbox sees

The worktree is bind-mounted rw, and for a linked worktree the repo's whole git
dir is mounted rw at the same host path with `safe.directory` set for exactly
those two paths — so the agent can rewrite any ref in that repo. An
unresolvable git dir fails sandbox creation as `sandbox_create_failed` rather
than mounting nothing.

## Parallelism is a script concern

Fan-out ("decompose into N jobsites, merge results") lives in the `.exs` script:
start N specs, poll, merge. It cannot be expressed in one spec, because the
event/reply plumbing (`on_event`, `reply_to`) is forbidden on the remote path by
design. See `templates/parallel.exs`.

`Jobsite.merge_into/2` merges a completed jobsite's branch **only into the branch
currently checked out in the server's copy of the repo**, and names the result:
`{:ok, %{jobsite_id:, branch:, merged_into:}}`. A mismatch is a 409, never a silent
target switch. The target is therefore server state the spec does not control, so
`templates/parallel.exs` reads it from `FOREMAN_MERGE_INTO` and raises when unset —
defaulting it to `main` would merge a fan-out into whatever branch the server
happened to be sitting on.

The bundled `parallel` template at
`packages/foreman_cli/cmd/foreman/templates/parallel/parallel.exs` is the same
shape and reads the same `FOREMAN_MERGE_INTO` name.
