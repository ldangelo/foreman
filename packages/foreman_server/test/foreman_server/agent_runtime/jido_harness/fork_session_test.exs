defmodule ForemanServer.AgentRuntime.JidoHarness.ForkSessionTest do
  use ExUnit.Case, async: true

  alias ForemanServer.AgentRuntime.JidoHarness.ForkSession
  alias Jido.Harness.Adapters.{Claude, Pi}
  alias Jido.Harness.RunRequest

  @uuid "3c0e51a8-7d1b-4a45-9c2e-0f6b8a1d2e34"
  @uuid7 "01a175c4-558c-702b-834b-9ee8d8218edc"

  describe "validate/2" do
    test "neither field is no fork" do
      assert ForkSession.validate(nil, nil) == :none
    end

    test "a supported provider with a safe id is valid" do
      assert ForkSession.validate("claude", @uuid) == :ok
      assert ForkSession.validate("pi", @uuid7) == :ok
    end

    test "one field without the other is refused as incomplete" do
      assert {:error, {:invalid_fork_session, :incomplete, {"claude", nil}}} =
               ForkSession.validate("claude", nil)

      assert {:error, {:invalid_fork_session, :incomplete, {nil, @uuid}}} =
               ForkSession.validate(nil, @uuid)
    end

    test "a provider that cannot fork is refused" do
      assert {:error, {:invalid_fork_session, :provider, "gemini"}} =
               ForkSession.validate("gemini", @uuid)

      # Atoms are not the recorded shape: the task stores the provider as a string.
      assert {:error, {:invalid_fork_session, :provider, :claude}} =
               ForkSession.validate(:claude, @uuid)
    end

    test "an id that could be read as a CLI flag, or carries a separator, is refused" do
      for bad <- ["--dangerously-skip-permissions", "-x", "a b", "a/b", "", ".hidden", "a;b", 42] do
        assert {:error, {:invalid_fork_session, :session_id, ^bad}} =
                 ForkSession.validate("claude", bad)
      end

      too_long = String.duplicate("a", 129)

      assert {:error, {:invalid_fork_session, :session_id, ^too_long}} =
               ForkSession.validate("claude", too_long)
    end
  end

  describe "harness_options/2" do
    test "claude resumes the id and forks it" do
      assert {@uuid, %{fork_session: true}} = ForkSession.harness_options("claude", @uuid)
      assert {@uuid, %{fork_session: true}} = ForkSession.harness_options(:claude, @uuid)
    end

    test "pi forks the id and carries no provider_session_id (the harness refuses both together)" do
      assert {nil, %{fork_session: @uuid7}} = ForkSession.harness_options("pi", @uuid7)
      assert {nil, %{fork_session: @uuid7}} = ForkSession.harness_options(:pi, @uuid7)
    end

    test "an unsupported provider or an unsafe id raises: callers validate first" do
      assert_raise FunctionClauseError, fn -> ForkSession.harness_options("gemini", @uuid) end
      assert_raise FunctionClauseError, fn -> ForkSession.harness_options(:gemini, @uuid) end

      assert_raise ArgumentError, ~r/unsafe provider session id/, fn ->
        ForkSession.harness_options("claude", "--resume")
      end
    end

    test "providers/0 is exactly what validate/2 and harness_options/2 accept" do
      assert ForkSession.providers() == ["claude", "pi"]
    end
  end

  # AGENTS.md 5.6: the options this module produces are only worth something if the pinned harness turns
  # them into the CLI flags that were measured against the real binaries.
  describe "harness contract" do
    setup do
      {:ok, cwd: File.cwd!()}
    end

    test "claude: --resume <id> --fork-session", %{cwd: cwd} do
      {session_id, provider_options} = ForkSession.harness_options("claude", @uuid)

      {:ok, request} =
        RunRequest.new(
          prompt: "p",
          provider: :claude,
          cwd: cwd,
          provider_session_id: session_id,
          provider_options: provider_options
        )

      {:ok, argv} = Claude.build_argv(request, provider_options)

      assert flag_value(argv, "--resume") == @uuid
      assert "--fork-session" in argv
    end

    test "pi: --fork <id> and no --session", %{cwd: cwd} do
      {session_id, provider_options} = ForkSession.harness_options("pi", @uuid7)

      {:ok, request} =
        RunRequest.new(
          prompt: "p",
          provider: :pi,
          cwd: cwd,
          provider_session_id: session_id,
          provider_options: provider_options
        )

      {:ok, argv} = Pi.build_argv(request, provider_options)

      assert flag_value(argv, "--fork") == @uuid7
      refute "--session" in argv
    end

    test "pi with live input keeps the fork (rpc mode)", %{cwd: cwd} do
      {session_id, provider_options} = ForkSession.harness_options("pi", @uuid7)
      options = Map.put(provider_options, :live_input, true)

      {:ok, request} =
        RunRequest.new(
          prompt: "p",
          provider: :pi,
          cwd: cwd,
          provider_session_id: session_id,
          provider_options: options
        )

      {:ok, argv} = Pi.build_argv(request, options)

      assert flag_value(argv, "--mode") == "rpc"
      assert flag_value(argv, "--fork") == @uuid7
    end

    test "claude with live input keeps resume and fork", %{cwd: cwd} do
      {session_id, provider_options} = ForkSession.harness_options("claude", @uuid)
      options = Map.put(provider_options, :live_input, true)

      {:ok, request} =
        RunRequest.new(
          prompt: "p",
          provider: :claude,
          cwd: cwd,
          provider_session_id: session_id,
          provider_options: options
        )

      {:ok, argv} = Claude.build_argv(request, options)

      assert flag_value(argv, "--resume") == @uuid
      assert "--fork-session" in argv
      assert flag_value(argv, "--input-format") == "stream-json"
    end

    defp flag_value(argv, flag) do
      case Enum.find_index(argv, &(&1 == flag)) do
        nil -> nil
        index -> Enum.at(argv, index + 1)
      end
    end
  end
end
