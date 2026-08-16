defmodule ForemanServer.AgentRuntime.JidoHarness.SessionTest do
  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime.JidoHarness.Session
  alias Jido.Harness.{Adapter, AdapterSpec, Capabilities, Event, ProviderStatus, SessionTransportSpec}

  defmodule Stub do
    @moduledoc false
    @behaviour Adapter

    @impl true
    def spec do
      %AdapterSpec{
        provider: :pi,
        name: "TRD-009 session stub",
        executable: "stub",
        capabilities: %Capabilities{streaming?: true, resume?: true},
        default_session_transport: :managed,
        session_transports: [SessionTransportSpec.managed()],
        normalized_options: [:provider_session_id],
        provider_options: []
      }
    end

    @impl true
    def status(_config) do
      {:ok,
       %ProviderStatus{
         provider: :pi,
         installed: true,
         compatible: true,
         authenticated: true,
         smoke_ready: true,
         capabilities: %Capabilities{streaming?: true, resume?: true},
         executable: "stub"
       }}
    end

    @impl true
    def run(request, _context) do
      {:ok,
       [
         event(:turn_started, request, %{"turn" => 1}),
         event(:output_text_delta, request, %{"text" => "fixture-"}),
         event(:output_text_final, request, %{"text" => "fixture-ok"}),
         event(:turn_completed, request, %{"turn" => 1})
       ]}
    end

    defp event(type, request, payload) do
      Event.new!(
        provider: :pi,
        type: type,
        provider_session_id: request.provider_session_id || "fixture-session",
        payload: payload
      )
    end
  end

  setup do
    original_providers = Application.get_env(:jido_harness, :providers)
    original_config = Application.get_env(:jido_harness, :provider_config)
    original_default = Application.get_env(:jido_harness, :default_provider)

    journal_dir = Path.join(System.tmp_dir!(), "foreman-session-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(journal_dir)

    Application.put_env(:jido_harness, :providers, %{pi: Stub})
    Application.put_env(:jido_harness, :provider_config, %{pi: %{retention: %{journal_dir: journal_dir}}})
    Application.delete_env(:jido_harness, :default_provider)

    on_exit(fn ->
      restore_env(:providers, original_providers)
      restore_env(:provider_config, original_config)
      restore_env(:default_provider, original_default)
      cleanup_sessions()
      cleanup_runs()
      cleanup_processes()
      File.rm_rf!(journal_dir)
    end)

    :ok
  end

  describe "start/2" do
    test "returns {:ok, session_id} when upstream stub starts a session" do
      assert {:ok, session_id} = Session.start(:pi, [])
      assert is_binary(session_id)
      assert session_id != ""
    end
  end

  describe "send_message/3" do
    test "returns the upstream turn id for a valid session_id" do
      assert {:ok, session_id} = Session.start(:pi, [])
      assert :ok = await_idle(session_id)

      assert {:ok, turn_id} = Session.send_message(session_id, "ping", [])
      assert is_binary(turn_id)

      assert {:ok, %Jido.Harness.TurnResult{} = result} =
               Jido.Harness.Session.await(session_id, turn_id, 5_000)

      assert result.session_id == session_id
      assert result.provider == :pi
      assert result.status == :completed
      assert result.text == "fixture-ok"
      assert result.provider_session_id == "fixture-session"
    end

    test "returns {:error, :invalid_session} for an unknown session_id" do
      assert {:error, :invalid_session} = Session.send_message("invalid-id", "ping", [])
    end
  end

  describe "continue/3" do
    test "returns the upstream turn id for a valid session_id" do
      assert {:ok, session_id} = Session.start(:pi, [])
      assert :ok = await_idle(session_id)

      assert {:ok, first_turn_id} = Session.send_message(session_id, "first", [])
      assert {:ok, %Jido.Harness.TurnResult{} = first} =
               Jido.Harness.Session.await(session_id, first_turn_id, 5_000)

      assert first.provider_session_id == "fixture-session"
      assert :ok = await_idle(session_id)

      assert {:ok, turn_id} = Session.continue(session_id, "second", [])
      assert is_binary(turn_id)

      assert {:ok, %Jido.Harness.TurnResult{} = result} =
               Jido.Harness.Session.await(session_id, turn_id, 5_000)

      assert result.session_id == session_id
      assert result.provider == :pi
      assert result.status == :completed
      assert result.text == "fixture-ok"
      assert result.provider_session_id == "fixture-session"
    end
  end

  defp await_idle(session_id), do: await_idle(session_id, 100)
  defp await_idle(_session_id, 0), do: {:error, :timeout}

  defp await_idle(session_id, attempts) do
    case Jido.Harness.Session.info(session_id) do
      {:ok, %{state: :idle}} -> :ok
      _other ->
        Process.sleep(10)
        await_idle(session_id, attempts - 1)
    end
  end

  defp cleanup_sessions do
    Jido.Harness.Session.list()
    |> Enum.each(fn info ->
      unless Jido.Harness.SessionInfo.terminal?(info), do: Jido.Harness.Session.close(info.session_id)
      Jido.Harness.Session.prune(info.session_id)
    end)
  end

  defp cleanup_runs do
    Jido.Harness.Run.list()
    |> Enum.each(fn info ->
      unless Jido.Harness.RunInfo.terminal?(info), do: Jido.Harness.Run.cancel(info.run_id)
      Jido.Harness.Run.prune(info.run_id)
    end)
  end

  defp cleanup_processes do
    Jido.Harness.Process.list()
    |> Enum.each(fn info ->
      unless Jido.Harness.ProcessInfo.terminal?(info), do: Jido.Harness.Process.kill(info.process_id)
      _ = Jido.Harness.Process.await(info.process_id, 2_000)
      Jido.Harness.Process.prune(info.process_id)
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_harness, key)
  defp restore_env(key, value), do: Application.put_env(:jido_harness, key, value)
end
