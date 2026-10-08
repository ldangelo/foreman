defmodule ForemanServer.Jobsite.SpecTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Jobsite.{Agent, Error, Sandboxes, Spec}
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @project_id "spec-project"
  @repo_path "/srv/repos/spec-project"

  setup do
    ProjectionStoreReset.reset!()

    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "ProjectRegistered",
                 payload: %{project_id: @project_id, path: @repo_path}
               }
             ])

    on_exit(fn -> ProjectionStoreReset.reset!() end)
    :ok
  end

  defp base do
    %{
      "project_id" => @project_id,
      "prompt" => "Fix the bug",
      "agent" => %{"provider" => "claude", "model" => "sonnet"}
    }
  end

  defp assert_error(result, code) do
    assert {:error, %Error{code: ^code} = error} = result
    error
  end

  describe "accepted specs" do
    test "minimal spec resolves the project path and defaults to the docker sandbox" do
      assert {:ok, opts} = Spec.from_json(base())

      assert opts == [
               repo_path: @repo_path,
               sandbox: Sandboxes.docker(),
               agent: %Agent{provider: :claude, model: "sonnet", binary: "claude"},
               prompt: "Fix the bug"
             ]
    end

    test "fully populated spec equals the exact keyword" do
      spec = %{
        "project_id" => @project_id,
        "prompt" => "Do it",
        "strategy" => %{"branch" => "feature/x-1"},
        "agent" => %{
          "provider" => "pi",
          "model" => "gpt-x",
          "effort" => "high",
          "approval_mode" => "auto_edit",
          "env" => %{"FOO" => "bar"}
        },
        "sandbox" => "host",
        "name" => "job-1",
        "max_iterations" => 3,
        "completion_signal" => ["DONE", "FINISHED"],
        "idle_timeout_seconds" => 30,
        "completion_timeout_seconds" => 10,
        "hooks" => %{
          "sandbox" => %{"on_sandbox_ready" => [%{"command" => "mix deps.get"}]}
        },
        "exclude_paths" => ["docs"],
        "copy_to_worktree" => [".env.example"],
        "push" => true
      }

      assert {:ok, opts} =
               Spec.from_json(spec, allow_host_sandbox: true, agent_env_allowlist: ["FOO"])

      assert opts == [
               repo_path: @repo_path,
               strategy: {:branch, "feature/x-1"},
               sandbox: Sandboxes.host(),
               agent: %Agent{
                 provider: :pi,
                 model: "gpt-x",
                 effort: :high,
                 env: %{"FOO" => "bar"},
                 provider_options: %{},
                 binary: "pi",
                 approval_mode: :auto_edit
               },
               prompt: "Do it",
               name: "job-1",
               max_iterations: 3,
               completion_signal: ["DONE", "FINISHED"],
               idle_timeout_seconds: 30,
               completion_timeout_seconds: 10,
               hooks: %{
                 sandbox: %{on_sandbox_ready: [%{command: "mix deps.get"}]}
               },
               exclude_paths: ["docs"],
               copy_to_worktree: [".env.example"],
               push: true
             ]
    end

    test "strategy string and map forms" do
      assert {:ok, opts} = Spec.from_json(Map.put(base(), "strategy", "head"))
      assert opts[:strategy] == :head

      assert {:ok, opts} =
               Spec.from_json(Map.put(base(), "strategy", %{"type" => "branch", "name" => "b1"}))

      assert opts[:strategy] == {:branch, "b1"}
    end

    test "push false is omitted" do
      assert {:ok, opts} = Spec.from_json(Map.put(base(), "push", false))
      refute Keyword.has_key?(opts, :push)
    end

    test "push requires a named-branch strategy: head and the default have none to publish" do
      for strategy <- [nil, "head", %{"type" => "head"}] do
        spec = Map.put(base(), "push", true)
        spec = if strategy, do: Map.put(spec, "strategy", strategy), else: spec
        assert_error(Spec.from_json(spec), :spec_push_requires_branch)
      end

      spec = base() |> Map.put("push", true) |> Map.put("strategy", %{"branch" => "agent/x"})
      assert {:ok, opts} = Spec.from_json(spec)
      assert opts[:push] == true
      assert opts[:strategy] == {:branch, "agent/x"}

      # `push: false` never needed a branch.
      assert {:ok, _} = Spec.from_json(Map.put(base(), "push", false))
    end

    test "host sandbox allowed through application config" do
      previous = Application.get_env(:foreman_server, :jobsites)
      Application.put_env(:foreman_server, :jobsites, allow_host_sandbox: true)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:foreman_server, :jobsites, previous),
          else: Application.delete_env(:foreman_server, :jobsites)
      end)

      assert {:ok, opts} = Spec.from_json(Map.put(base(), "sandbox", "host"))
      assert opts[:sandbox] == Sandboxes.host()
    end
  end

  describe "rejections" do
    test "non-map input" do
      assert_error(Spec.from_json("nope"), :spec_invalid)
      assert_error(Spec.from_json(nil), :spec_invalid)
    end

    test "unknown key names the key and mints no atom" do
      key = "totally_unknown_key_#{System.unique_integer([:positive])}"
      error = assert_error(Spec.from_json(Map.put(base(), key, 1)), :spec_unknown_key)
      assert error.message =~ key
      assert error.details == %{key: key}
      assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    end

    test "absent project_id is distinct from malformed and unknown" do
      assert_error(Spec.from_json(Map.delete(base(), "project_id")), :spec_project_id_missing)
      assert_error(Spec.from_json(Map.put(base(), "project_id", 42)), :spec_project_id_invalid)
      assert_error(Spec.from_json(Map.put(base(), "project_id", "")), :spec_project_id_invalid)

      assert_error(
        Spec.from_json(Map.put(base(), "project_id", "no-such-project")),
        :spec_project_not_found
      )
    end

    test "archived project is unavailable" do
      assert :ok =
               ProjectionStore.apply_events([
                 %{event_type: "ProjectArchived", payload: %{project_id: @project_id}}
               ])

      assert_error(Spec.from_json(base()), :spec_project_unavailable)
    end

    test "prompt missing, malformed, blank" do
      assert_error(Spec.from_json(Map.delete(base(), "prompt")), :spec_prompt_missing)
      assert_error(Spec.from_json(Map.put(base(), "prompt", 5)), :spec_prompt_invalid)
      assert_error(Spec.from_json(Map.put(base(), "prompt", "  ")), :spec_prompt_invalid)
    end

    test "prompt_file is rejected" do
      spec = base() |> Map.delete("prompt") |> Map.put("prompt_file", "/etc/passwd")
      assert_error(Spec.from_json(spec), :spec_prompt_file_forbidden)
    end

    test "caller-only keys are rejected: on_event, reply_to, logging, resume?" do
      for key <- ["on_event", "reply_to", "logging", "resume?"] do
        assert_error(Spec.from_json(Map.put(base(), key, "x")), :spec_forbidden_key)
      end

      assert_error(
        Spec.from_json(Map.put(base(), "on_event", fn _ -> :ok end)),
        :spec_forbidden_key
      )
    end

    test "function-like values are rejected" do
      assert_error(Spec.from_json(Map.put(base(), "name", fn -> :ok end)), :spec_non_json_value)
      assert_error(Spec.from_json(Map.put(base(), "name", self())), :spec_non_json_value)

      assert_error(
        Spec.from_json(put_in(base(), ["agent", "model"], {:m, :f})),
        :spec_non_json_value
      )
    end

    test "agent missing / malformed / unknown key" do
      assert_error(Spec.from_json(Map.delete(base(), "agent")), :spec_agent_missing)
      assert_error(Spec.from_json(Map.put(base(), "agent", "claude")), :spec_agent_invalid)

      assert_error(
        Spec.from_json(put_in(base(), ["agent", "binary"], "/bin/sh")),
        :spec_agent_invalid
      )

      assert_error(
        Spec.from_json(update_in(base(), ["agent"], &Map.delete(&1, "model"))),
        :spec_agent_invalid
      )
    end

    test "bad provider" do
      error =
        assert_error(
          Spec.from_json(put_in(base(), ["agent", "provider"], "gemini-9000")),
          :spec_provider_invalid
        )

      assert error.details.provider == "gemini-9000"

      assert_error(
        Spec.from_json(put_in(base(), ["agent", "provider"], :claude)),
        :spec_non_json_value
      )

      assert_error(
        Spec.from_json(put_in(base(), ["agent", "provider"], 7)),
        :spec_provider_invalid
      )

      assert_raise ArgumentError, fn -> String.to_existing_atom("gemini-9000") end
    end

    test "bad approval_mode and effort" do
      assert_error(
        Spec.from_json(put_in(base(), ["agent", "approval_mode"], "yolo")),
        :spec_approval_mode_invalid
      )

      assert_error(
        Spec.from_json(put_in(base(), ["agent", "effort"], "ludicrous")),
        :spec_agent_invalid
      )
    end

    test "host sandbox disallowed by default and when flag is not exactly true" do
      assert_error(Spec.from_json(Map.put(base(), "sandbox", "host")), :spec_sandbox_not_allowed)

      assert_error(
        Spec.from_json(Map.put(base(), "sandbox", "host"), allow_host_sandbox: false),
        :spec_sandbox_not_allowed
      )

      assert_error(
        Spec.from_json(Map.put(base(), "sandbox", "host"), allow_host_sandbox: "yes"),
        :spec_sandbox_not_allowed
      )
    end

    test "unknown sandbox name" do
      assert_error(Spec.from_json(Map.put(base(), "sandbox", "vm")), :spec_sandbox_invalid)
      assert_error(Spec.from_json(Map.put(base(), "sandbox", 1)), :spec_sandbox_invalid)
    end

    test "agent env must be allowlisted" do
      spec = put_in(base(), ["agent", "env"], %{"SECRET" => "x"})
      error = assert_error(Spec.from_json(spec), :spec_env_not_allowed)
      assert error.details.keys == ["SECRET"]

      mixed = put_in(base(), ["agent", "env"], %{"OK" => "1", "SECRET" => "x"})
      assert_error(Spec.from_json(mixed, agent_env_allowlist: ["OK"]), :spec_env_not_allowed)

      assert {:ok, opts} = Spec.from_json(spec, agent_env_allowlist: ["SECRET"])
      assert opts[:agent].env == %{"SECRET" => "x"}

      assert {:ok, opts} = Spec.from_json(put_in(base(), ["agent", "env"], %{}))
      assert opts[:agent].env == %{}

      assert_error(
        Spec.from_json(put_in(base(), ["agent", "env"], %{"A" => 1}), agent_env_allowlist: ["A"]),
        :spec_agent_invalid
      )
    end

    test "strategy malformed" do
      for bad <- [
            "merge_to_head",
            %{"branch" => "-rf"},
            %{"branch" => "a..b"},
            %{"branch" => 3},
            %{"x" => 1},
            5
          ] do
        assert_error(Spec.from_json(Map.put(base(), "strategy", bad)), :spec_strategy_invalid)
      end
    end

    test "numeric options must be positive integers" do
      for key <- ["max_iterations", "idle_timeout_seconds", "completion_timeout_seconds"],
          bad <- [0, -1, 1.5, "3", true, nil] do
        error = assert_error(Spec.from_json(Map.put(base(), key, bad)), :spec_option_invalid)
        assert error.details.key == key
      end
    end

    test "other malformed options" do
      assert_error(Spec.from_json(Map.put(base(), "push", "yes")), :spec_option_invalid)
      assert_error(Spec.from_json(Map.put(base(), "name", "../evil")), :spec_option_invalid)
      assert_error(Spec.from_json(Map.put(base(), "completion_signal", [])), :spec_option_invalid)
      assert_error(Spec.from_json(Map.put(base(), "resume_session", "")), :spec_option_invalid)

      assert_error(
        Spec.from_json(Map.put(base(), "exclude_paths", ["/etc"])),
        :spec_option_invalid
      )

      assert_error(
        Spec.from_json(Map.put(base(), "copy_to_worktree", ["../secret"])),
        :spec_option_invalid
      )

      assert_error(Spec.from_json(Map.put(base(), "copy_to_worktree", "a")), :spec_option_invalid)
    end

    test "hooks validated" do
      assert_error(Spec.from_json(Map.put(base(), "hooks", "x")), :spec_hooks_invalid)

      assert_error(
        Spec.from_json(Map.put(base(), "hooks", %{"bogus" => %{}})),
        :spec_hooks_invalid
      )

      assert_error(
        Spec.from_json(Map.put(base(), "hooks", %{"sandbox" => %{"bogus" => []}})),
        :spec_hooks_invalid
      )

      assert_error(
        Spec.from_json(Map.put(base(), "hooks", %{"sandbox" => %{"on_worktree_ready" => "ls"}})),
        :spec_hooks_invalid
      )
    end

    test "hooks.host is forbidden: it would run sh -c on the server host" do
      host_hooks = %{"host" => %{"on_worktree_ready" => [%{"command" => "touch /tmp/pwned"}]}}
      assert_error(Spec.from_json(Map.put(base(), "hooks", host_hooks)), :spec_hooks_forbidden)

      # Forbidden even when empty or mixed with otherwise-valid sandbox hooks.
      assert_error(
        Spec.from_json(Map.put(base(), "hooks", %{"host" => %{}})),
        :spec_hooks_forbidden
      )

      mixed = %{
        "host" => %{"on_sandbox_ready" => [%{"command" => "ls"}]},
        "sandbox" => %{"on_sandbox_ready" => [%{"command" => "ls"}]}
      }

      assert_error(Spec.from_json(Map.put(base(), "hooks", mixed)), :spec_hooks_forbidden)
    end

    test "hooks sandbox-before-exists is rejected" do
      sandbox_before_exists = %{"sandbox" => %{"on_worktree_ready" => [%{"command" => "ls"}]}}
      assert_error(Spec.from_json(Map.put(base(), "hooks", sandbox_before_exists)), :hook_failed)
    end

    test "resume_session combined with max_iterations > 1 is rejected by Options" do
      spec = base() |> Map.put("resume_session", "sess-1") |> Map.put("max_iterations", 2)
      assert_error(Spec.from_json(spec), :resume_with_iterations)

      assert {:ok, opts} = Spec.from_json(Map.put(base(), "resume_session", "sess-1"))
      assert opts[:resume_session] == "sess-1"
    end
  end
end
