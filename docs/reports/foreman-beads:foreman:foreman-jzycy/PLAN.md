# Plan — foreman-jzycy: decide and implement the reviewer-for-terminal-run behaviour

## 1. Verdict

**Not a bug. The behaviour is intentional and stays. The gap is the missing
explicit test; add it (plus a one-line decision comment). No behaviour change.**

Evidence that reviewing a terminal failed/cancelled run is deliberate, on the
current tree (HEAD `796c888c`):

- `packages/foreman_server/lib/foreman_server/review/analyzer.ex:414-422` —
  `settle_run("RunCancelled", …)` and `settle_run("RunFailed", …)` exist purely
  to wait for a *failed or cancelled* run's executor to finish writing the
  archive before reviewing it. Code written to review failed runs correctly.
- `packages/foreman_server/lib/foreman_server/review/capture.ex:238` —
  `close_cancelled_run/1` builds a cancelled run's archive from its retained
  worktree (working-tree diff), for the reviewer.
- `docs/user-guide.md:3110-3131` — "A cancelled run … is archived and reviewed
  like any other"; "A failed workflow run has the same ordering problem … the
  review step waits up to 30 seconds for the executor to exit and then reviews
  the archive the executor wrote."
- `docs/user-guide.md:1114-1116` (added by PR #923, the run this review is
  about) — "The automated reviewer still runs on a *failed* run on purpose
  (`ForemanServer.Review.Analyzer` treats `RunFailed` as a terminal event), so a
  reviewer's `pi` after a failure is not a leaked worker."
- The reviewer is **not** an Overwatch worker and **not** a second writer: it is
  a read-only `DetachedRun` in a scratch cwd
  (`review/evaluator/agent.ex:216-230`: `sandbox_mode: :read_only`, `cwd` =
  scratch dir outside the repo and archive). It therefore cannot "land" code and
  was never meant to; its output is the verdict plus `foreman-gap` beads, which
  is exactly what a *failed* run needs.

So expectation (3) of the original request ("no review or other agent phase is
started for a run that is already terminal") is rejected on purpose: it would
delete the review of every failed and cancelled run, which is the subsystem's
whole point. What PR #923 omitted is the explicit pinning test and the
`analyzer.ex` comment recording the decision.

## 2. Root cause (of the finding, not of a defect)

`analyzer.ex:53` `@terminal_events` and `handle_info/2` at `analyzer.ex:153-162`
are correct. Nothing in the review suite states *why* a terminal failed/cancelled
run is still reviewed, and no test exercises `RunCancelled` through the
subscriber path, so a future reader (or reviewer) reads the behaviour as an
oversight. Fix the silence, not the code.

## 3. Failing check first

This is a decision pin, not a regression test, so it passes on the current tree
by design. Prove it is load-bearing instead (do this, confirm red, then revert):

```bash
cd packages/foreman_server
# temporarily delete RunFailed and RunCancelled from @terminal_events (analyzer.ex:53)
MIX_ENV=test mix test test/foreman_server/review/analyzer_test.exs:<new-test-line>
# expect: the new test fails (no review is ever recorded)
git checkout -- lib/foreman_server/review/analyzer.ex
```

If deps are not fetched in this worktree, run
`devbox run -- bash -c 'cd packages/foreman_server && mix deps.get'` once first.

## 4. Edits

### Edit 1 — record the decision next to the list it governs

File: `packages/foreman_server/lib/foreman_server/review/analyzer.ex`, line 53.

Current:

```elixir
  @terminal_events ~w(RunCompleted RunFailed RunCancelled JobsiteCompleted JobsiteFailed JobsiteCancelled)
```

Replace with (comment added above the unchanged attribute):

```elixir
  # A failed or cancelled run is reviewed on purpose (foreman-jzycy): the review
  # of work that did not land is where `foreman-gap` beads come from, and the
  # reviewer is a read-only `DetachedRun` in a scratch cwd, not an Overwatch
  # worker in the run's worktree — it is neither a leaked worker nor a second
  # writer. Pinned by "a run whose projection is already terminal is still
  # reviewed" in test/foreman_server/review/analyzer_test.exs; documented at
  # docs/user-guide.md "Session archive and automated review" and in the
  # run-lifecycle list (docs/user-guide.md:1114).
  @terminal_events ~w(RunCompleted RunFailed RunCancelled JobsiteCompleted JobsiteFailed JobsiteCancelled)
```

Nothing else in the file changes.

### Edit 2 — the pinning test

File: `packages/foreman_server/test/foreman_server/review/analyzer_test.exs`.

Insert in the `describe "subscriber" do` block (starts at line 799), immediately
after the existing test `"reacts to RunCompleted and RunFailed, ignoring
non-terminal run events"` (ends at line 836, the `end` before the
`JobsiteCompleted` test at line 837). Helpers used (`uid/1`, `seed_run/3`,
`subject/4`, `init_archive/1`, `await/2`, `cancelled_checkout/1`, `git!/2`) are
all already defined in this module; `cancelled_checkout/1` and `git!/2` live
under `describe "cancelled runs"` but are ordinary module-level `defp`s, so they
are callable here.

```elixir
    # Decision (foreman-jzycy): a run that is ALREADY terminal — failed or
    # cancelled — is still reviewed, and that is the intended behaviour, not an
    # oversight. The reviewer is why a failed run is useful: its gaps become
    # `foreman-gap` beads. It runs as a read-only `DetachedRun` in a scratch cwd,
    # outside Overwatch and outside the run's worktree, so it is neither a
    # leaked worker nor a second writer (docs/user-guide.md:1114). Change this
    # test first if that decision is ever reversed.
    test "a run whose projection is already terminal is still reviewed, failed and cancelled alike",
         %{repo: repo} do
      base = cancelled_checkout(repo)

      for {type, status} <- [{"RunFailed", "failed"}, {"RunCancelled", "cancelled"}] do
        run_id = uid("run")
        seed_run(run_id, repo, worktree_path: repo, base_ref: base)
        init_archive(subject(:run, run_id, repo))

        assert :ok =
                 ProjectionStore.apply_events([
                   %{event_type: type, payload: %{run_id: run_id}}
                 ])

        # The projection is updated before subscribers are notified, so the
        # Analyzer saw a run that was already terminal.
        run = ProjectionStore.run(run_id)
        assert run.status == status
        assert run.terminal?

        review = await(fn -> ProjectionStore.review("run", run_id) end)
        assert review.verdict == "met"

        assert {:ok, %{"status" => ^status}} =
                 Archive.read_manifest(Archive.dir(:run, run_id, repo))
      end
    end
```

Note for the implementer: no run executor is registered for these runs, so
`settle_run/2` returns at once (`analyzer.ex:431`); the `RunCancelled` leg then
goes through `Capture.close_cancelled_run/1`, which is why the real checkout from
`cancelled_checkout/1` is needed.

## 5. Verification

```bash
devbox run -- bash -c 'cd packages/foreman_server && mix deps.get'
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test test/foreman_server/review/analyzer_test.exs --warnings-as-errors'
devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted'
```

Success = the analyzer file's tests all pass (the new test included, 0 failures,
no warnings) and the formatter reports no diff. Then run the full suite once:

```bash
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors'
```

## 6. Documentation gate

No externally visible identifier is added, removed or renamed (no route, config
key, env var, CLI verb, MCP tool, command or event type). The behaviour is
unchanged, so nothing in `CLAUDE.md`, `README.md`, `docs/user-guide.md` or
`docs/cli-reference.md` becomes stale. The decision is already written in
`docs/user-guide.md:1114-1116` and `docs/user-guide.md:3110-3131`; do **not**
restate it a third time. No `CHANGELOG.md` entry: no operator-visible change.

The implementer's report must state the decision explicitly: *expectation (3) of
foreman-ws23g is rejected; a terminal failed/cancelled run is still reviewed on
purpose, now pinned by a test and a comment.*

## 7. Out of scope

- Do **not** change `@terminal_events`, `handle_info/2`, `settle_run/2`, or any
  other analyzer behaviour. Comment and test only.
- Do **not** add a config switch for "review failed runs" — nobody asked, and a
  knob would turn the decision back into a question.
- Do **not** touch `Overwatch`, `WorkerSupervisor`, `Workflow.Dispatcher`,
  `JidoHarnessWorker` or the PR #923 worker-stop code; this task is only the
  fourth gap of that review.
- Do **not** edit the other `foreman-ws23g` report artifacts
  (`docs/reports/foreman-beads:foreman:foreman-ws23g/*`); that is a separate,
  minor finding.
- Do **not** rewrite, reorder or restyle neighbouring tests in
  `analyzer_test.exs`.
