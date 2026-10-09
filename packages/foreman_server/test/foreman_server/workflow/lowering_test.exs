defmodule ForemanServer.Workflow.LoweringTest do
  # Pure tests: no event store, no RunExecutor, no Postgres. `Lowering.lower/2`
  # takes a phase-spec list and a plain ctx map and returns a `Program.t()` —
  # these assert its structural output against every bundled manifest.
  use ExUnit.Case, async: true

  alias ForemanServer.Jobsite.{Agent, Error, Program, Step}
  alias ForemanServer.Jobsite.Runners.Overwatch
  alias ForemanServer.Workflow.{Interpreter, Lowering, PhaseSpec}

  @manifests_dir Path.join([:code.priv_dir(:foreman_server), "defaults", "workflows"])
  @bundled_manifests ~w(assess fix implement-trd implement-trd-beads prd review)

  defp ctx(overrides \\ %{}),
    do: Map.merge(%{run_id: "run-test-1", worktree_spec: nil}, overrides)

  defp lower!(phases, overrides \\ %{}) do
    assert {:ok, %Program{steps: steps}} =
             phases |> PhaseSpec.normalize_all() |> Lowering.lower(ctx(overrides))

    steps
  end

  defp kinds(steps), do: Enum.map(steps, & &1.kind)

  for name <- @bundled_manifests do
    test "lowers #{name}.yaml into one agent and one commit step per phase behind a single worktree step" do
      path = Path.join(@manifests_dir, unquote(name) <> ".yaml")
      assert {:ok, workflow} = Interpreter.load(path)
      phase_specs = PhaseSpec.normalize_all(Map.get(workflow, "phases", []))
      assert phase_specs != []

      assert {:ok, %Program{steps: steps}} = Lowering.lower(phase_specs, ctx())

      assert hd(steps).kind == :worktree
      assert length(Enum.filter(steps, &(&1.kind == :worktree))) == 1
      assert length(Enum.filter(steps, &(&1.kind == :agent))) == length(phase_specs)
      assert length(Enum.filter(steps, &(&1.kind == :commit))) == length(phase_specs)

      # A phase's steps are contiguous and ordered agent -> [gate] -> commit.
      for {phase_spec, index} <- Enum.with_index(phase_specs) do
        phase_steps = Enum.filter(steps, &(&1.opts.phase_idx == index))

        expected =
          [:agent] ++
            if(Map.has_key?(phase_spec, :required_file), do: [:gate], else: []) ++ [:commit]

        assert kinds(phase_steps) -- [:worktree] == expected
      end

      # Every agent step uses the Overwatch runner, exactly one iteration, and
      # no completion signal (that runner performs no signal matching).
      for %Step{kind: :agent, opts: opts} <- steps do
        assert opts.runner == Overwatch
        assert opts.max_iterations == 1
        assert opts.completion_signals == []
        assert %Agent{} = opts.agent
      end

      # A commit step defers exactly when its phase says `commit: false`; an
      # absent key commits.
      for {phase_spec, commit_step} <-
            Enum.zip(phase_specs, Enum.filter(steps, &(&1.kind == :commit))) do
        assert commit_step.opts.defer? == (Map.get(phase_spec, :commit) == false)
      end
    end
  end

  test "prd.yaml lowers to a worktree step plus agent and commit per phase, and no gate" do
    {:ok, workflow} = Interpreter.load(Path.join(@manifests_dir, "prd.yaml"))
    phase_specs = PhaseSpec.normalize_all(Map.fetch!(workflow, "phases"))

    assert {:ok, %Program{steps: steps}} = Lowering.lower(phase_specs, ctx())

    # No bundled manifest declares `requiredFile:`, so no gate is ever lowered.
    refute Enum.any?(steps, &(&1.kind == :gate))
    assert length(steps) == 1 + 2 * length(phase_specs)
  end

  describe "interruptibility" do
    test "only a phase's first step may be preceded by an intent check" do
      steps =
        lower!([
          %{"name" => "p1", "prompt" => "one", "required_file" => "docs/PRD"},
          %{"name" => "p2", "prompt" => "two"}
        ])

      assert [
               {:worktree, false},
               {:agent, true},
               {:gate, true},
               {:commit, true},
               {:agent, false},
               {:commit, true}
             ] = Enum.map(steps, &{&1.kind, Map.get(&1.opts, :uninterruptible, false)})
    end

    test "with no worktree step the agent step is the interruptible one" do
      steps = lower!([%{"name" => "p1", "prompt" => "one"}], %{worktree_spec: %{enabled: false}})

      assert [{:agent, false}, {:commit, true}] =
               Enum.map(steps, &{&1.kind, Map.get(&1.opts, :uninterruptible, false)})
    end
  end

  describe "worktree step" do
    test "worktree: enabled: false emits none" do
      steps =
        lower!([%{"name" => "p1", "prompt" => "do work"}], %{worktree_spec: %{enabled: false}})

      refute :worktree in kinds(steps)
    end

    test "a declared worktree block that leaves it enabled still emits one" do
      steps =
        lower!([%{"name" => "p1", "prompt" => "do work"}], %{
          worktree_spec: %{enabled: true, cleanup: "never"}
        })

      assert [:worktree, :agent, :commit] = kinds(steps)
    end
  end

  describe "start_index (resume)" do
    test "phases before it are not lowered and the worktree step moves to the first one that is" do
      phases = [
        %{"name" => "p1", "prompt" => "one"},
        %{"name" => "p2", "prompt" => "two"},
        %{"name" => "p3", "prompt" => "three"}
      ]

      steps = lower!(phases, %{start_index: 1})

      assert [:worktree, :agent, :commit, :agent, :commit] = kinds(steps)
      assert steps |> Enum.map(& &1.opts.phase_idx) |> Enum.uniq() == [1, 2]
      assert hd(steps).opts.phase_idx == 1
    end
  end

  describe "commit step" do
    test "carries the message RunExecutor's pause path commits with, keyed by the phase's number" do
      steps =
        lower!([
          %{"name" => "p1", "prompt" => "one"},
          %{"name" => "p2", "prompt" => "two", "index" => 7}
        ])

      assert ["Foreman run run-test-1 phase 1", "Foreman run run-test-1 phase 7"] =
               steps |> Enum.filter(&(&1.kind == :commit)) |> Enum.map(& &1.opts.message)

      assert Lowering.commit_message("run-test-1", 7) == "Foreman run run-test-1 phase 7"
    end

    test "commit: false defers and an absent key does not" do
      steps =
        lower!([
          %{"name" => "p1", "prompt" => "one", "commit" => false},
          %{"name" => "p2", "prompt" => "two"}
        ])

      assert [true, false] =
               steps |> Enum.filter(&(&1.kind == :commit)) |> Enum.map(& &1.opts.defer?)
    end
  end

  describe "gate step" do
    test "required_file lowers to a gate between the agent and the commit carrying the key" do
      steps =
        lower!([%{"name" => "p1", "prompt" => "do work", "required_file" => "planning.prd_path"}])

      assert [:worktree, :agent, :gate, :commit] = kinds(steps)
      assert %Step{opts: %{key: "planning.prd_path"}} = Enum.find(steps, &(&1.kind == :gate))
    end

    test "a blank required_file still lowers, so the gate can reject it rather than it vanishing" do
      steps = lower!([%{"name" => "p1", "prompt" => "do work", "required_file" => ""}])

      assert :gate in kinds(steps)
    end
  end

  describe "refused phases" do
    test "a bash phase is refused before any step is built, naming the phase and the reason" do
      phase_specs =
        PhaseSpec.normalize_all([
          %{"name" => "ok", "prompt" => "fine"},
          %{"name" => "shell", "bash" => "echo hi"}
        ])

      assert {:error, %Error{code: :unsupported_phase_action, details: details}} =
               Lowering.lower(phase_specs, ctx())

      assert details.index == 1
      assert details.reason == {:unsupported_phase_action, :bash}
    end

    test "a command phase with no command is refused with the executor's own reason" do
      phase_specs = [%{name: "empty", action: :command, command: ""}]

      assert {:error, %Error{details: %{index: 0, reason: {:invalid_phase_command, "empty"}}}} =
               Lowering.lower(phase_specs, ctx())
    end

    test "a phase before start_index is not validated" do
      phase_specs =
        PhaseSpec.normalize_all([
          %{"name" => "shell", "bash" => "echo hi"},
          %{"name" => "ok", "prompt" => "fine"}
        ])

      assert {:ok, %Program{}} = Lowering.lower(phase_specs, ctx(%{start_index: 1}))
    end
  end
end
