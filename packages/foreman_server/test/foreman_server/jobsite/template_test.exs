defmodule ForemanServer.Jobsite.TemplateTest do
  # `Template.generate/2` turns a prompt into a runnable remote-jobsite script. Every assertion
  # about "the server would accept this" is made by the REAL `Jobsite.Spec.from_json/2` against a
  # registered project: there is no second copy of the whitelist in this file or in the generator.
  use ExUnit.Case, async: false
  use ExUnitProperties

  import ExUnit.CaptureIO

  alias ForemanServer.Jobsite.{Error, Spec, Template}
  alias ForemanServer.Jobsite.Template.{Feature, GeneratedFile}
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @project_id "tpl-project"
  @model_project_id "tpl-model-project"
  @repo_path "/srv/repos/tpl-project"
  @signal "<promise>COMPLETE</promise>"

  # The client package a generated script loads. Read as source: this app does not depend on it.
  @client_source Path.expand("../../../../foreman_client/lib/foreman/client.ex", __DIR__)

  setup do
    ProjectionStoreReset.reset!()

    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "ProjectRegistered",
                 payload: %{project_id: @project_id, path: @repo_path}
               },
               %{
                 event_type: "ProjectRegistered",
                 payload: %{
                   project_id: @model_project_id,
                   path: "/srv/repos/tpl-model-project",
                   config: %{thread_model: "project-model"}
                 }
               }
             ])

    on_exit(fn -> ProjectionStoreReset.reset!() end)
    :ok
  end

  defp request(extra \\ %{}) do
    Map.merge(
      %{
        "project_id" => @project_id,
        "prompt" => "Rename the config loader in the parser module.",
        "agent" => %{"provider" => "claude", "model" => "sonnet"}
      },
      extra
    )
  end

  defp generate!(params, opts \\ []) do
    assert {:ok, %Template{} = template} = Template.generate(params, opts)
    template
  end

  defp file!(%Template{files: files}, path) do
    assert %GeneratedFile{content: content} = Enum.find(files, &(&1.path == path))
    content
  end

  defp script!(%Template{name: name} = template), do: file!(template, name <> ".exs")
  defp prompt!(%Template{name: name} = template), do: file!(template, "prompts/" <> name <> ".md")

  defp assert_error(result, code) do
    assert {:error, %Error{code: ^code} = error} = result
    error
  end

  describe "a plain prompt" do
    test "is one agent turn on a named branch in the docker sandbox" do
      template = generate!(request())

      assert template.name == "rename-the-config-loader"
      assert template.features == []
      assert template.notes == []

      assert template.spec == %{
               "project_id" => @project_id,
               "name" => "rename-the-config-loader",
               "prompt" => "Rename the config loader in the parser module.\n",
               "agent" => %{
                 "provider" => "claude",
                 "model" => "sonnet",
                 "approval_mode" => "auto_approve"
               },
               "strategy" => %{"branch" => "agent/rename-the-config-loader"},
               "sandbox" => "docker"
             }

      assert Enum.map(template.files, & &1.path) == [
               "rename-the-config-loader.exs",
               "prompts/rename-the-config-loader.md"
             ]
    end

    test "the spec it carries is accepted by the real Jobsite.Spec.from_json/2" do
      template = generate!(request())
      assert {:ok, built} = Spec.from_json(template.spec)
      assert built[:project_id] == @project_id
      assert built[:repo_path] == @repo_path
    end

    test "the oracle can fail: from_json rejects a spec the generator would never emit" do
      template = generate!(request())

      assert {:error, %Error{code: :spec_forbidden_key}} =
               Spec.from_json(Map.put(template.spec, "repositories", ["/etc"]))

      assert {:error, %Error{code: :spec_push_requires_branch}} =
               template.spec
               |> Map.merge(%{"push" => true, "strategy" => "head"})
               |> Spec.from_json()
    end

    # `strategy: head` is a legal spec, not a whitelist violation (and `Docker.kind/0` is
    # `:bind_mount`, so the sandbox step does not refuse it either): never generating it is the
    # generator's own choice. The agent would edit the server's own checkout in place, with no
    # branch to review, merge or push, and no keyword in a prompt should choose that.
    test "strategy head is a legal spec, so never generating it is the generator's own choice" do
      head_spec = Map.put(generate!(request()).spec, "strategy", "head")

      assert {:ok, built} = Spec.from_json(head_spec)
      assert built[:strategy] == :head
      assert {ForemanServer.Jobsite.Sandboxes.Docker, _config} = built[:sandbox]

      assert_error(
        Template.generate(request(%{"strategy" => "head"})),
        :template_option_unsupported
      )
    end

    test "the prompt file is exactly the prompt the spec carries" do
      template = generate!(request())
      assert prompt!(template) == template.spec["prompt"]
      assert String.ends_with?(prompt!(template), "module.\n")
    end

    test "the same input yields the same output" do
      assert generate!(request()) == generate!(request())
    end

    test "trailing whitespace is normalised to one newline and nothing else is touched" do
      template = generate!(request(%{"prompt" => "  Indented first line\n\n  second\t\n\n\n"}))
      assert template.spec["prompt"] == "  Indented first line\n\n  second\n"
    end
  end

  describe "naming" do
    test "the name is a slug of the first words of the prompt and the branch follows it" do
      template =
        generate!(request(%{"prompt" => "Refactor: the HTTP/2 client, please! More text"}))

      assert template.name == "refactor-the-http-2"
      assert template.spec["strategy"] == %{"branch" => "agent/refactor-the-http-2"}
    end

    test "a prompt with nothing sluggable is named work" do
      assert generate!(request(%{"prompt" => "!!! ???"})).name == "work"
      assert generate!(request(%{"prompt" => "修复测试"})).name == "work"
    end

    test "a long first word is cut at 40 characters" do
      template = generate!(request(%{"prompt" => String.duplicate("a", 90)}))
      assert template.name == String.duplicate("a", 40)
    end

    test "an explicit name wins and the default branch is a slug of it" do
      template = generate!(request(%{"name" => "My_Job.v2"}))
      assert template.name == "My_Job.v2"
      assert template.spec["name"] == "My_Job.v2"
      assert template.spec["strategy"] == %{"branch" => "agent/my-job-v2"}
      assert Enum.map(template.files, & &1.path) == ["My_Job.v2.exs", "prompts/My_Job.v2.md"]
    end

    test "a name whose default branch would be invalid still yields a valid branch" do
      # `x.lock` is a legal name but `agent/x.lock` is not a legal branch.
      template = generate!(request(%{"name" => "x.lock"}))
      assert template.spec["strategy"] == %{"branch" => "agent/x-lock"}
    end

    test "a name that cannot be a file name is refused by the validator, not turned into a path" do
      for bad <- ["../escape", "a/b", "has space", "", ".hidden", String.duplicate("a", 129)] do
        assert_error(Template.generate(request(%{"name" => bad})), :spec_option_invalid)
      end
    end
  end

  describe "features read from the prompt" do
    test "loop and review-and-fix become an iteration budget with a completion signal" do
      template = generate!(request(%{"prompt" => "Loop until the failing test passes"}))

      assert template.features == ["loop", "review-and-fix"]
      assert template.spec["max_iterations"] == 5
      assert template.spec["completion_signal"] == @signal
    end

    test "the prompt file tells the agent how to end an iterating run" do
      template = generate!(request(%{"prompt" => "Keep going until every module compiles."}))
      prompt = prompt!(template)

      assert String.starts_with?(prompt, "Keep going until every module compiles.\n\n")
      assert String.ends_with?(prompt, "\n")
      assert prompt =~ @signal
      assert prompt == template.spec["prompt"]
    end

    test "a prompt that already names the signal is not given a second instruction" do
      own = "Fix it, loop as needed, and end with #{@signal} when done."
      template = generate!(request(%{"prompt" => own}))

      assert template.spec["completion_signal"] == @signal
      assert template.spec["prompt"] == own <> "\n"
    end

    test "a non-iterating prompt gets neither a budget nor a signal" do
      template = generate!(request())
      refute Map.has_key?(template.spec, "max_iterations")
      refute Map.has_key?(template.spec, "completion_signal")
      refute prompt!(template) =~ "promise"
    end

    test "publishing is inferred as push on the named branch" do
      template = generate!(request(%{"prompt" => "Add the endpoint, then push it"}))

      assert template.features == ["push-to-origin"]
      assert template.spec["push"] == true
      assert template.spec["strategy"] == %{"branch" => "agent/add-the-endpoint-then"}
    end

    test "working in place is a note, never strategy head" do
      template = generate!(request(%{"prompt" => "Tidy the module in place"}))

      assert template.features == ["work-in-place"]
      assert [note] = template.notes
      assert note =~ "head"
      assert template.spec["strategy"] == %{"branch" => "agent/tidy-the-module-in"}
      assert template.spec["sandbox"] == "docker"
    end

    test "what a remote spec cannot express is reported, not silently dropped" do
      cases = [
        {"session-resume", "Resume the session from yesterday and finish it"},
        {"fan-out", "Run this for each of the packages"},
        {"notify", "Fix it, then ping me when it is done"},
        {"cleanup", "Fix it and clean up the worktree afterwards"},
        {"artifact-gate", "Fix it; you must produce a report file"}
      ]

      for {id, prompt} <- cases do
        template = generate!(request(%{"prompt" => prompt}))
        assert template.features == [id], "#{id}: #{inspect(template.features)}"
        assert [note] = template.notes
        assert is_binary(note) and note != ""
        # A note changes nothing about the spec: the prompt alone decides these.
        refute Map.has_key?(template.spec, "max_iterations")
        refute Map.has_key?(template.spec, "push")
      end
    end

    test "Feature.read/1 matches what it should and nothing else" do
      ids = fn text -> text |> Feature.read() |> Enum.map(& &1.id) end

      assert ids.("loop over the modules") == ["loop"]
      assert ids.("retry on failure") == ["loop"]
      assert ids.("make the build green") == ["review-and-fix"]
      assert ids.("publish the branch") == ["push-to-origin"]
      assert ids.("open a PR for it") == ["push-to-origin"]
      assert ids.("without a new branch") == ["work-in-place"]
      assert ids.("Write a single pure function") == []
      # Word boundaries: these only contain a trigger as part of a longer word.
      assert ids.("add a loopback interface") == []
      assert ids.("see the pushover docs") == []
    end

    test "no pattern is quadratic on a hostile prompt" do
      # An unbounded `.*` after `write a` rescans the rest of the prompt for every occurrence.
      hostile = String.duplicate("write a ", 100_000)

      {micros, ids} = :timer.tc(fn -> hostile |> Feature.read() |> Enum.map(& &1.id) end)

      assert ids == []
      assert micros < 3_000_000
    end

    test "the host sandbox is never inferred from the prompt" do
      for prompt <- ["Run it directly on the host", "no sandbox please", "the host header bug"] do
        template = generate!(request(%{"prompt" => prompt}))
        assert template.spec["sandbox"] == "docker"
      end
    end
  end

  describe "explicit options win over the prompt" do
    test "max_iterations on its own turns a plain prompt into a loop with the default signal" do
      template = generate!(request(%{"max_iterations" => 8}))

      assert template.features == []
      assert template.spec["max_iterations"] == 8
      assert template.spec["completion_signal"] == @signal
      assert prompt!(template) =~ @signal
    end

    test "completion_signal on its own turns a plain prompt into a loop with the default budget" do
      template = generate!(request(%{"completion_signal" => "ALL-DONE"}))

      assert template.spec["max_iterations"] == 5
      assert template.spec["completion_signal"] == "ALL-DONE"
      assert prompt!(template) =~ "ALL-DONE"
      refute prompt!(template) =~ @signal
    end

    test "an explicit budget overrides the inferred one" do
      template = generate!(request(%{"prompt" => "Loop until green", "max_iterations" => 2}))
      assert template.spec["max_iterations"] == 2
      assert template.features == ["loop"]
    end

    test "push: false vetoes an inferred push and push: true adds one" do
      vetoed = generate!(request(%{"prompt" => "Fix it and push", "push" => false}))
      refute Map.has_key?(vetoed.spec, "push")
      assert vetoed.features == []

      added = generate!(request(%{"push" => true}))
      assert added.spec["push"] == true
      assert added.features == []
    end

    test "an explicit branch is kept even when the prompt infers a push" do
      template =
        generate!(
          request(%{"prompt" => "Fix it and push", "strategy" => %{"branch" => "feat/x"}})
        )

      assert template.spec["strategy"] == %{"branch" => "feat/x"}
      assert template.spec["push"] == true
    end

    test "agent provider and model are taken as given and never defaulted" do
      template = generate!(request(%{"agent" => %{"provider" => "pi", "model" => "minimax"}}))

      assert template.spec["agent"] == %{
               "provider" => "pi",
               "model" => "minimax",
               "approval_mode" => "auto_approve"
             }
    end

    test "with no model the project's thread_model decides and the spec does not name one" do
      template =
        generate!(
          request(%{
            "project_id" => @model_project_id,
            "agent" => %{"provider" => "claude"}
          })
        )

      assert template.spec["agent"] == %{
               "provider" => "claude",
               "approval_mode" => "auto_approve"
             }

      assert {:ok, built} = Spec.from_json(template.spec)
      assert built[:agent].model == "project-model"
    end

    test "the host sandbox is available only as an explicit choice the server allows" do
      assert_error(
        Template.generate(request(%{"sandbox" => "host"})),
        :spec_sandbox_not_allowed
      )

      template = generate!(request(%{"sandbox" => "host"}), allow_host_sandbox: true)
      assert template.spec["sandbox"] == "host"
      assert script!(template) =~ "allow_host_sandbox"
    end
  end

  describe "the real validator is the only judge" do
    test "an unknown project is not generated for" do
      assert_error(
        Template.generate(request(%{"project_id" => "nobody"})),
        :spec_project_not_found
      )
    end

    test "missing and malformed required input is named by the validator's own codes" do
      assert_error(
        Template.generate(Map.delete(request(), "project_id")),
        :spec_project_id_missing
      )

      assert_error(Template.generate(Map.delete(request(), "prompt")), :spec_prompt_missing)
      assert_error(Template.generate(request(%{"prompt" => 5})), :spec_prompt_invalid)
      assert_error(Template.generate(request(%{"prompt" => "   \n"})), :spec_prompt_invalid)
      assert_error(Template.generate(request(%{"project_id" => 5})), :spec_project_id_invalid)
      assert_error(Template.generate("not a map"), :spec_invalid)
    end

    test "a blank prompt is not rescued by the completion instruction" do
      assert_error(
        Template.generate(request(%{"prompt" => "  ", "max_iterations" => 3})),
        :spec_prompt_invalid
      )
    end

    test "provider is required and must be registered; model is required without a project default" do
      assert_error(
        Template.generate(request(%{"agent" => %{"model" => "m"}})),
        :spec_provider_invalid
      )

      assert_error(
        Template.generate(request(%{"agent" => %{"provider" => "gpt", "model" => "m"}})),
        :spec_provider_invalid
      )

      assert_error(Template.generate(Map.delete(request(), "agent")), :spec_provider_invalid)

      assert_error(
        Template.generate(request(%{"agent" => %{"provider" => "claude"}})),
        :spec_agent_invalid
      )

      assert_error(Template.generate(request(%{"agent" => "claude"})), :spec_agent_invalid)
    end

    test "numeric, boolean, branch and sandbox values are judged by the whitelist" do
      for bad <- [0, -1, "3", 1.5, nil] do
        assert_error(
          Template.generate(request(%{"max_iterations" => bad})),
          :spec_option_invalid
        )
      end

      assert_error(Template.generate(request(%{"completion_signal" => ""})), :spec_option_invalid)
      assert_error(Template.generate(request(%{"push" => "yes"})), :spec_option_invalid)
      assert_error(Template.generate(request(%{"sandbox" => "podman"})), :spec_sandbox_invalid)

      for bad <- ["a..b", "-lead", "trail.", "x.lock", "has space", 5] do
        assert_error(
          Template.generate(request(%{"strategy" => %{"branch" => bad}})),
          :spec_strategy_invalid
        )
      end
    end

    test "options the generator does not set are refused by name, whatever the whitelist says" do
      for {key, value} <- [
            {"hooks", %{"sandbox" => %{"on_sandbox_ready" => [%{"command" => "make"}]}}},
            {"repositories", ["/etc"]},
            {"repo_path", "/etc"},
            {"bead_id", "foreman-1"},
            {"resume_session", "abc"},
            {"idle_timeout_seconds", 60},
            {"exclude_paths", ["docs"]},
            {"bogus", 1},
            {"strategy", "head"},
            {"strategy", %{"type" => "head"}},
            {"strategy", %{"branch" => "a", "extra" => 1}}
          ] do
        error =
          assert_error(Template.generate(request(%{key => value})), :template_option_unsupported)

        assert error.message =~ key
      end

      for {agent_key, value} <- [
            {"env", %{"A" => "b"}},
            {"effort", "high"},
            {"approval_mode", "default"}
          ] do
        agent = %{"provider" => "claude", "model" => "m", agent_key => value}

        error =
          assert_error(
            Template.generate(request(%{"agent" => agent})),
            :template_option_unsupported
          )

        assert error.message =~ agent_key
      end
    end

    test "an agent.env value can never reach a generated file" do
      secret = "sk-live-0123456789"
      agent = %{"provider" => "claude", "model" => "m", "env" => %{"ANTHROPIC_API_KEY" => secret}}

      assert {:error, %Error{code: :template_option_unsupported} = error} =
               Template.generate(request(%{"agent" => agent}),
                 agent_env_allowlist: ["ANTHROPIC_API_KEY"]
               )

      refute inspect(error) =~ secret
    end

    property "whatever it is given, it returns a typed error or a spec the real validator accepts" do
      check all(
              params <- params_gen(),
              max_runs: 150
            ) do
        case Template.generate(params, allow_host_sandbox: true) do
          {:error, %Error{code: code}} when is_atom(code) ->
            :ok

          {:ok, %Template{} = template} ->
            assert {:ok, _built} = Spec.from_json(template.spec, allow_host_sandbox: true)
            assert prompt!(template) == template.spec["prompt"]
            assert {:ok, _ast} = Code.string_to_quoted(script!(template))
        end
      end
    end

    test "the property is not vacuous: its generator reaches both outcomes often" do
      accepted =
        params_gen()
        |> Enum.take(200)
        |> Enum.map(&match?({:ok, _}, Template.generate(&1, allow_host_sandbox: true)))

      assert Enum.count(accepted, & &1) > 60
      assert Enum.count(accepted, &(not &1)) > 10
    end
  end

  describe "the generated script" do
    test "parses and calls only what the real Foreman.Client exports" do
      script = script!(generate!(request(%{"prompt" => "Loop until green, then push"})))

      assert {:ok, ast} = Code.string_to_quoted(script)
      calls = client_calls(ast)

      assert {:new, 0} in calls
      assert {:run, 2} in calls
      assert missing_client_calls(calls) == []
    end

    test "the export check can fail: the calls the archived prototype generated do not exist" do
      prototype = ~S"""
      client = Foreman.Client.new()

      case Foreman.Client.start_jobsite(client, spec) do
        {:ok, response} ->
          stream = Foreman.Client.stream_events(client, response["id"])
          Foreman.Client.get_jobsite(client, response["id"])
      end
      """

      assert {:ok, ast} = Code.string_to_quoted(prototype)

      assert missing_client_calls(client_calls(ast)) ==
               [get_jobsite: 2, start_jobsite: 2, stream_events: 2]
    end

    test "its spec literal evaluates to exactly the validated spec" do
      template =
        generate!(
          request(%{
            "prompt" => "Loop until green and push it",
            "completion_signal" => ~S|done #{raise "boom"} "quoted" \ back|,
            "agent" => %{"provider" => "pi", "model" => ~S|m"; System.halt(1); "#{raise "x"}|}
          })
        )

      assert evaluate_spec_literal(template) == template.spec
    end

    test "a hostile prompt travels only in the prompt file, byte for byte" do
      hostile =
        "Say \"\"\" and '''\n#!/bin/sh \#{System.halt(1)} \\n \\\\ \r\n tab\t end \u2028 \e[31m ünïcode ✓"

      template = generate!(request(%{"prompt" => hostile}))

      assert prompt!(template) == String.trim_trailing(hostile) <> "\n"
      refute script!(template) =~ "System.halt(1) "
      assert {:ok, _ast} = Code.string_to_quoted(script!(template))
      assert evaluate_spec_literal(template) == template.spec
    end

    test "run against a stand-in client it starts exactly the validated spec" do
      template = generate!(request(%{"prompt" => "Loop until green"}))
      env = %{"FOREMAN_PROJECT_ID" => @project_id, "FOREMAN_AGENT_ENV" => nil}

      output = run_script(template, env)

      assert_received {:fake_client_new, []}
      assert_received {:fake_client_run, sent}
      assert sent == template.spec
      assert output =~ "status=completed"
    end

    test "FOREMAN_AGENT_ENV names shell variables that become agent.env at run time" do
      template = generate!(request())

      env = %{
        "FOREMAN_PROJECT_ID" => "p-from-env",
        "FOREMAN_AGENT_ENV" => "TPL_TEST_TOKEN, TPL_TEST_BASE",
        "TPL_TEST_TOKEN" => "t0ken",
        "TPL_TEST_BASE" => "http://llm"
      }

      run_script(template, env)

      assert_received {:fake_client_run, sent}
      assert sent["project_id"] == "p-from-env"

      assert sent["agent"]["env"] == %{
               "TPL_TEST_TOKEN" => "t0ken",
               "TPL_TEST_BASE" => "http://llm"
             }

      assert Map.delete(sent["agent"], "env") == template.spec["agent"]

      assert Map.drop(sent, ["project_id", "agent"]) ==
               Map.drop(template.spec, ["project_id", "agent"])
    end

    test "an unset FOREMAN_PROJECT_ID stops the script before it contacts the server" do
      template = generate!(request())

      assert_raise RuntimeError, ~r/FOREMAN_PROJECT_ID/, fn ->
        run_script(template, %{"FOREMAN_PROJECT_ID" => nil, "FOREMAN_AGENT_ENV" => nil})
      end

      refute_received {:fake_client_run, _}
    end

    test "the header lists every inferred feature and note, and the runtime gates the script needs" do
      template =
        generate!(
          request(%{"prompt" => "Loop until green, push it, and ping me", "sandbox" => "host"}),
          allow_host_sandbox: true
        )

      script = script!(template)

      for id <- template.features, do: assert(script =~ "feature #{id}")
      for note <- template.notes, do: assert(script =~ note)
      assert script =~ "allow_remote_start"
      assert script =~ "allow_host_sandbox"
      assert script =~ "origin"
      assert script =~ "FOREMAN_AGENT_ENV"
      assert script =~ "FOREMAN_API_TOKEN"
    end

    test "a docker script points at the sandbox image prerequisites" do
      script = script!(generate!(request()))
      assert script =~ "foreman-jobsite:"
      refute script =~ "allow_host_sandbox"
    end

    test "nothing but the name derived from the prompt is copied out of it" do
      template =
        generate!(request(%{"prompt" => "one two three four SECRET-MARKER-123 and more"}))

      assert template.name == "one-two-three-four"
      refute String.downcase(script!(template)) =~ "secret-marker-123"
      assert prompt!(template) =~ "SECRET-MARKER-123"
    end
  end

  # -- helpers --------------------------------------------------------------------------------

  # {function, arity} for every `Foreman.Client.fun(...)` call in a parsed script.
  defp client_calls(ast) do
    {_, calls} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, [:Foreman, :Client]}, fun]}, _, args} = node, acc
        when is_atom(fun) and is_list(args) ->
          {node, [{fun, length(args)} | acc]}

        node, acc ->
          {node, acc}
      end)

    calls |> Enum.uniq() |> Enum.sort()
  end

  defp missing_client_calls(calls), do: Enum.reject(calls, &(&1 in client_exports()))

  # The public `def`s of packages/foreman_client/lib/foreman/client.ex, with default arguments
  # expanded to every arity they create.
  defp client_exports do
    {:ok, ast} = @client_source |> File.read!() |> Code.string_to_quoted()

    {_, exports} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:def, _, [head | _]} = node, acc -> {node, add_export(head, acc)}
        node, acc -> {node, acc}
      end)

    assert MapSet.size(exports) > 5, "found no exports in #{@client_source}"
    exports
  end

  defp add_export({:when, _, [head | _]}, acc), do: add_export(head, acc)

  defp add_export({name, _, args}, acc) when is_atom(name) and is_list(args) do
    defaults = Enum.count(args, &match?({:\\, _, _}, &1))
    Enum.reduce((length(args) - defaults)..length(args), acc, &MapSet.put(&2, {name, &1}))
  end

  defp add_export({name, _, ctx}, acc) when is_atom(name) and is_atom(ctx),
    do: MapSet.put(acc, {name, 0})

  # Evaluate the script's first `spec = %{...}` literal the way `elixir script.exs` would, with
  # `project_id` bound and `__DIR__` pointing at a directory that holds the generated prompt file.
  defp evaluate_spec_literal(%Template{} = template) do
    dir = write_template!(template)
    {:ok, ast} = template |> script!() |> Code.string_to_quoted()

    {_, literal} =
      Macro.prewalk(ast, nil, fn
        {:=, _, [{:spec, _, ctx}, {:%{}, _, _} = literal]} = node, nil when is_atom(ctx) ->
          {node, literal}

        node, acc ->
          {node, acc}
      end)

    assert literal != nil, "the script has no `spec = %{...}` literal"

    {spec, _binding} =
      Code.eval_quoted(literal, [project_id: @project_id],
        file: Path.join(dir, template.name <> ".exs")
      )

    spec
  end

  defp write_template!(%Template{files: files}) do
    dir = Path.join(System.tmp_dir!(), "template-test-#{System.unique_integer([:positive])}")

    for %GeneratedFile{path: path, content: content} <- files do
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defmodule FakeClient do
    @moduledoc false
    def new(opts \\ []) do
      send(self(), {:fake_client_new, opts})
      :fake_client
    end

    def run(:fake_client, spec, _wait_opts \\ []) do
      send(self(), {:fake_client_run, spec})

      {:ok,
       %{
         "jobsite_id" => "js-test",
         "status" => "completed",
         "branch" => spec["strategy"]["branch"],
         "iterations" => [%{}],
         "commits" => []
       }}
    end
  end

  # Runs the generated script's source with `Mix.install` removed and `Foreman.Client` pointed at
  # FakeClient (whose surface the export check above ties to the real client). Returns stdout.
  defp run_script(%Template{} = template, env) do
    dir = write_template!(template)

    source =
      template
      |> script!()
      |> String.replace(~r/^Mix\.install\(.*\)$/m, ":ok")
      |> String.replace("Foreman.Client", inspect(FakeClient))

    refute source =~ "Mix.install"

    previous = Map.new(env, fn {name, _value} -> {name, System.get_env(name)} end)

    on_exit(fn ->
      for {name, value} <- previous do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end)

    for {name, value} <- env do
      if value, do: System.put_env(name, value), else: System.delete_env(name)
    end

    capture_io(fn ->
      Code.eval_string(source, [], file: Path.join(dir, template.name <> ".exs"))
    end)
  end

  # -- generators -----------------------------------------------------------------------------

  # Mostly valid input, so the property exercises the success path as often as the failures.
  defp params_gen do
    gen all(
          prompt <- prompt_gen(),
          extras <- StreamData.list_of(extra_gen(), max_length: 3),
          drop <-
            StreamData.frequency([
              {14, StreamData.constant(nil)},
              {1, StreamData.member_of(["project_id", "prompt", "agent"])}
            ])
        ) do
      base = %{
        "project_id" => @project_id,
        "prompt" => prompt,
        "agent" => %{"provider" => "claude", "model" => "sonnet"}
      }

      extras |> Enum.reduce(base, fn {k, v}, acc -> Map.put(acc, k, v) end) |> Map.delete(drop)
    end
  end

  @phrases [
    "loop until done",
    "retry",
    "make the tests pass",
    "push it",
    "open a PR",
    "in place",
    "resume the session",
    "for each of the files",
    "ping me",
    "clean up",
    "must produce a report file",
    "the host",
    "\"\"\"",
    "\#{inspect(1)}",
    "\\",
    "\n",
    "ünï ✓",
    "<promise>COMPLETE</promise>"
  ]

  defp prompt_gen do
    StreamData.frequency([
      {6,
       StreamData.list_of(StreamData.member_of(@phrases), max_length: 6)
       |> StreamData.map(&Enum.join(&1, " "))},
      {3, StreamData.string(:printable, max_length: 80)},
      {1, StreamData.member_of(["", "   ", 5, nil])}
    ])
  end

  defp extra_gen do
    StreamData.frequency([{9, valid_extra_gen()}, {3, invalid_extra_gen()}])
  end

  defp extra_gen(key, values),
    do: StreamData.tuple({StreamData.constant(key), StreamData.member_of(values)})

  defp valid_extra_gen do
    StreamData.one_of([
      extra_gen("name", ["ok-name", "a.b", "Job_1"]),
      extra_gen("max_iterations", [1, 3, 5, 20]),
      extra_gen("completion_signal", ["DONE", ["a", "b"]]),
      extra_gen("strategy", [%{"branch" => "feat/x"}]),
      extra_gen("sandbox", ["docker", "host"]),
      extra_gen("push", [true, false]),
      extra_gen("agent", [
        %{"provider" => "pi", "model" => "m"},
        %{"provider" => "claude", "model" => "m"}
      ])
    ])
  end

  defp invalid_extra_gen do
    StreamData.one_of([
      extra_gen("name", ["bad name", "", 5]),
      extra_gen("max_iterations", [0, -3, "2", nil]),
      extra_gen("completion_signal", ["", 5]),
      extra_gen("strategy", [%{"branch" => "a..b"}, "head", %{"branch" => 5}]),
      extra_gen("sandbox", ["podman", 5]),
      extra_gen("push", ["yes", nil]),
      extra_gen("agent", [
        %{"provider" => "claude"},
        %{"model" => "m"},
        %{"provider" => "nope", "model" => "m"},
        %{"provider" => "claude", "model" => "m", "env" => %{"A" => "b"}},
        "claude"
      ]),
      extra_gen("hooks", [%{}]),
      extra_gen("bogus", [1])
    ])
  end
end
