defmodule Jido.Harness.LiveInputTest do
  use ExUnit.Case, async: false

  alias Jido.Harness.Adapters.CLIMapper
  alias Jido.Harness.{Event, Run}

  @claude_recording Path.expand("../support/fixtures/claude_live_input.jsonl", __DIR__)

  setup do
    original = Application.get_env(:jido_harness, :provider_config, %{})

    config =
      Map.merge(original, %{
        claude: %{cli_path: Jido.Harness.TestHelpers.fixture_path("fake_claude_live.py")},
        pi: %{cli_path: Jido.Harness.TestHelpers.fixture_path("fake_pi_live.py")}
      })

    Application.put_env(:jido_harness, :provider_config, config)

    on_exit(fn ->
      Jido.Harness.TestHelpers.cleanup_runs()
      Application.put_env(:jido_harness, :provider_config, original)
    end)

    :ok
  end

  defp start_live(provider, prompt) do
    {:ok, run_id} =
      Run.start(provider, %{
        prompt: prompt,
        provider_options: %{live_input: true},
        runtime_timeout_ms: 30_000
      })

    run_id
  end

  defp events(run_id) do
    {:ok, events} = Run.replay(run_id, cursor: 0, limit: 1_000)
    events
  end

  defp wait_for_event(run_id, fun, attempts \\ 200) do
    case Enum.find(events(run_id), fun) do
      nil when attempts > 0 ->
        Process.sleep(25)
        wait_for_event(run_id, fun, attempts - 1)

      nil ->
        flunk("event never appeared: #{inspect(Enum.map(events(run_id), & &1.type))}")

      event ->
        event
    end
  end

  describe "claude (recorded claude 2.1.308 stream-json)" do
    test "a steer written mid-turn is consumed by id in the same session and ends the run once" do
      run_id = start_live(:claude, "first")
      wait_for_event(run_id, &(&1.type == :input_accepted and &1.payload["text"] == "first"))

      # The first turn is still running (the fake holds it open).
      assert :ok = Run.send_input(run_id, "steer-1", "second")

      assert {:ok, result} = Run.await(run_id, 15_000)
      assert result.status == :completed

      accepted = for %Event{type: :input_accepted, payload: p} <- result.events, do: p["input_id"]
      assert "steer-1" in accepted

      # Two turns' results, one run, one completion, and the second turn's text is the result.
      assert Enum.count(result.events, &(&1.type == :input_idle)) == 2
      assert Enum.count(result.events, &(&1.type == :run_completed)) == 1
      assert result.text == "two"
      assert result.provider_session_id == "f0739304-d2f9-45de-9da3-bdc226bd2e3d"
    end

    test "stdin is closed after the last idle, so a late write is refused, never dropped silently" do
      run_id = start_live(:claude, "only")
      wait_for_event(run_id, &(&1.type == :input_idle))

      assert {:error, reason} = Run.send_input(run_id, "late", "too late")
      assert reason in [:input_closed, :not_running]
      assert {:ok, %{status: :completed}} = Run.await(run_id, 15_000)
    end

    test "a run not started with live_input refuses input as :not_live" do
      {:ok, run_id} = Run.start(:claude, %{prompt: "plain", runtime_timeout_ms: 30_000})
      assert {:error, :not_live} = Run.send_input(run_id, "x", "y")
    end

    test "recorded real records map to :input_accepted/:input_idle in live mode and :run_completed otherwise" do
      records = @claude_recording |> File.stream!() |> Enum.map(&Jason.decode!/1)
      echo = Enum.find(records, &(&1["type"] == "user" and &1["isReplay"] == true))
      result = Enum.find(records, &(&1["type"] == "result"))

      assert [%Event{type: :input_accepted, payload: %{"input_id" => id, "text" => "Reply with the single word one."}}] =
               CLIMapper.claude_live(echo)

      assert id == echo["uuid"]

      assert [] = CLIMapper.claude(echo)

      live_types = result |> CLIMapper.claude_live() |> Enum.map(& &1.type)
      assert List.last(live_types) == :input_idle
      refute :run_completed in live_types
      assert result |> CLIMapper.claude() |> List.last() |> Map.fetch!(:type) == :run_completed
    end
  end

  describe "pi (recorded pi 1.3.0 rpc)" do
    test "a steer is consumed FIFO by text after the tool call, session id comes from get_state" do
      run_id = start_live(:pi, "prompt")
      wait_for_event(run_id, &(&1.type == :tool_call))

      assert :ok = Run.send_input(run_id, "steer-1", "Reply with the word STEERED instead.")

      assert {:ok, result} = Run.await(run_id, 20_000)
      assert result.status == :completed

      assert Enum.any?(
               result.events,
               &(&1.type == :input_accepted and &1.payload["text"] == "Reply with the word STEERED instead.")
             )

      assert result.provider_session_id =~ ~r/^[0-9a-f-]{36}$/
      assert Enum.count(result.events, &(&1.type == :input_idle)) == 1
    end

    test "attachments are refused loudly in live mode" do
      request = Jido.Harness.RunRequest.new!(%{prompt: "x", attachments: ["/tmp/a.png"]})

      assert {:error, %Jido.Harness.Error{message: message}} =
               Jido.Harness.Adapters.Pi.build_argv(request, %{live_input: true})

      assert message =~ "attachments"
    end
  end
end
