# PLAN — foreman-vbfmo.12: cancelled runs land in the coordinator's waiting_on_you group

All paths are repository-relative from the repo root. Elixir code lives under `packages/foreman_server/`.

## 1. Verdict

**Real bug, still present on this tree** (HEAD `0988b071`).

Evidence:
- `packages/foreman_server/lib/foreman_server/coordinator/context.ex:137-138`:
  ```elixir
  def card_state(%Thread{status: status})
      when status in ~w(blocked stuck needs_recovery paused failed cancelled), do: :waiting_on_you
  ```
  A thread whose run the operator cancelled (`status == "cancelled"`, `resolved: false`) gets `:waiting_on_you`.
- `packages/foreman_server/lib/foreman_server/coordinator/context.ex:434` counts
  `Enum.count(model.cards, &(&1.state in [:working, :waiting_on_you]))` as "active threads now", so a cancelled
  thread also inflates that number in the LIMITS section.
- `packages/foreman_server/test/foreman_server/coordinator/context_test.exs:359-366` ("card states follow the
  thread's disposition and status") has no `cancelled` case, so nothing pins the current behaviour.

Already-correct, do **not** change:
- `packages/foreman_server/lib/foreman_server/overview/group.ex:121` `@cancelled ~w(cancelled deleted removed)`
  and `:139` `i.status in @cancelled -> {:resolved, :cancelled}` — the Overview grouping is right already.
- Overview coverage already exists in `packages/foreman_server/test/foreman_server/overview/group_test.exs`:
  cancelled `:14` and `:38`, failed `:42-43`, blocked statuses `:40-41`. **No new Overview tests are needed**;
  the bead's "Overview test for each status" is already satisfied there (confirmed by reading the `@rows` table).

## 2. Root cause

`ForemanServer.Coordinator.Context.card_state/1` treats every non-running terminal/stalled status as "the operator
must act". `cancelled` is a terminal disposition the operator already chose; it needs no attention. The coordinator's
card states therefore disagree with `Overview.Group.classify/1`, which puts cancelled in `:resolved`.

## 3. Failing check first

Add the cancelled assertion to the existing test, then run it and watch it fail before editing `context.ex`.

File: `packages/foreman_server/test/foreman_server/coordinator/context_test.exs`
Test: `"card states follow the thread's disposition and status"` (line 359).

Add inside that test, after the `"failed"` line (`:362`):

```elixir
    assert Context.card_state(thread(1, "cancelled")) == :resolved
```

Command (from the repo root), expected to FAIL with
`Assertion with == failed … left: :waiting_on_you, right: :resolved`:

```
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test test/foreman_server/coordinator/context_test.exs'
```

If the DB is needed, the suite's `DATABASE_URL` is
`postgres://postgres:postgres@localhost:55432/foreman_test`; prefix the `mix test` with it if the run errors on
database connection. Allow >60s for the first compile.

## 4. Edits

### Edit 1 — `packages/foreman_server/lib/foreman_server/coordinator/context.ex`, `card_state/1`

Lines 135-138 currently read:

```elixir
  def card_state(%Thread{resolved: true}), do: :resolved

  def card_state(%Thread{status: status})
      when status in ~w(blocked stuck needs_recovery paused failed cancelled), do: :waiting_on_you
```

Replace with:

```elixir
  def card_state(%Thread{resolved: true}), do: :resolved

  # An operator-cancelled thread is terminal by the operator's own decision: it
  # needs no attention, and `Overview.Group.classify/1` groups it `:resolved` too.
  def card_state(%Thread{status: "cancelled"}), do: :resolved

  def card_state(%Thread{status: status})
      when status in ~w(blocked stuck needs_recovery paused failed), do: :waiting_on_you
```

Clause order matters: the `"cancelled"` clause must sit **above** the `last_report` clause at the current line 140
(`def card_state(%Thread{last_report: %{verdict: _}}), do: :ready_for_review`), otherwise a cancelled thread that
already produced a report would classify `:ready_for_review`.

Do not touch the `@doc`/`@spec` at lines 132-134 — the returned atom set is unchanged.

### Edit 2 — `packages/foreman_server/test/foreman_server/coordinator/context_test.exs`

In the test `"card states follow the thread's disposition and status"` (line 359), make the assertion block cover
every status the bead names, so the three dispositions are pinned:

```elixir
  test "card states follow the thread's disposition and status" do
    assert Context.card_state(thread(1, "in_progress")) == :working
    assert Context.card_state(thread(1, "blocked")) == :waiting_on_you
    assert Context.card_state(thread(1, "stuck")) == :waiting_on_you
    assert Context.card_state(thread(1, "needs_recovery")) == :waiting_on_you
    assert Context.card_state(thread(1, "failed")) == :waiting_on_you
    assert Context.card_state(thread(1, "cancelled")) == :resolved
    assert Context.card_state(thread(1, "cancelled", last_report: %{verdict: "ok", summary: "s"})) ==
             :resolved
    assert Context.card_state(thread(1, "completed")) == :ready_for_review
    assert Context.card_state(thread(1, "completed", resolved: true)) == :resolved
    assert Context.card_state(thread(1, "queued")) == :idle
  end
```

The `thread/3` helper is defined at `packages/foreman_server/test/foreman_server/coordinator/context_test.exs:44-54`
and already accepts `:last_report` and `:resolved` in `opts`; no helper change is needed.

## 5. Verification

From the repo root:

```
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test test/foreman_server/coordinator/context_test.exs test/foreman_server/overview/group_test.exs --warnings-as-errors'
devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted'
```

Success means: both test files green (0 failures), no compiler warnings, `mix format --check-formatted` exits 0.
If the test run fails on the database, re-run with the
`DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test` prefix inside the `bash -c` string. These
runs take over a minute; give the command a generous timeout.

Documentation gate (already checked, no action expected): `card_state/1` is an internal function; `grep` for
`card_state` and `active threads now` in `CLAUDE.md`, `README.md`, `docs/user-guide.md`, `docs/cli-reference.md`
returns no hits. The `waiting_on_you` hits in `CLAUDE.md:1157` and `docs/user-guide.md:422,1454` describe
`Overview.Group.classify/1`, which this change does not touch, and they already document cancelled as resolved.
Re-run those greps after the edit and state in the report that no doc file needed an edit (no operator-visible
identifier added, removed or renamed).

## 6. Out of scope — do not touch

- `packages/foreman_server/lib/foreman_server/overview/group.ex` and its tests: already correct.
- `packages/foreman_server/lib/foreman_server/coordinator/context.ex:434` ("active threads now"): it is fixed
  transitively by Edit 1; do not change the counting expression.
- The `deleted` / `removed` statuses in `Overview`'s `@cancelled`: they already fall through to `:idle` in
  `card_state/1` and produce no bogus waiting card. Do not widen the new clause to cover them.
- No new command, event, MCP tool, HTTP route, CLI verb or config key. No refactor of the surrounding
  `card_state/1` clauses, the cut order at `context.ex:214`, or any other file.
- Do not merge the PR (operator-only gate).
