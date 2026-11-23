# PLAN — foreman-i3qol: record base commit SHA on `RunBaseBranchRecorded`

## 1. Verdict

**Real gap, not a crash.** `packages/foreman_server/lib/foreman_server/events/run_base_branch_recorded.ex:23`
declares `defstruct [:run_id, :base_branch, :repo_id, :sequence]` — no SHA field. Because
`ForemanServer.EventCodec.build_struct/3` (`lib/foreman_server/event_codec.ex:161-168`) *raises* on
an undeclared key, a `base_sha` cannot simply be smuggled through the existing pass-through payload:
the field must be declared and the producers must be changed.

Today the only durable record of what the run was cut from is a *branch name*
(`ProjectionStore.run(run_id).base_branch`). The resolved commit exists at provisioning time —
`repo_base/1` (`lib/foreman_server/workflow/run_executor.ex:4256-4270`) already returns
`{:ok, branch, sha}` and throws the sha away for the recording path — but it is never persisted on
the run, so a resumed executor / operator cannot tell which commit the base branch pointed at.

## 2. Root cause

Three places drop the SHA that is already in hand:

- `RunExecutor.dispatch_run_base_branch/2` (`lib/foreman_server/workflow/run_executor.ex:1584-1591`)
  sends `%{run_id:, base_branch:}` only.
- `RunExecutor.dispatch_repo_base_branch/3` (`run_executor.ex:4274-4281`) sends branch only, although
  its caller at `run_executor.ex:4216` holds `base_ref` (the SHA).
- `RepoAttach.create/6` (`lib/foreman_server/workflow/repo_attach.ex:70-76`) same, with `base_ref`
  in scope at `repo_attach.ex:45`.

`Run.handle_command/2` for `"run.record_base_branch"` (`lib/foreman_server/aggregates/run.ex:782-798`)
validates only `run_id` + `base_branch`; `ProjectionStore` `"RunBaseBranchRecorded"`
(`lib/foreman_server/projection_store.ex:2828-2843`) projects only the branch.

## 3. Failing check first

Add ONE new test file and extend TWO existing ones. All three fail before the edits.

**(a) New:** `packages/foreman_server/test/foreman_server/aggregates/run_base_branch_test.exs`

```elixir
defmodule ForemanServer.Aggregates.RunBaseBranchTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.Run

  # Seed exactly as test/foreman_server/aggregates/run_flag_stuck_test.exs:6-24
  # does (`run.start` -> `apply_event`), then:
  defp record(payload),
    do: Run.handle_command(started(), %{type: "run.record_base_branch", payload: payload})

  test "the resolved base commit rides along with the branch" do
    assert {:ok, event} = record(%{run_id: "run-1", base_branch: "dev", base_sha: "abc123"})
    assert event.event_type == "RunBaseBranchRecorded"

    assert %ForemanServer.Events.RunBaseBranchRecorded{base_sha: "abc123"} =
             ForemanServer.EventCodec.decode!("RunBaseBranchRecorded", event.payload)
  end

  # AGENTS.md 5.3: absent is not malformed. Historical events carry no SHA and
  # must still record and decode.
  test "an absent base commit is still a valid recording" do
    assert {:ok, event} = record(%{run_id: "run-1", base_branch: "dev"})

    assert %ForemanServer.Events.RunBaseBranchRecorded{base_sha: nil} =
             ForemanServer.EventCodec.decode!("RunBaseBranchRecorded", event.payload)
  end

  test "a non-binary base commit is refused, never coerced" do
    assert {:error, {:missing_or_invalid, :base_sha, 7}} =
             record(%{run_id: "run-1", base_branch: "dev", base_sha: 7})
  end
end
```

**(b) Extend** `packages/foreman_server/test/foreman_server/projection_store_run_repositories_test.exs`:
in the test `"single-repo run: one primary entry ..."` (line 38) add `base_sha: "deadbeef"` to the
`RunBaseBranchRecorded` payload (line 46-47) and `base_sha: "deadbeef"` to the asserted primary map
(after `base_branch: "dev"`, line 61). In `"multi-repo run: ..."` add `base_sha: "cafe01"` to the
`repo_id: "api"` payload and assert the `"api"` entry carries `base_sha: "cafe01"`.

**(c) Extend** `packages/foreman_server/test/foreman_server/workflow/run_executor_pr_base_branch_test.exs`,
inside the resume test (line 59-104), right after the existing
`assert %{base_branch: "feat/original-work"} = ForemanServer.ProjectionStore.run(run_id)`:

```elixir
      head = String.trim(git!(repo, ["rev-parse", "HEAD"]))
      assert %{base_sha: ^head} = ForemanServer.ProjectionStore.run(run_id)
```

Run (fails):

```bash
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test \
  test/foreman_server/aggregates/run_base_branch_test.exs \
  test/foreman_server/projection_store_run_repositories_test.exs \
  test/foreman_server/workflow/run_executor_pr_base_branch_test.exs'
```

## 4. Edits

1. **`packages/foreman_server/lib/foreman_server/events/run_base_branch_recorded.ex`** — declare the
   field. Keep `@enforce_keys [:run_id, :base_branch]` unchanged (events already on disk have no
   SHA; enforcing it would break replay). Add to `@type t` after `base_branch:`:
   `base_sha: String.t() | nil,` and change line 23 to
   `defstruct [:run_id, :base_branch, :base_sha, :repo_id, :sequence]`. Add to the moduledoc:
   "`base_sha` is the commit the base branch pointed at when the run was cut; absent on events
   recorded before it was captured and when the revision could not be resolved."

2. **`packages/foreman_server/lib/foreman_server/aggregates/run.ex:782-798`** — validate it.
   Insert as a new `with` clause after the `base_branch` clause (line 785):

   ```elixir
         :ok <- require_optional_binary(payload, :base_sha),
   ```

   `require_optional_binary/2` already exists at `run.ex:1568-1574` and returns
   `{:error, {:missing_or_invalid, key, value}}`. The payload pass-through at `run.ex:793-795`
   needs no change: a declared field now flows through.

3. **`packages/foreman_server/lib/foreman_server/aggregates/run.ex:410-422`** — leave
   `apply_event/2` unchanged. `State` latches `base_branch` because `pr_watch.ex:537` reads it as
   `recorded_base`; nothing reads a base SHA from aggregate state, and adding an unread `State`
   field is dead state (AGENTS.md 5.4b). The SHA is a read-model fact only. **Do not add
   `:base_sha` to `State`.**

4. **`packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:1542` and `:1584-1593`** —
   resolve and send the primary's SHA. Change the call site at line 1542 from
   `dispatch_run_base_branch(state.run_id, resolved)` to
   `dispatch_run_base_branch(state, resolved)` and replace the two clauses:

   ```elixir
   # (keep the existing comment; append: the base commit is recorded alongside
   # when the revision reads, and an unresolvable revision records the branch
   # alone — AGENTS.md 5.3, absent is not malformed.)
   defp dispatch_run_base_branch(state, {:ok, branch}) do
     payload = %{run_id: state.run_id, base_branch: branch}

     payload =
       case resolve_revision(vcs_working_directory(state), branch) do
         {:ok, sha} -> Map.put(payload, :base_sha, sha)
         {:error, _reason} -> payload
       end

     CommandGateway.dispatch_system(%{
       type: "run.record_base_branch",
       command_id: "run_executor:base-branch:" <> state.run_id,
       aggregate_id: "run:#{state.run_id}",
       payload: payload
     })
   end

   defp dispatch_run_base_branch(_state, {:error, _reason}), do: :ok
   ```

   (`resolve_revision/2` is private in the same module at `run_executor.ex:4643`;
   `vcs_working_directory/1` at `run_executor.ex:3766`.)

5. **`packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:4230` and `:4274-4281`** —
   the secondary's SHA is already resolved as `base_ref` (`run_executor.ex:4216`). Change line 4230
   to `dispatch_repo_base_branch(state.run_id, repo.id, base_branch, base_ref)` and the function to
   `defp dispatch_repo_base_branch(run_id, repo_id, branch, base_sha) do`, with payload
   `%{run_id: run_id, base_branch: branch, base_sha: base_sha, repo_id: repo_id}`.

6. **`packages/foreman_server/lib/foreman_server/workflow/repo_attach.ex:70-76`** — add
   `base_sha: base_ref` to the dispatched payload (`base_ref` is `create/6`'s own parameter,
   `repo_attach.ex:45`).

7. **`packages/foreman_server/lib/foreman_server/projection_store.ex:2828-2843`** — project it.
   In the `repo_id when is_binary(repo_id)` branch, pipe the existing `Map.update(...)` result into
   a second `Map.update` over `:repo_base_shas` keyed the same way, but only when
   `get(payload, :base_sha)` is a binary (never insert `nil`, AGENTS.md 5.4b). In the `_ ->` branch
   change `maybe_put(run, :base_branch, get(payload, :base_branch))` to
   `run |> maybe_put(:base_branch, get(payload, :base_branch)) |> maybe_put(:base_sha, get(payload, :base_sha))`
   (`maybe_put/3` at `projection_store.ex:5920` already drops `nil`).

8. **`packages/foreman_server/lib/foreman_server/projection_store.ex:4539`, `:4553-4562`,
   `:4592-4604`, `:1191-1200`** — surface it on the run view.
   - After line 4539 add `base_shas = (run && get(run, :repo_base_shas)) || %{}`.
   - In `primary_entry` (after `base_branch:`, line 4557) add `base_sha: run && get(run, :base_sha),`.
   - Pass `base_shas` into `secondary_run_repository/6` (becomes `/7`, both the call at
     `projection_store.ex:4596-4601`-area and the definition at `:4592`) and add
     `base_sha: Map.get(base_shas, repo_id),` after its `base_branch:` line.
   - Add `base_sha: String.t() | nil,` to the `@type run_repository` map at `:1195`.

## 5. Verification

```bash
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test \
  test/foreman_server/aggregates/run_base_branch_test.exs \
  test/foreman_server/projection_store_run_repositories_test.exs \
  test/foreman_server/workflow/run_executor_pr_base_branch_test.exs \
  test/foreman_server/workflow/run_executor_multi_repo_test.exs \
  test/foreman_server/event_codec_test.exs --warnings-as-errors'
devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted'
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors'
```

Success = all green, zero warnings. `run_executor_multi_repo_test.exs:246` (`repo_base_branches`)
must still pass unchanged.

**Documentation gate.** Added identifiers: event field `base_sha` on `RunBaseBranchRecorded`; run
projection keys `base_sha` and `repo_base_shas`; `run_repositories/1` entry key `base_sha`. Required
edits:
- `docs/lessons/architecture-and-events.md:222` — extend the `RunBaseBranchRecorded` row to
  "…and the commit it pointed at".
- `CLAUDE.md:538` — the sentence listing `repo_base_branches` also names `repo_base_shas`.
- `docs/user-guide.md:1361-1364` — one sentence on the `GET /api/runs/{id}` bullet: the projected
  run also carries `base_sha`, the commit the base branch pointed at, or `null`.
- `README.md`, `docs/cli-reference.md`: no edit — no CLI verb, flag, route or config key changes
  (`docs/cli-reference.md:753` is about `auto_pr_base_branch_unresolved`, untouched).

## 6. Out of scope

- The other gaps in the source review (`base_ref_policy` project setting, `git fetch origin <base>`
  before worktree creation, `ProjectRecommendations` "behind origin"). Different beads.
- `State.base_sha` on the Run aggregate (edit 3) and any change to `apply_event/2`.
- `FOREMAN_REPOS` / `repo_entries/2` (`run_executor.ex:5664-5690`): it already exports `base_ref`.
- `PrRisk` / `PrWatch` rubric inputs, merge gate, AutoPR base resolution.
- Reformatting or restructuring adjacent code in the touched functions.
