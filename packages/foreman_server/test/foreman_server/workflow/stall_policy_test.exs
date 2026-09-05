defmodule ForemanServer.Workflow.StallPolicyTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Workflow.{PhaseSpec, StallPolicy, Validator}

  setup do
    keys = [
      :agent_no_output_stall_threshold_ms,
      :messaging_no_progress_stall_threshold_ms,
      :stall_detection_enabled
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:foreman_server, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:foreman_server, key)
        {key, value} -> Application.put_env(:foreman_server, key, value)
      end)
    end)

    :ok
  end

  test "defaults are typed positive thresholds" do
    Application.delete_env(:foreman_server, :agent_no_output_stall_threshold_ms)
    Application.delete_env(:foreman_server, :messaging_no_progress_stall_threshold_ms)

    assert StallPolicy.agent_threshold_ms!() == 900_000
    assert StallPolicy.messaging_threshold_ms!() == 1_800_000
  end

  test "malformed thresholds fail loudly, disable value is explicit" do
    for value <- [0, -1, "900000"] do
      Application.put_env(:foreman_server, :agent_no_output_stall_threshold_ms, value)

      assert {:error, {:invalid_stall_threshold, :agent_no_output_stall_threshold_ms, ^value}} =
               StallPolicy.validate_threshold(:agent_no_output_stall_threshold_ms, 900_000)
    end

    Application.put_env(:foreman_server, :agent_no_output_stall_threshold_ms, false)

    assert {:error, {:stall_detection_disabled, :agent_no_output_stall_threshold_ms}} =
             StallPolicy.validate_threshold(:agent_no_output_stall_threshold_ms, 900_000)
  end

  test "workflow validation accepts explicit metadata and rejects malformed overrides" do
    workflow = %{
      "name" => "ok",
      "phases" => [%{"name" => "wait", "prompt" => "x", "stall_detection" => "messaging"}]
    }

    assert :ok = Validator.validate(workflow)

    bad = %{
      "name" => "bad",
      "phases" => [
        %{"name" => "wait", "prompt" => "x", "stall_detection" => %{"kind" => "mystery"}}
      ]
    }

    assert {:error, {:invalid_stall_detection, 0, {:invalid_stall_kind, "mystery"}}} =
             Validator.validate(bad)
  end

  test "phase names never infer stall scope" do
    assert %{name: "messaging wait"} =
             PhaseSpec.normalize(%{"name" => "messaging wait", "prompt" => "x"})

    refute Map.has_key?(
             PhaseSpec.normalize(%{"name" => "messaging wait", "prompt" => "x"}),
             :stall_detection
           )

    assert %{stall_detection: %{kind: "messaging_no_progress"}} =
             PhaseSpec.normalize(%{
               "name" => "wait",
               "prompt" => "x",
               "stall_detection" => "messaging"
             })
  end
end
