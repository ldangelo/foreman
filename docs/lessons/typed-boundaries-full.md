# Typed boundaries, loud failures — full rules with post-mortems

> Archived verbatim from the former monolithic `AGENTS.md` (2026-10-18) to keep the always-loaded agent context small. Full text of `AGENTS.md` §5.1–5.7 (core rules are summarised there).
> Section-number references inside (e.g. "section 4", "§5.4") point at the pre-split `AGENTS.md`; the §5 rules are summarised in `AGENTS.md` and full text is in `typed-boundaries-full.md`.

## 5. Typed Boundaries, Loud Failures

**Make the compiler catch it. If it can't, fail loudly. Never degrade to a plausible-looking success.**

Six stacked MCP defects shipped undetected because every one of them failed
quietly — a permissive catch-all turned each into either a successful-looking
response or a misleading "unknown tool". These rules exist to prevent that
class, not just that instance.

### 5.1 Typed returns — no bare maps as result or error payloads

A function's failure payload MUST be a struct with `@enforce_keys` and
`@type t`, never an anonymous map:

```elixir
# WRONG — a typo'd or renamed key silently stops matching downstream.
{:error, %{code: "NOT_FOUND", message: "Run not found"}}

# RIGHT
{:error, %ToolError{code: "NOT_FOUND", message: "Run not found"}}
```

Maps stay legitimate for genuinely open nested data (event payloads, config
blobs, `phase_status`). They are not acceptable as the contract itself. This is
the same rule already enforced for aggregate state (see **Aggregate State
Design**) and domain events (see **Typed Event Structs**) — it applies to every
internal API boundary.

### 5.2 Result handling MUST be total, with no permissive fallback

Match exactly the documented return shapes and nothing else. A catch-all that
wraps an unrecognized value into a success response is prohibited:

```elixir
# WRONG — an unmatched error is reported to the caller as a SUCCESS.
defp wrap(other, frame) do
  {:reply, %Response{content: [text(inspect(other))], isError: false}, frame}
end

# RIGHT — total over the contract; anything else raises FunctionClauseError.
defp wrap({:ok, data}, frame), do: {:reply, ..., frame}
defp wrap({:error, %ToolError{} = e}, frame), do: {:error, ..., frame}
```

A crash beats a lie. `rescue`/`catch` around a call you do not understand, or
an `_ -> :ok` fallback, converts a defect into corrupt state.

### 5.3 Distinguish "absent" from "malformed"

One catch-all serving both is a debugging tax. Give each cause its own code:

| Cause | Response |
| --- | --- |
| Unknown name / id | `METHOD_NOT_FOUND` / `NOT_FOUND` |
| Known name, missing required argument | `INVALID_PARAMS`, naming the argument |
| Known name, wrong key type (caller bypassed the boundary) | **raise** — programming error |

`foreman_queue_status` was advertised for its entire life with no
implementation, and every call returned `METHOD_NOT_FOUND — Unknown tool`,
indistinguishable from a client typo.

**Update 2026-09-01: `InboxThread` is now implemented.** Per `foreman-q5bm`:

- `CommandRouter.aggregate_module_for/1` has `"inbox:"` clause → routes to InboxThread
- Event structs `InboxMessageAppended` / `InboxDeliveryUpdated` under `lib/foreman_server/events/`
- `ProjectionStore` handles both events; exposes `inbox_thread/1` and `list_inbox_threads/0`
- MCP tools `foreman_inbox_get`, write-gated `foreman_inbox_send`, and write-gated `foreman_task_add_comment` exist; `foreman_inbox_send` dispatches public operator `inbox.send` through `CommandGateway`, while `foreman_task_add_comment` calls `TaskProvider.comment/3` directly via the adapter registry and does not route through `CommandGateway` or the `Task` aggregate.

The per-run operator inbox is functional. Public run-progress writes use MCP `foreman_inbox_send` only when `allow_workflow_writes: true`; trusted OTP automation may still use `dispatch_system` for internal `inbox.send` / `inbox.delivery.update`.

`task.block` was in the same class: a handler existed in `task.ex` gated behind
`require_blockable/1` which no operator path triggered; `CrashLoopDetector`
was the sole caller via `dispatch_system`, and `TaskBlocked` had no
`ProjectionStore` handler so the blocked state was invisible to the read model.
`OperatorTimeout` also dispatched it on operator timeout expiry. All four
(`require_blockable/1`, the `task.block` handler, `TaskBlocked` event, and the
`OperatorTimeout` dispatch) have been deleted. `blocked_reason` aggregate field
was written but never read; removed from the `State` struct. PR #432.

### 5.4 Typed parameters — one key convention, normalized once

Pick one key convention per boundary (atoms internally), convert at the single
entry point, and never pattern-match both:

```elixir
# WRONG — invites permanent drift; one of the two clauses is always dead.
backend = Map.get(args, :backend) || Map.get(args, "backend")

# RIGHT — the transport normalized schema-declared keys already.
backend = Map.get(args, :backend)
```

Only convert keys the schema declares, so caller input can never mint atoms.
A string key arriving past that boundary is a programming error: raise.

### 5.4b Normalize parameters — whitelist known keys, drop unknowns

Every caller-facing function that accepts a map parameter MUST normalize its
input at the entry point before delegating downstream:

1. **Declare the whitelist** of accepted keys (atoms, internally).
2. **Fold only whitelisted keys** into the canonical output map.
3. **Never insert `nil`** for an absent key — callers that pattern-match
   `%{key: "present"}` will crash when `nil` arrives; callers that use
   `|| fallback` misbehave because `nil || fallback` returns `fallback`
   but `false || fallback` also returns `fallback` (lost signal).

```elixir
# WRONG — caller can pass any key; nil-literal keys silently drift.
def handle(%{key: value}) when is_binary(value), do: ...
def handle(%{key: nil}), do: ...

# RIGHT — whitelist known keys at the boundary.
@known_keys [:key, "key"]
def normalize(raw) do
  Enum.reduce(@known_keys, %{}, &put_field(&1, raw, &2))
end
```

The rule is sound; the example originally attached to it was not. It claimed a
"YAML-driven `:clean_worktree` key was silently dropped because it wasn't in the
normalization whitelist". `clean_worktree` is not a YAML key and never was — it
is the `VcsAdapter` operation name for removing a worktree — and the whitelist
entry added for it normalized a key no module read.

The real defect of this class, in the same change, was the reverse: the manifest
key `cleanup:` stayed in the whitelist and kept normalizing correctly, while its
only consumer (`worktree_cleanup/1`) was rewritten to read a different key. The
declaration in two bundled workflows kept parsing and controlled nothing. So
normalization whitelisting is necessary but not sufficient: a key is live only
when something reads it, and the reader is where a rename has to be checked.
The second half of the original claim does hold on its own — inserting `nil` for
an absent key poisons callers written as `value || fallback`, which is why
`PhaseSpec.put_worktree_field/3` drops absent keys instead.

### 5.5 Prefer compile-time enforcement over runtime discovery

When a registry and its implementations must agree, **generate the dispatch
from the registry** so disagreement cannot compile:

```elixir
for schema <- @tools do
  impl = :"tool_#{schema.name}"
  def call_tool(unquote(schema.name), args), do: unquote(impl)(args)
end
```

A missing implementation is now `undefined function tool_foreman_queue_status/1`
at compile time instead of a runtime "unknown tool". Apply the same reasoning to
workflow phases, event codecs, provider callbacks, and CLI subcommands: derive
one side from the other rather than maintaining two hand-written lists.

**A compile warning about an undefined module or function is a defect report,
not noise.** `run_executor.ex` was missing
`alias ForemanServer.Workflow.StepSequencer`, so
`StepSequencer.propagate_terminal/2` resolved to a non-existent top-level
module. Every multi-phase run — `plan.yaml` included —
crashed the executor on the phase 1 -> phase 2 transition instead of advancing,
which means `create-trd` had never once executed. The compiler emitted the
warning on every build for the entire life of the bug and nothing failed on it,
so the crash was repeatedly re-diagnosed as a workflow or agent problem. (That
module, and the loop that called it, were deleted in the Jobsite engine cutover
— the lesson stands, the code does not.)
Treat `undefined module`, `undefined function`, and unused-alias warnings as
build failures to be read, not scrolled past: this section's whole point is that
the compiler already knew.

### 5.6 Verify third-party contracts against dep source, and pin them with a test

Every MCP defect was an assumption about `anubis_mcp` that the library
contradicted (`handler: nil` required for dispatch; `validate_input: nil`
silently discards arguments; `Anubis.Server.Response` ≠ `Anubis.MCP.Response`;
`Frame.get_assign/2` does not exist; auth lives at `frame.context`, not
`frame.transport_context`). Read `deps/<lib>/lib/**` and confirm before coding,
then add a test asserting the invariant so an upgrade cannot silently break it.

### 5.7 Never duplicate a boundary across transports or adapters

`ForemanServer.MCP` and `ForemanServer.MCP.Stdio` were ~85% byte-identical, so
three defects existed twice and the stdio copy was missed on the first fix.
Put the shared behavior in one module (`ForemanServer.MCP.Dispatch`) and let
each variant implement only its genuine difference. When two implementations
must behave identically, add a test that exercises **both** through the same
assertions.

---

