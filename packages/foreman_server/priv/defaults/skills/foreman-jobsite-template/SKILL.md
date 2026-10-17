---
name: foreman-jobsite-template
description: "Generate a Foreman Jobsite .exs runner script and companion prompt .md from a natural-language description. Use when asked to create, scaffold, or author a Jobsite spec or template."
---

# Foreman Jobsite Template Generator

## When to Use

Invoke when asked to generate, scaffold, or author a Foreman Jobsite script from a natural-language description.  This skill translates the description into:

1. A `.exs` runner script (using `foreman_client` with `Mix.install`) that POST /api/jobsites will accept.
2. A companion `.md` prompt file that the server sends as `prompt` to the agent.

Output target: `.foreman/<name>.exs` and `.foreman/prompts/<name>.md`.

---

## Spec Contract — `Jobsite.Spec.from_json/2` Whitelist

### Allowed top-level keys (only these may appear in the spec map)

| Key | Type | Notes |
|-----|------|-------|
| `project_id` | string | **Required.** Read from `FOREMAN_PROJECT_ID`. |
| `prompt` | string | **Required.** Inline text only — load from `File.read!/1`. |
| `agent` | map | **Required.** See agent sub-keys below. |
| `strategy` | string or map | Recommended: `%{"branch" => name}`. |
| `sandbox` | string | `"docker"` (default) or `"host"` (server must opt in). |
| `name` | string | 1–128 chars of `[A-Za-z0-9._-]`. |
| `max_iterations` | integer | **Positive** — the server refuses `0` (`optional_pos_int` in `spec.ex`). Optional; default `1`. Independent of `completion_signal`. |
| `completion_signal` | string or list | Non-empty string, or non-empty list of them. Optional. Nothing requires an iteration count. |
| `idle_timeout_seconds` | integer | **Positive** — same `optional_pos_int` guard refuses `0`. Optional. |
| `completion_timeout_seconds` | integer | **Positive** — same `optional_pos_int` guard refuses `0`. Optional. |
| `resume_session` | string | Non-empty. Optional. |
| `push` | boolean | `true` **requires** `strategy: %{"branch" => name}`. |
| `exclude_paths` | list | Relative paths only — no `..` segments. |
| `copy_to_worktree` | list | Relative paths only — no `..` segments. |
| `hooks` | map | Only `sandbox` target accepted (NOT `host`). Phases: `on_worktree_ready`, `on_sandbox_ready`. Each entry: `%{"command" => string}`. |

### Agent sub-keys

| Key | Type | Notes |
|-----|------|-------|
| `provider` | string | **Required.** One of `JidoHarness.providers()` — currently `"pi"` or `"claude"`. A LiteLLM proxy is reached *through* `pi`, not as its own provider. |
| `model` | string | **Required.** Non-empty model name. |
| `effort` | string | Optional. One of: `"minimal"`, `"low"`, `"medium"`, `"high"`, `"xhigh"`. |
| `approval_mode` | string | Optional. One of: `"auto_edit"`, `"auto_approve"`, `"default"`. |
| `env` | map | Optional. String→string. Every key must be in the server's `agent_env_allowlist`. Values are NOT persisted to events — a resumed jobsite runs without them. |

### Forbidden keys — always rejected

NEVER include any of these in the spec map:
`on_event`, `reply_to`, `logging`, `resume?`, `resume`, `repo_path`, `path`, `base`, `prompt_file`

### Security constraints (non-negotiable)

- `hooks.host.*` is **FORBIDDEN** (`:spec_hooks_forbidden`). Only `hooks.sandbox.*` is accepted.
- `prompt_file` is **FORBIDDEN** (`:spec_prompt_file_forbidden`). Inline `prompt` only.
- `agent.env` values are never persisted to events (clear-text protection); a resumed jobsite runs without them.
- `sandbox: "host"` requires `config :foreman_server, :jobsites, allow_host_sandbox: true` on the server. Default to `"docker"` unless explicitly requested.
- `push: true` requires `strategy: %{"branch" => name}` — not `"head"`. Violating this yields `:spec_push_requires_branch`.
- Branch names must match `~r/\A[A-Za-z0-9][A-Za-z0-9._\/-]*\z/` and must not contain `..`, end with `.lock`, `/`, or `.`.

---

## Template Style Selection

Choose the template style based on the description:

### basic — single-shot
- **When:** Task is bounded and achievable in one agent pass.
- **approval_mode:** `"auto_edit"` (agent edits; human reviews diff).
- **sandbox:** `"docker"` (default); `"host"` only if explicitly required and server allows it.
- **No** `max_iterations` or `completion_signal`.

### iterate — loop until done
- **When:** Task requires multiple agent turns (e.g., draining a backlog, refining output).
- **approval_mode:** `"auto_approve"` (unattended; agent acts freely).
- **sandbox:** `"docker"` (required for unattended looping).
- **Must set** `max_iterations` (default 20; caller adjusts) and `completion_signal`.
- Default completion signal: `"<promise>COMPLETE</promise>"`.
- Default model: `"claude-opus-4-8"` (more capable for multi-turn).

### parallel — fan-out across N independent items, sequential merge
- **When:** Same prompt template applies to N independent items concurrently.
- One `Foreman.Client.run/3` call per item via `Task.async_stream/3`.
- Merges are **sequential** — the server refuses concurrent merges into the same checked-out branch.
- Requires `FOREMAN_MERGE_INTO` for the target branch.

---

## Runner Script Pattern

Every generated runner follows this structure:

```elixir
# .foreman/<name>.exs — <one-line description>
#
# Run with plain Elixir (OTP 27+); no Foreman checkout, no database:
#
#   export FOREMAN_API_TOKEN=...            # the server's bearer token
#   export FOREMAN_PROJECT_ID=my-project    # a project registered on the server
#   elixir .foreman/<name>.exs
#
# FOREMAN_API_URL defaults to http://127.0.0.1:4766.
<# Any additional env vars the script reads, documented here. #>

# Pin `ref: "<tag or sha>"` here to stop following the default branch.
Mix.install([{:foreman_client, github: "ldangelo/foreman", sparse: "packages/foreman_client"}])

project_id = System.get_env("FOREMAN_PROJECT_ID") || raise "FOREMAN_PROJECT_ID is not set"
client = Foreman.Client.new()

spec = %{
  "project_id" => project_id,
  # ... only whitelisted keys here ...
}

case Foreman.Client.run(client, spec) do
  {:ok, jobsite} ->
    IO.puts("branch=#{jobsite["branch"]} status=#{jobsite["status"]}")

  {:error, reason} ->
    IO.puts(:stderr, "jobsite did not complete: #{inspect(reason)}")
    System.halt(1)
end
```

### Basic style spec block

```elixir
spec = %{
  "project_id" => project_id,
  "strategy" => %{"branch" => "agent/<name>"},
  "sandbox" => "docker",
  "agent" => %{"provider" => "claude", "model" => "claude-sonnet-4-6", "approval_mode" => "auto_edit"},
  "prompt" => File.read!(Path.join(__DIR__, "prompts/<name>.md"))
}
```

### Iterate style spec block

```elixir
max_iterations =
  case Integer.parse(System.get_env("FOREMAN_MAX_ITERATIONS", "20")) do
    {n, ""} when n > 0 -> n
    _ -> raise "FOREMAN_MAX_ITERATIONS must be a positive integer"
  end

spec = %{
  "project_id" => project_id,
  "strategy" => %{"branch" => "agent/<name>"},
  "sandbox" => "docker",
  "agent" => %{"provider" => "claude", "model" => "claude-opus-4-8", "approval_mode" => "auto_approve"},
  "prompt" => File.read!(Path.join(__DIR__, "prompts/<name>.md")),
  "max_iterations" => max_iterations,
  "completion_signal" => "<promise>COMPLETE</promise>"
}
```

Success output for iterate:
```elixir
{:ok, jobsite} ->
  IO.puts(
    "branch=#{jobsite["branch"]} iterations=#{length(jobsite["iterations"] || [])} status=#{jobsite["status"]}"
  )
```

### Parallel style spec + fan-out

```elixir
tasks = ["task-a", "task-b", "task-c"]  # replace with actual items
into  = System.get_env("FOREMAN_MERGE_INTO") || raise "FOREMAN_MERGE_INTO is not set"
template = File.read!(Path.join(__DIR__, "prompts/<name>.md"))

results =
  tasks
  |> Task.async_stream(
    fn task ->
      spec = %{
        "project_id" => project_id,
        "strategy" => %{"branch" => "agent/#{task}"},
        "sandbox" => "docker",
        "agent" => %{"provider" => "claude", "model" => "claude-sonnet-4-6", "approval_mode" => "auto_approve"},
        "prompt" => String.replace(template, "{{TASK}}", task)
      }
      {task, Foreman.Client.run(client, spec)}
    end,
    max_concurrency: 3,
    timeout: :infinity
  )
  |> Enum.map(fn {:ok, pair} -> pair end)

for {task, outcome} <- results do
  case outcome do
    {:ok, jobsite} ->
      case Foreman.Client.merge(client, jobsite["jobsite_id"], into) do
        {:ok, _}                                    -> IO.puts("merged #{task}")
        {:error, {409, %{"error" => "merge_conflict"}}} -> IO.puts("CONFLICT #{task}: manual merge required")
        {:error, reason}                            -> IO.puts("MERGE FAILED #{task}: #{inspect(reason)}")
      end
    {:error, reason} ->
      IO.puts("FAILED #{task}: #{inspect(reason)}")
  end
end
```

---

## Prompt File Pattern

The companion `.md` is the literal text the server sends as `prompt` to the agent. Write it to convey:

- The concrete objective (what to achieve, not how to achieve it).
- The completion condition (for iterate style: exactly what the agent should emit when done).
- Any tool, skill, or command references the agent has access to in the sandbox.

For iterate style, always end the prompt with the completion instruction:

```markdown
When — and only when — all work is complete and verified, end your final message with exactly:

    <promise>COMPLETE</promise>

Do not emit that tag early; Jobsite stops iterating the moment it appears.
```

---

## Verification Checklist

Before emitting the final `.exs` file, verify each item:

- [ ] No forbidden keys: `on_event`, `reply_to`, `logging`, `resume?`, `resume`, `repo_path`, `path`, `base`, `prompt_file`
- [ ] No `hooks.host.*` entries — only `hooks.sandbox.*`
- [ ] `agent.provider` is in `JidoHarness.providers()` (currently `"pi"` or `"claude"`) — never
      a hardcoded copy of that list in the script; the server's rejection `details` carries the live set
- [ ] `agent.model` is a non-empty string
- [ ] `prompt` is loaded via `File.read!/1`, never a hardcoded multi-line string in the spec map
- [ ] If `push: true`, strategy is `%{"branch" => name}` (not `"head"`)
- [ ] `max_iterations`, `idle_timeout_seconds` and `completion_timeout_seconds`, if set, are
      **positive** integers — all three go through the one `optional_pos_int` guard, so `0` is
      refused as `spec_option_invalid`, never clamped. `max_iterations` is independent of
      `completion_signal`; neither requires the other.
- [ ] Iteration progress is read from `jobsite["iterations"]` (a list of per-iteration records)
      and `jobsite["iteration_index"]` — never `iteration_count` / `iteration_results`, which do
      not exist on the read model and print as `nil`
- [ ] If `agent.env` is set, add a comment that keys must appear in the server's `agent_env_allowlist`
- [ ] Branch name matches `~r/\A[A-Za-z0-9][A-Za-z0-9._\/-]*\z/` — no `..`, no trailing `.lock`, `/`, or `.`
- [ ] `sandbox` is `"docker"` unless `"host"` is explicitly required and documented in the header comment
- [ ] `approval_mode` is `"auto_edit"` for interactive/review tasks, `"auto_approve"` for unattended iterate/parallel

---

## Quick Reference — `Foreman.Client` API

```elixir
client = Foreman.Client.new()
# Reads FOREMAN_API_TOKEN and FOREMAN_API_URL from env.

# Start + poll to completion (blocking):
{:ok, jobsite} | {:error, reason} = Foreman.Client.run(client, spec)

# Lower-level:
{:ok, %{"jobsite_id" => id}} = Foreman.Client.start(client, spec)
{:ok, jobsite}               = Foreman.Client.get(client, id)
{:ok, _}                     = Foreman.Client.merge(client, id, into_branch)
{:ok, _}                     = Foreman.Client.cancel(client, id, "reason")
{:ok, _}                     = Foreman.Client.pause(client, id, "reason")
```

---

## Example: Iterate Jobsite for an Issue Backlog

User prompt: *"Process all GitHub issues labeled 'auto-fix' using ensemble skills, one per turn, committing each fix."*

**`.foreman/auto-fix.exs`** (iterate style):

```elixir
# .foreman/auto-fix.exs — drain issues labeled auto-fix, one per agent turn.
#
#   export FOREMAN_API_TOKEN=...
#   export FOREMAN_PROJECT_ID=my-project
#   export FOREMAN_MAX_ITERATIONS=30   # at least as many issues as expected
#   elixir .foreman/auto-fix.exs
#
# FOREMAN_API_URL defaults to http://127.0.0.1:4766.

Mix.install([{:foreman_client, github: "ldangelo/foreman", sparse: "packages/foreman_client"}])

project_id = System.get_env("FOREMAN_PROJECT_ID") || raise "FOREMAN_PROJECT_ID is not set"
client = Foreman.Client.new()

max_iterations =
  case Integer.parse(System.get_env("FOREMAN_MAX_ITERATIONS", "30")) do
    {n, ""} when n > 0 -> n
    _ -> raise "FOREMAN_MAX_ITERATIONS must be a positive integer"
  end

spec = %{
  "project_id" => project_id,
  "strategy" => %{"branch" => "agent/auto-fix"},
  "sandbox" => "docker",
  "agent" => %{"provider" => "claude", "model" => "claude-opus-4-8", "approval_mode" => "auto_approve"},
  "prompt" => File.read!(Path.join(__DIR__, "prompts/auto-fix.md")),
  "max_iterations" => max_iterations,
  "completion_signal" => "<promise>COMPLETE</promise>"
}

case Foreman.Client.run(client, spec) do
  {:ok, jobsite} ->
    IO.puts(
      "branch=#{jobsite["branch"]} iterations=#{length(jobsite["iterations"] || [])} status=#{jobsite["status"]}"
    )

  {:error, reason} ->
    IO.puts(:stderr, "jobsite did not complete: #{inspect(reason)}")
    System.halt(1)
end
```

**`.foreman/prompts/auto-fix.md`**:

```markdown
Work through all GitHub issues labeled 'auto-fix' in this repository, in
dependency order, one issue per turn.

Each turn:
1. Find the next actionable 'auto-fix' issue using the available tools.
2. Implement the fix using the ensemble skills installed in this sandbox.
3. Run the project tests. Only when tests pass, commit the change.
4. If no more 'auto-fix' issues are actionable, go to Completion.

Completion: end your final message with exactly:

    <promise>COMPLETE</promise>

Do not emit that tag early; Jobsite stops iterating the moment it appears.
Set FOREMAN_MAX_ITERATIONS to at least the number of issues expected.
```
