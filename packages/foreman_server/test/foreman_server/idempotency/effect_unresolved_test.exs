defmodule ForemanServer.Idempotency.EffectUnresolvedTest do
  @moduledoc """
  An effect key that recovery could not resolve (a reconciler blocked the run, or the
  run was terminal and could not be blocked) is never repeated by the operator's
  Create PR: `Effect.run/4` refuses with `{:error, {:effect_unresolved, key}}`, leaving
  the key and its SHAs untouched, until an operator `run.reset` follows the version the
  boot step recorded. A `:not_done` retry is legitimate and is not marked.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias ForemanServer.{Aggregate, CommandGateway, CommandRouter, PrCreate, ProjectionStore}
  alias ForemanServer.Aggregates.Run
  alias ForemanServer.Idempotency.{Effect, KeyStore}
  alias ForemanServer.Idempotency.Reconcilers.PrCreate, as: CreateEffect
  alias ForemanServer.TestSupport.PrFixSupport, as: Fix
  alias ForemanServer.TestSupport.PrWatchSupport, as: Support
  alias ForemanServer.TestSupport.{EffectWorld, KeyStoreReset}
  alias ForemanServer.EventStore, as: FEventStoreMod
  alias ForemanServerWeb.Workspace.Actions

  @base "main"

  setup do
    KeyStoreReset.reset!()

    on_exit(fn ->
      PrCreate.clear_command_runner()
      KeyStoreReset.reset!()
    end)

    :ok
  end

  # A thread whose project checkout is a real repository with a bare origin and the run
  # branch, behind the scripted GitHub. `complete: false` leaves the run blockable.
  defp thread!(world, complete) do
    repo = Fix.git_repo!()
    token = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    project_id = "project-unres-#{token}"

    run = Support.start_run!(project_id: project_id, complete: complete)
    branch = "foreman/#{run.run_id}/implement"

    :ok =
      ProjectionStore.apply_events([
        %{event_type: "ProjectRegistered", payload: %{project_id: project_id, path: repo}},
        %{
          event_type: "TaskCreated",
          payload: %{
            task_id: run.task_id,
            project_id: project_id,
            title: "Add widgets",
            description: "Adds the widget screen",
            status: "open",
            task_type: "implement"
          }
        },
        %{
          event_type: "RunBaseBranchRecorded",
          payload: %{run_id: run.run_id, base_branch: @base}
        },
        %{
          event_type: "WorktreeCreated",
          payload: %{
            operation_id: "wt-#{run.run_id}-implement",
            project_id: project_id,
            run_id: run.run_id,
            phase_id: "implement",
            repo_path: repo,
            worktree_path: "/gone/#{token}",
            branch: branch,
            base_ref: @base,
            cleanup: "remove"
          }
        }
      ])

    fx = EffectWorld.adopt!(repo, branch)
    PrCreate.set_command_runner(EffectWorld.runner(world))
    on_exit(fn -> ForemanServer.RunControl.clear(run.run_id) end)
    {Map.merge(run, %{repo: repo, branch: branch}), fx}
  end

  # The operator's Create PR dies right after `gh pr create` made the PR, and the boot
  # sweep reaches the verdict `:done`.
  defp crash_and_sweep!(world, t) do
    EffectWorld.crash!(world, :create, :after, fn -> PrCreate.execute(t.run_id) end)
    EffectWorld.sweep(world)
  end

  defp version(run_id), do: run_id |> then(&Aggregate.load(Run, "run:#{&1}")) |> elem(1)

  defp key_of(t), do: CreateEffect.key(t.run_id, t.branch, @base)

  defp create_command(run_id) do
    %{
      type: "run.pr.create",
      command_id: "create-#{run_id}-#{System.unique_integer([:positive])}",
      aggregate_id: "run:#{run_id}",
      payload: %{run_id: run_id}
    }
  end

  defp reset_run!(run_id) do
    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "run.reset",
        command_id: "reset-#{run_id}-#{System.unique_integer([:positive])}",
        aggregate_id: "run:#{run_id}",
        payload: %{"run_id" => run_id}
      })
  end

  describe "a key left unresolved" do
    test "a blocked run: the operator's Create PR is refused, key and SHAs untouched, nothing created" do
      world = EffectWorld.start()
      {t, _fx} = thread!(world, false)
      key = key_of(t)

      crash_and_sweep!(world, t)

      assert EffectWorld.status(t.run_id) == "blocked"
      assert {:ok, %{status: :ambiguous, metadata: metadata} = before_key} = KeyStore.get(key)
      assert KeyStore.unresolved_version(metadata) == {:ok, version(t.run_id)}
      assert metadata["unresolved_reason"] == "effect_already_done"
      assert EffectWorld.executed(world, :create) == 1

      assert {:error, {:effect_unresolved, ^key}} = PrCreate.execute(t.run_id)

      assert {:ok, ^before_key} = KeyStore.get(key)
      assert EffectWorld.executed(world, :create) == 1
      assert length(EffectWorld.prs(world)) == 1
    end

    test "the operator command returns the typed error and the workspace words it" do
      world = EffectWorld.start()
      {t, _fx} = thread!(world, false)
      key = key_of(t)
      crash_and_sweep!(world, t)

      assert {:error, {:effect_unresolved, ^key}} =
               CommandGateway.dispatch_operator(create_command(t.run_id))

      message = Actions.describe({:effect_unresolved, key})
      assert message =~ "foreman_doctor"
      assert message =~ "reset the run"
      refute "PrCreated" in Support.run_event_types(t.run_id)
    end

    test "a completed run that could not be blocked is refused too, and stays so" do
      world = EffectWorld.start()
      {t, _fx} = thread!(world, true)
      key = key_of(t)

      crash_and_sweep!(world, t)

      assert {:ok, %{status: :ambiguous, metadata: metadata} = before_key} = KeyStore.get(key)
      assert KeyStore.unresolved_version(metadata) == {:ok, version(t.run_id)}

      assert {:error, {:effect_unresolved, ^key}} = PrCreate.execute(t.run_id)

      # No reset exists for a completed run (`run.reset` is accepted from failed, stuck,
      # blocked and paused only), so the refusal stands.
      assert {:error, _not_resettable} = reset_attempt(t.run_id)
      assert {:error, {:effect_unresolved, ^key}} = PrCreate.execute(t.run_id)
      assert {:ok, ^before_key} = KeyStore.get(key)
      assert EffectWorld.executed(world, :create) == 1
    end

    test "an event that is not a reset does not lift the refusal" do
      world = EffectWorld.start()
      {t, _fx} = thread!(world, false)
      key = key_of(t)
      crash_and_sweep!(world, t)

      v = version(t.run_id)

      :ok =
        FEventStoreMod.append_to_stream("run:#{t.run_id}", v, [
          %EventStore.EventData{
            event_type: "RunBaseBranchRecorded",
            data: %{run_id: t.run_id, base_branch: @base},
            metadata: %{}
          }
        ])

      assert version(t.run_id) == v + 1
      assert {:error, {:effect_unresolved, ^key}} = PrCreate.execute(t.run_id)
    end
  end

  describe "the exit" do
    test "after a run.reset the next Effect.run runs and records a fresh intent" do
      world = EffectWorld.start()
      {t, _fx} = thread!(world, false)
      key = key_of(t)
      crash_and_sweep!(world, t)

      {:ok, %{metadata: stored}} = KeyStore.get(key)
      assert {:error, {:effect_unresolved, ^key}} = run_effect(key, stored)

      reset_run!(t.run_id)

      test_pid = self()

      assert {:ok, :again} =
               Effect.run(
                 :pr_create,
                 key,
                 fn ->
                   send(test_pid, {:inside, KeyStore.get(key)})
                   {:ok, :again}
                 end,
                 stored
               )

      assert_received {:inside, {:ok, %{status: :started, metadata: started}}}
      assert KeyStore.unresolved_version(started) == :none
      assert started["run_id"] == t.run_id
      assert {:ok, %{status: :completed}} = KeyStore.get(key)
    end

    test "a block after the reset is a new marker: an earlier reset in the stream does not lift it" do
      world = EffectWorld.start()
      {t, _fx} = thread!(world, false)
      key = key_of(t)
      crash_and_sweep!(world, t)
      reset_run!(t.run_id)

      {:ok, _} =
        CommandRouter.dispatch(%{
          type: "project.register",
          payload: %{project_id: t.project_id, path: t.repo},
          aggregate_id: "project:#{t.project_id}"
        })

      {:ok, _} =
        CommandRouter.dispatch_run_start(t.project_id, %{
          run_id: t.run_id,
          task_id: t.task_id,
          workflow_snapshot: %{phases: [], attempt: 2}
        })

      EffectWorld.sweep(world)

      assert EffectWorld.status(t.run_id) == "blocked"
      {:ok, %{metadata: stored}} = KeyStore.get(key)
      assert KeyStore.unresolved_version(stored) == {:ok, version(t.run_id)}
      assert {:error, {:effect_unresolved, ^key}} = run_effect(key, stored)
    end
  end

  describe "a retry that is legitimate" do
    for complete <- [false, true] do
      test "a :not_done verdict leaves no marker and the retry runs (run completed: #{complete})" do
        world = EffectWorld.start()
        {t, _fx} = thread!(world, unquote(complete))
        key = key_of(t)

        EffectWorld.crash!(world, :create, :before, fn -> PrCreate.execute(t.run_id) end)
        EffectWorld.sweep(world)

        assert {:ok, %{status: :ambiguous, metadata: metadata}} = KeyStore.get(key)
        assert KeyStore.unresolved_version(metadata) == :none
        assert EffectWorld.executed(world, :create) == 0

        assert {:ok, %{pr_url: url}} = PrCreate.execute(t.run_id)
        assert [%{"url" => ^url}] = EffectWorld.prs(world)
        assert {:ok, :completed} = KeyStore.status(key)
      end
    end
  end

  describe "the run stream cannot be read" do
    test "the effect is refused, never repeated" do
      key = Effect.key(:pr_create, "run-unreadable", "h:main")

      meta = %{
        "run_id" => "run-unreadable",
        "effect_class" => "pr_create",
        "head_branch" => "h",
        "base_branch" => "main",
        "cwd" => "/w"
      }

      :ok = KeyStore.mark_started(key, meta)
      :ok = KeyStore.mark_unresolved(key, 3, "effect_outcome_ambiguous")
      {:ok, before_key} = KeyStore.get(key)

      :meck.new(FEventStoreMod, [:passthrough, :no_link])
      on_exit(fn -> :meck.unload(FEventStoreMod) end)
      :meck.expect(FEventStoreMod, :read_stream_forward, fn _, _, _ -> {:error, :boom} end)

      assert {:error, {:effect_unresolved, ^key}} = run_effect(key, meta)

      :meck.expect(FEventStoreMod, :read_stream_forward, fn _, _, _ -> raise "store down" end)
      assert {:error, {:effect_unresolved, ^key}} = run_effect(key, meta)

      assert {:ok, ^before_key} = KeyStore.get(key)
    end
  end

  defp reset_attempt(run_id) do
    CommandGateway.dispatch_system(%{
      type: "run.reset",
      command_id: "reset-try-#{run_id}-#{System.unique_integer([:positive])}",
      aggregate_id: "run:#{run_id}",
      payload: %{"run_id" => run_id}
    })
  end

  # `Effect.run` with a function that must not run when the key is refused.
  defp run_effect(key, meta) do
    test_pid = self()

    result =
      Effect.run(
        :pr_create,
        key,
        fn ->
          send(test_pid, :ran)
          :ran
        end,
        meta
      )

    case result do
      {:error, {:effect_unresolved, _}} -> refute_received :ran
      _ -> :ok
    end

    result
  end
end
