defmodule ForemanServer.Workflow.InterpreterTest do
  use ExUnit.Case, async: false

  @template_names ~w(discover assess plan implement implement-trd implement-trd-beads verify release)

  test "load!/1 loads each bundled workflow template" do
    Enum.each(@template_names, fn template_name ->
      path = Application.app_dir(:foreman_server, "priv/defaults/workflows/#{template_name}.yaml")

      assert {:ok, workflow} = Workflow.Interpreter.load!(path)
      assert workflow["name"] == template_name
      assert is_binary(workflow["description"])
      assert is_list(workflow["phases"])

      assert Enum.any?(workflow["phases"], fn phase ->
               is_map(phase) and is_binary(phase["name"]) and phase["name"] != ""
             end)
    end)
  end

  test "load!/1 raises when phases are missing" do
    path = write_temp_yaml!("name: broken\ndescription: phases missing\n")

    assert_raise Workflow.MissingRequiredPhaseError,
                 ~r/must define top-level keys \"name\" and \"phases\"/,
                 fn ->
                   Workflow.Interpreter.load!(path)
                 end
  end

  test "load!/1 raises when no phase has a name" do
    path = write_temp_yaml!("name: nameless\nphases:\n  - prompt: discover.md\n")

    assert_raise Workflow.MissingRequiredPhaseError,
                 ~r/at least one phase entry with a \"name\" key/,
                 fn ->
                   Workflow.Interpreter.load!(path)
                 end
  end

  test "load!/1 raises when a phase defines no action" do
    path = write_temp_yaml!("name: empty-action\nphases:\n  - name: only\n")

    assert_raise Workflow.MissingRequiredPhaseError,
                 ~r/must define exactly one of: prompt, command, bash/,
                 fn ->
                   Workflow.Interpreter.load!(path)
                 end
  end

  test "load!/1 raises when a phase defines two actions" do
    path =
      write_temp_yaml!("""
      name: dual-action
      phases:
        - name: only
          prompt: discover.md
          command: "/skill:x"
      """)

    assert_raise Workflow.MissingRequiredPhaseError,
                 ~r/must define exactly one of: prompt, command, bash \(found 2\)/,
                 fn ->
                   Workflow.Interpreter.load!(path)
                 end
  end

  test "load!/1 accepts a command: phase with a leading slash and requiredFile" do
    path =
      write_temp_yaml!("""
      name: command-only
      phases:
        - name: create-prd
          command: "/skill:ensemble-full-create-prd --foreman"
          requiredFile: planning.prd_path
      """)

    assert {:ok, workflow} = Workflow.Interpreter.load!(path)

    [phase] = workflow["phases"]
    assert phase["name"] == "create-prd"
    assert phase["command"] == "/skill:ensemble-full-create-prd --foreman"
    assert phase["requiredFile"] == "planning.prd_path"
  end

  test "load!/1 rejects a command: phase without a leading slash" do
    path =
      write_temp_yaml!("""
      name: bad-command
      phases:
        - name: only
          command: "skill:ensemble-full-create-prd"
      """)

    assert_raise Workflow.MissingRequiredPhaseError,
                 ~r/\"command\" must be a non-empty slash invocation beginning with \"\/\"/,
                 fn ->
                   Workflow.Interpreter.load!(path)
                 end
  end

  test "load!/1 rejects an empty command: value" do
    path =
      write_temp_yaml!("""
      name: empty-command
      phases:
        - name: only
          command: ""
      """)

    assert_raise Workflow.MissingRequiredPhaseError,
                 ~r/must define exactly one of: prompt, command, bash/,
                 fn ->
                   Workflow.Interpreter.load!(path)
                 end
  end

  test "load!/1 accepts a bash: phase syntactically" do
    path =
      write_temp_yaml!("""
      name: bash-phase
      phases:
        - name: only
          bash: "echo hello"
      """)

    assert {:ok, _workflow} = Workflow.Interpreter.load!(path)
  end

  test "load!/1 rejects a non-mapping phase entry at the parser level" do
    path = write_temp_yaml!("name: bad-shape\nphases:\n  - \"not-a-map\"\n")

    assert_raise ArgumentError, ~r/not-a-map/, fn ->
      Workflow.Interpreter.load!(path)
    end
  end

  test "load!/1 rejects a malformed requiredFile dotted key" do
    path =
      write_temp_yaml!("""
      name: bad-required-file
      phases:
        - name: only
          command: "/skill:x"
          requiredFile: "planning..prd_path"
      """)

    assert_raise Workflow.MissingRequiredPhaseError,
                 ~r/\"requiredFile\" must be a non-empty dotted context key/,
                 fn ->
                   Workflow.Interpreter.load!(path)
                 end
  end

  test "load!/1 rejects an empty requiredFile value" do
    path =
      write_temp_yaml!("""
      name: empty-required-file
      phases:
        - name: only
          command: "/skill:x"
          requiredFile: ""
      """)

    assert_raise Workflow.MissingRequiredPhaseError,
                 ~r/\"requiredFile\" must be a non-empty dotted context key/,
                 fn ->
                   Workflow.Interpreter.load!(path)
                 end
  end

  describe "worktree validation" do
    test "accepts a phase without a worktree block (legacy compatible)" do
      path =
        write_temp_yaml!("""
        name: legacy
        phases:
          - name: only
            command: "/skill:x"
        """)

      assert {:ok, workflow} = Workflow.Interpreter.load!(path)
      refute Map.has_key?(hd(workflow["phases"]), "worktree")
    end

    test "refuses a relocated phase-level worktree block instead of dropping it" do
      # `worktree:` moved from phase level to workflow level. `PhaseSpec` drops
      # keys it does not know, so this manifest used to parse and silently lose
      # the opt-out — then take the DEFAULT-ON worktree path, inverting an
      # explicit refusal to provision into provisioning. A relocated key is
      # malformed, not unknown, so it gets its own loud error (AGENTS.md 5.3).
      path =
        write_temp_yaml!("""
        name: legacy-phase-worktree
        description: pre-move manifest
        phases:
          - name: only
            command: "/skill:x"
            worktree:
              enabled: false
        """)

      assert_raise Workflow.MissingRequiredPhaseError,
                   ~r/phase 1 declares a phase-level \"worktree\" block/,
                   fn -> Workflow.Interpreter.load!(path) end
    end

    test "a blank top-level key stays a blank scalar and still fails validation" do
      # Teaching the root parser to nest made EVERY valueless top-level key
      # nest, so `name:` parsed as `%{}`. `missing_or_blank?/1` answers true for
      # `""` but false for `%{}`, so a blank required key passed validation and
      # `name: %{}` propagated into the frozen workflow_snapshot. Nest only when
      # an indented child actually follows.
      path =
        write_temp_yaml!("""
        name:
        description: blank name
        phases:
          - name: only
            command: "/skill:x"
        """)

      assert_raise Workflow.MissingRequiredPhaseError,
                   ~r/must define top-level keys \"name\" and \"phases\"/,
                   fn -> Workflow.Interpreter.load!(path) end
    end

    test "refuses an unrecognized worktree key instead of dropping it" do
      # `WorktreeSpec.normalize/1` keeps only recognized keys, so a misspelling
      # used to validate, get dropped, and hand the executor a spec saying
      # nothing — provisioning the DEFAULT-ON worktree for a manifest that
      # plainly asked for none. A typo must not be a silent behavior change.
      path =
        write_temp_yaml!("""
        name: typo
        description: misspelled key
        worktree:
          enabeld: false
        phases:
          - name: only
            command: "/skill:x"
        """)

      assert_raise Workflow.MissingRequiredPhaseError,
                   ~r/unrecognized key \"enabeld\"/,
                   fn -> Workflow.Interpreter.load!(path) end
    end

    test "parses a top-level nested mapping into a string-keyed map" do
      # The workflow-level `worktree:` block only works because the root parser
      # learned to nest. Previously only `phases:` could introduce a nested
      # mapping, so `worktree:` parsed as the empty string and its own indented
      # lines were left unconsumed. Nothing covered that, so pin the parse
      # result verbatim: the block reaches Catalog/Approval raw and
      # string-keyed.
      path =
        write_temp_yaml!("""
        name: wt-toplevel
        description: workflow-level worktree block
        worktree:
          enabled: true
          base: "{{implementation.source_revision}}"
          branch: foreman/{task_id}/{run_id}
          path: workspace
          cleanup: never
        phases:
          - name: only
            command: "/skill:x"
        """)

      assert {:ok, workflow} = Workflow.Interpreter.load!(path)

      assert workflow["worktree"] == %{
               "enabled" => true,
               "base" => "{{implementation.source_revision}}",
               "branch" => "foreman/{task_id}/{run_id}",
               "path" => "workspace",
               "cleanup" => "never"
             }

      assert workflow["phases"] == [%{"name" => "only", "command" => "/skill:x"}]
    end

    test "accepts a partial worktree block (absent keys keep their defaults)" do
      path =
        write_temp_yaml!("""
        name: wt-default
        worktree:
          base: main
        phases:
          - name: only
            command: "/skill:x"
        """)

      assert {:ok, _workflow} = Workflow.Interpreter.load!(path)
    end

    test "accepts worktree with all valid fields" do
      path =
        write_temp_yaml!("""
        name: wt-full
        worktree:
          enabled: true
          base: main
          branch: feature/x
          path: implement
          cleanup: always
        phases:
          - name: only
            command: "/skill:x"
        """)

      assert {:ok, _workflow} = Workflow.Interpreter.load!(path)
    end

    test "accepts enabled: false (other fields must still validate)" do
      path =
        write_temp_yaml!("""
        name: wt-disabled
        worktree:
          enabled: false
        phases:
          - name: only
            command: "/skill:x"
        """)

      assert {:ok, _workflow} = Workflow.Interpreter.load!(path)
    end

    test "rejects absolute path even when enabled: false" do
      path =
        write_temp_yaml!("""
        name: wt-disabled-abs
        worktree:
          enabled: false
          path: /abs/should/be/rejected
        phases:
          - name: only
            command: "/skill:x"
        """)

      assert_raise Workflow.MissingRequiredPhaseError,
                   ~r/\"worktree\.path\" must be relative \(absolute paths rejected\)/,
                   fn -> Workflow.Interpreter.load!(path) end
    end

    test "rejects non-boolean enabled" do
      path =
        write_temp_yaml!("""
        name: wt-enabled-bad
        worktree:
          enabled: maybe
        phases:
          - name: only
            command: "/skill:x"
        """)

      error =
        assert_raise Workflow.MissingRequiredPhaseError,
                     ~r/\"worktree\.enabled\" must be a boolean/,
                     fn -> Workflow.Interpreter.load!(path) end

      # The block is validated ONCE at workflow level, so the message must not
      # blame a phase. It used to be validated per phase and name an index,
      # which pointed operators at the wrong part of the manifest.
      refute error.message =~ "phase"
    end

    test "rejects blank base" do
      path =
        write_temp_yaml!("""
        name: wt-blank-base
        worktree:
          base: ""
        phases:
          - name: only
            command: "/skill:x"
        """)

      assert_raise Workflow.MissingRequiredPhaseError,
                   ~r/\"worktree\.base\" must be a non-empty string/,
                   fn -> Workflow.Interpreter.load!(path) end
    end

    test "rejects absolute path" do
      path =
        write_temp_yaml!("""
        name: wt-abs
        worktree:
          path: /tmp/abs
        phases:
          - name: only
            command: "/skill:x"
        """)

      assert_raise Workflow.MissingRequiredPhaseError,
                   ~r/\"worktree\.path\" must be relative \(absolute paths rejected\)/,
                   fn -> Workflow.Interpreter.load!(path) end
    end

    test "rejects path with .. traversal" do
      path =
        write_temp_yaml!("""
        name: wt-traverse
        worktree:
          path: ../escape
        phases:
          - name: only
            command: "/skill:x"
        """)

      assert_raise Workflow.MissingRequiredPhaseError,
                   ~r/\"worktree\.path\" must not contain "\.\." traversal/,
                   fn -> Workflow.Interpreter.load!(path) end
    end

    test "rejects invalid cleanup enum value" do
      path =
        write_temp_yaml!("""
        name: wt-cleanup
        worktree:
          cleanup: sometimes
        phases:
          - name: only
            command: "/skill:x"
        """)

      assert_raise Workflow.MissingRequiredPhaseError,
                   ~r/\"worktree\.cleanup\" must be one of: always, never, on_success/,
                   fn -> Workflow.Interpreter.load!(path) end
    end

    test "accepts cleanup: never" do
      path =
        write_temp_yaml!("""
        name: wt-never
        worktree:
          cleanup: never
        phases:
          - name: only
            command: "/skill:x"
        """)

      assert {:ok, _workflow} = Workflow.Interpreter.load!(path)
    end

    test "accepts cleanup: on_success" do
      # `on_success` is the third legal value and reclaims the worktree only on
      # a successful finalize. It was schema-legal from the start but the
      # executor collapsed it into `always`, so nothing asserted the schema
      # accepted it.
      path =
        write_temp_yaml!("""
        name: wt-on-success
        worktree:
          cleanup: on_success
        phases:
          - name: only
            command: "/skill:x"
        """)

      assert {:ok, workflow} = Workflow.Interpreter.load!(path)
      assert workflow["worktree"]["cleanup"] == "on_success"
    end
  end

  # `commit:` is phase-level (a run has one worktree, but each phase produces
  # its own output). ONE invariant is validated statically: work that no later
  # phase commits is unproposable, and that is decidable from the manifest
  # alone. A second refusal — a `requiredFile:` phase reached with work
  # pending — used to live here and was deleted; see the test below that pins
  # the manifest now loading.
  describe "phase commit validation" do
    defp commit_manifest(phases) do
      body =
        phases
        |> Enum.map(fn {name, extra} ->
          "  - name: #{name}\n    command: \"/skill:s-#{name}\"\n#{extra}"
        end)
        |> Enum.join()

      write_temp_yaml!("name: c\ndescription: d\nphases:\n" <> body)
    end

    test "accepts an explicit commit: true" do
      path = commit_manifest([{"a", "    commit: true\n"}])

      assert {:ok, workflow} = Workflow.Interpreter.load!(path)
      assert hd(workflow["phases"])["commit"] == true
    end

    test "accepts a positive integer timeout_minutes" do
      path = commit_manifest([{"a", "    timeout_minutes: 15\n"}])

      assert {:ok, workflow} = Workflow.Interpreter.load!(path)
      assert hd(workflow["phases"])["timeout_minutes"] == 15
    end

    test "accepts camelCase timeoutMinutes" do
      path = commit_manifest([{"a", "    timeoutMinutes: 20\n"}])

      assert {:ok, workflow} = Workflow.Interpreter.load!(path)
      assert hd(workflow["phases"])["timeoutMinutes"] == 20
    end

    test "rejects non-positive and non-integer timeout_minutes values" do
      for value <- ["0", "-1", "later", "\"15\"", "false"] do
        path = commit_manifest([{"a", "    timeout_minutes: #{value}\n"}])

        assert_raise Workflow.MissingRequiredPhaseError,
                     ~r/phase 0 "timeout_minutes" must be a positive integer number of minutes/,
                     fn -> Workflow.Interpreter.load!(path) end
      end
    end

    test "accepts an absent commit key and does not synthesize one" do
      # Absent must stay absent through the parser: the default lives in
      # `RunExecutor.phase_commits?/1`, and injecting `true` here would make
      # "declared nothing" indistinguishable from "declared the default".
      path = commit_manifest([{"a", ""}])

      assert {:ok, workflow} = Workflow.Interpreter.load!(path)
      refute Map.has_key?(hd(workflow["phases"]), "commit")
    end

    test "casts commit to a real boolean, not the string \"false\"" do
      # `false` must survive as a boolean through the YAML parse AND the JSON
      # round-trip the workflow snapshot performs. A string \"false\" would be
      # truthy at every downstream read.
      path = commit_manifest([{"a", "    commit: false\n"}, {"b", "    commit: true\n"}])

      assert {:ok, workflow} = Workflow.Interpreter.load!(path)
      assert hd(workflow["phases"])["commit"] === false
    end

    test "rejects a non-boolean commit value" do
      path = commit_manifest([{"a", "    commit: maybe\n"}])

      assert_raise Workflow.MissingRequiredPhaseError,
                   ~r/phase 0 \"commit\" must be a boolean/,
                   fn -> Workflow.Interpreter.load!(path) end
    end

    test "rejects a QUOTED commit: \"false\" rather than coercing it" do
      # The dangerous case, because YAML makes it look intentional and every
      # downstream read of the string "false" is truthy — the phase would
      # commit while the manifest says it defers. Malformed must be refused,
      # never mapped onto a plausible default (AGENTS.md 5.3).
      path = commit_manifest([{"a", "    commit: \"false\"\n"}])

      assert_raise Workflow.MissingRequiredPhaseError,
                   ~r/phase 0 \"commit\" must be a boolean/,
                   fn -> Workflow.Interpreter.load!(path) end
    end

    test "rejects a quoted commit: \"true\" on the same grounds" do
      path = commit_manifest([{"a", "    commit: \"true\"\n"}])

      assert_raise Workflow.MissingRequiredPhaseError,
                   ~r/phase 0 \"commit\" must be a boolean/,
                   fn -> Workflow.Interpreter.load!(path) end
    end

    test "accepts stack_pr true and false without conflating commit" do
      path =
        commit_manifest([
          {"a", "    commit: false\n    stack_pr: true\n"},
          {"b", "    stack_pr: false\n"}
        ])

      assert {:ok, workflow} = Workflow.Interpreter.load!(path)
      [first, second] = workflow["phases"]
      assert first["commit"] == false
      assert first["stack_pr"] == true
      assert second["stack_pr"] == false
    end

    test "rejects malformed stack_pr values" do
      for value <- ["maybe", "\"true\"", "123"] do
        path = commit_manifest([{"a", "    stack_pr: #{value}\n"}])

        assert_raise Workflow.MissingRequiredPhaseError,
                     ~r/phase 0 \"stack_pr\" must be a boolean/,
                     fn -> Workflow.Interpreter.load!(path) end
      end
    end

    test "rejects mapped stack_pr values" do
      path = commit_manifest([{"a", "    stack_pr:\n      nested: true\n"}])

      assert_raise Workflow.MissingRequiredPhaseError,
                   ~r/phase 0 \"stack_pr\" must be a boolean/,
                   fn -> Workflow.Interpreter.load!(path) end
    end

    test "a declared commit value reaches the executor's phase_commits?/1" do
      # Pins the declaration end-to-end: parsing a boolean is worthless if the
      # value the executor reads disagrees with it. MUST go through
      # `PhaseSpec.normalize/1` — `phase_commits?/1` reads the ATOM `:commit`,
      # so handing it a raw string-keyed manifest phase yields nil for every
      # input and the test passes vacuously.
      path = commit_manifest([{"a", "    commit: false\n"}, {"b", "    commit: true\n"}])

      assert {:ok, workflow} = Workflow.Interpreter.load!(path)

      [deferring, committing] =
        Enum.map(workflow["phases"], &ForemanServer.Workflow.PhaseSpec.normalize/1)

      refute ForemanServer.Workflow.RunExecutor.__phase_commits_for_test__(deferring)
      assert ForemanServer.Workflow.RunExecutor.__phase_commits_for_test__(committing)
    end

    test "an absent commit key reaches phase_commits?/1 as committing" do
      # The other half of absent-is-not-false: no :commit key at all, and the
      # phase still commits.
      path = commit_manifest([{"a", ""}])

      spec = ForemanServer.Workflow.PhaseSpec.normalize(hd(workflow_phases(path)))
      refute Map.has_key?(spec, :commit)
      assert ForemanServer.Workflow.RunExecutor.__phase_commits_for_test__(spec)
    end

    defp workflow_phases(path) do
      assert {:ok, workflow} = Workflow.Interpreter.load!(path)
      workflow["phases"]
    end

    test "accepts deferred work that no later phase commits, under the default cleanup" do
      # This test previously asserted the OPPOSITE: any never-committed deferral
      # was refused at load, on the grounds that AutoPR gates on
      # `git rev-list --count base..head` and so cannot propose uncommitted work.
      # That consequence is real, but it is not a reason to refuse the manifest —
      # it conflated an operator mistake with a workflow that deliberately stages
      # changes in a retained worktree for human review, and made the latter
      # inexpressible.
      #
      # The refusal now fires only when cleanup would DESTROY the deferred work
      # (see CommitCleanupValidationTest); when the worktree is retained, the
      # run-terminal warning in CommitWarningTest makes the absent PR
      # attributable instead. Absent `cleanup:` is `never`, so this manifest is
      # the retained case.
      path = commit_manifest([{"a", "    commit: false\n"}])

      assert {:ok, workflow} = Workflow.Interpreter.load!(path)
      assert workflow["phases"] |> hd() |> Map.get("commit") == false
    end

    test "accepts a requiredFile phase reached with work still pending" do
      # This manifest was REFUSED at load until the `commit:` tag was reconciled
      # to its PRD, on the theory that discovery would mis-attribute phase 0's
      # uncommitted document to phase 1. The refusal was deleted because it made
      # deferral and discovery mutually exclusive, forbidding exactly the
      # batching the tag exists to provide — deferring the phase immediately
      # before a gated phase is the shape the plan and prd workflows want.
      #
      # Mis-attribution remains a property of what discovery SCOPES; it is not
      # something a load-time veto on manifest shape can fix, and treating the
      # operator's declared intent as a defect was the wrong trade.
      path =
        commit_manifest([
          {"a", "    commit: false\n"},
          {"b", "    requiredFile: planning.prd_path\n    commit: true\n"}
        ])

      assert {:ok, workflow} = Workflow.Interpreter.load!(path)
      assert length(workflow["phases"]) == 2
    end

    test "accepts deferral absorbed by a later phase" do
      path = commit_manifest([{"a", "    commit: false\n"}, {"b", "    commit: true\n"}])

      assert {:ok, _workflow} = Workflow.Interpreter.load!(path)
    end

    test "accepts a requiredFile phase once an intervening phase has committed" do
      # The pending flag must CLEAR, not latch: phase 1's commit absorbs phase
      # 0's deferred work, so phase 2's gate starts from a clean tree and is
      # honest. A latching implementation would reject this valid manifest.
      path =
        commit_manifest([
          {"a", "    commit: false\n"},
          {"b", "    commit: true\n"},
          {"c", "    requiredFile: planning.prd_path\n"}
        ])

      assert {:ok, _workflow} = Workflow.Interpreter.load!(path)
    end
  end

  defp write_temp_yaml!(contents) do
    directory =
      Path.join(System.tmp_dir!(), "workflow-interpreter-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)

    path = Path.join(directory, "workflow.yaml")
    File.write!(path, contents)
    path
  end
end
