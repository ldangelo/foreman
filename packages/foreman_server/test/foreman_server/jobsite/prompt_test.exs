defmodule ForemanServer.Jobsite.PromptTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Jobsite.{Error, Prompt, Sandbox, Sandboxes, Worktree}

  defp tmp_repo! do
    path = Path.join(System.tmp_dir!(), "jobsite-prompt-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    {_output, 0} = System.cmd("git", ["-C", path, "init", "-q"])
    {_output, 0} = System.cmd("git", ["-C", path, "config", "user.email", "test@example.com"])
    {_output, 0} = System.cmd("git", ["-C", path, "config", "user.name", "Test"])
    File.write!(Path.join(path, "README.md"), "hello\n")
    {_output, 0} = System.cmd("git", ["-C", path, "add", "-A"])
    {_output, 0} = System.cmd("git", ["-C", path, "commit", "-q", "-m", "init"])
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp sandbox! do
    repo = tmp_repo!()
    {:ok, worktree} = Worktree.create(repo_path: repo, strategy: :head)
    {provider, config} = Sandboxes.host()
    {:ok, state, sandbox_repo_path, container_id} = provider.create(config, worktree)

    %Sandbox{
      jobsite_id: "js-test",
      provider: provider,
      state: state,
      worktree: worktree,
      sandbox_repo_path: sandbox_repo_path,
      container_id: container_id,
      config: config
    }
  end

  describe "resolve/3 — inline :prompt" do
    test "passes through byte-identical, {{X}} intact" do
      sandbox = sandbox!()
      assert {:ok, "do the thing {{NOT_SUBSTITUTED}}"} = Prompt.resolve([prompt: "do the thing {{NOT_SUBSTITUTED}}"], sandbox, %{})
    end

    test "rejects prompt_args alongside an inline :prompt" do
      sandbox = sandbox!()

      assert {:error, %Error{code: :prompt_source_conflict}} =
               Prompt.resolve([prompt: "x", prompt_args: %{"A" => "b"}], sandbox, %{})
    end
  end

  describe "resolve/3 — :prompt_file substitution" do
    test "substitutes {{KEY}} from prompt_args" do
      sandbox = sandbox!()
      file = Path.join(System.tmp_dir!(), "prompt-#{System.unique_integer([:positive])}.md")
      File.write!(file, "Implement issue {{ISSUE_NUMBER}} on {{SOURCE_BRANCH}}")
      on_exit(fn -> File.rm(file) end)

      assert {:ok, text} = Prompt.resolve([prompt_file: file, prompt_args: %{"ISSUE_NUMBER" => "42"}], sandbox, %{})
      assert text =~ "Implement issue 42 on"
      assert text =~ sandbox.worktree.branch
    end

    test "a missing key is :prompt_arg_missing" do
      sandbox = sandbox!()
      file = Path.join(System.tmp_dir!(), "prompt-#{System.unique_integer([:positive])}.md")
      File.write!(file, "{{UNDEFINED_KEY}}")
      on_exit(fn -> File.rm(file) end)

      assert {:error, %Error{code: :prompt_arg_missing}} = Prompt.resolve([prompt_file: file], sandbox, %{})
    end

    test "prompt_args setting a reserved key is :prompt_arg_reserved" do
      sandbox = sandbox!()
      file = Path.join(System.tmp_dir!(), "prompt-#{System.unique_integer([:positive])}.md")
      File.write!(file, "hello")
      on_exit(fn -> File.rm(file) end)

      assert {:error, %Error{code: :prompt_arg_reserved}} =
               Prompt.resolve([prompt_file: file, prompt_args: %{"SOURCE_BRANCH" => "evil"}], sandbox, %{})
    end
  end

  describe "resolve/3 — command expansion" do
    test "runs !`command` inside the sandbox and substitutes its output" do
      sandbox = sandbox!()
      file = Path.join(System.tmp_dir!(), "prompt-#{System.unique_integer([:positive])}.md")
      File.write!(file, "today is !`echo hello-expansion`")
      on_exit(fn -> File.rm(file) end)

      assert {:ok, text} = Prompt.resolve([prompt_file: file], sandbox, %{})
      assert text == "today is hello-expansion"
    end

    test "a non-zero expansion command is :prompt_expansion_failed" do
      sandbox = sandbox!()
      file = Path.join(System.tmp_dir!(), "prompt-#{System.unique_integer([:positive])}.md")
      File.write!(file, "!`exit 7`")
      on_exit(fn -> File.rm(file) end)

      assert {:error, %Error{code: :prompt_expansion_failed}} = Prompt.resolve([prompt_file: file], sandbox, %{})
    end

    test "expansion scans only the file's text, never a substituted value" do
      sandbox = sandbox!()
      file = Path.join(System.tmp_dir!(), "prompt-#{System.unique_integer([:positive])}.md")
      File.write!(file, "payload: {{PAYLOAD}}")
      on_exit(fn -> File.rm(file) end)

      assert {:ok, text} =
               Prompt.resolve([prompt_file: file, prompt_args: %{"PAYLOAD" => "!`echo injected`"}], sandbox, %{})

      assert text == "payload: !`echo injected`"
    end
  end
end
