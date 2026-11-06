defmodule ForemanServer.Agents.OtelTurnAttributesTest do
  @moduledoc """
  What a coordinator turn span carries: operator input, reply, error, model and usage, with the
  project's secret values redacted out of every text attribute (the collector prints attributes).
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.Coordinator.{Error, Turn, TurnRunner}
  alias ForemanServer.{CommandRouter, ProjectSecrets, Usage}

  @secret "postgres://svc:hunter2pw@db.internal:5432/app"

  setup %{tmp_dir: dir} do
    store = Application.get_env(:foreman_server, :secret_store)

    Application.put_env(
      :foreman_server,
      :secret_store,
      Keyword.put(store, :dir, Path.join(dir, "secrets"))
    )

    on_exit(fn -> Application.put_env(:foreman_server, :secret_store, store) end)

    project_id = "otel-turn-#{System.unique_integer([:positive])}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.register",
        aggregate_id: "project:#{project_id}",
        payload: %{project_id: project_id, path: dir, config: %{}}
      })

    assert {:ok, %{name: "DB_URL"}} = ProjectSecrets.set(project_id, "DB_URL", @secret, "test")

    {:ok, project_id: project_id}
  end

  defp content([%{"content" => content}]), do: content
  defp decode(json), do: json |> Jason.decode!() |> content()

  test "the span carries the operator input, the model and the turn identity", %{project_id: p} do
    context = %{trigger_messages: [%{text: "first"}, %{text: "second"}]}

    attrs = TurnRunner.turn_span_attributes(p, "turn-1", context, model: "m-1")

    assert decode(attrs["gen_ai.input.messages"]) == "first\n\nsecond"
    assert attrs["gen_ai.request.model"] == "m-1"
    assert attrs["foreman.project_id"] == p
    assert attrs["foreman.turn_id"] == "turn-1"
  end

  test "no model option means no model attribute", %{project_id: p} do
    attrs = TurnRunner.turn_span_attributes(p, "t", %{trigger_messages: [%{text: "x"}]}, [])
    refute Map.has_key?(attrs, "gen_ai.request.model")
  end

  test "the root span carries the reply but NO usage; the chat span carries both", %{
    project_id: p
  } do
    usage = %Usage{input_tokens: 7, output_tokens: 3}
    result = {:ok, %Turn{reply: "done", usage: usage}}

    root = TurnRunner.turn_result_attributes(p, result)
    assert [%{"role" => "assistant"}] = Jason.decode!(root["gen_ai.output.messages"])
    assert decode(root["gen_ai.output.messages"]) == "done"
    refute Map.has_key?(root, "gen_ai.usage.input_tokens")
    refute Map.has_key?(root, "gen_ai.usage.output_tokens")

    chat = TurnRunner.chat_result_attributes(p, result)
    assert decode(chat["gen_ai.output.messages"]) == "done"
    assert chat["gen_ai.usage.input_tokens"] == 7
    assert chat["gen_ai.usage.output_tokens"] == 3
  end

  test "an error result is the same on both spans and carries no usage", %{project_id: p} do
    result = {:error, Error.new(:agent_failed, "it broke")}

    assert TurnRunner.chat_result_attributes(p, result) ==
             TurnRunner.turn_result_attributes(p, result)
  end

  test "the chat span name carries the model, bounded" do
    assert TurnRunner.chat_span_name([]) == "chat"
    assert TurnRunner.chat_span_name(model: "m-1") == "chat m-1"

    name = TurnRunner.chat_span_name(model: String.duplicate("x", 500))
    assert name == "chat " <> String.duplicate("x", 80)
  end

  test "an error turn carries its message", %{project_id: p} do
    attrs = TurnRunner.turn_result_attributes(p, {:error, Error.new(:agent_failed, "it broke")})
    assert attrs == %{"error.message" => "it broke"}
  end

  test "a stored secret value is in no attribute value of input, reply or error", %{project_id: p} do
    context = %{trigger_messages: [%{text: "connect to #{@secret} now"}]}

    all =
      [
        TurnRunner.turn_span_attributes(p, "t", context, []),
        TurnRunner.turn_result_attributes(p, {:ok, %Turn{reply: "used #{@secret}", usage: nil}}),
        TurnRunner.turn_result_attributes(
          p,
          {:error, Error.new(:agent_failed, "failed against #{@secret}")}
        )
      ]
      |> Enum.flat_map(&Map.values/1)
      |> Enum.map(&to_string/1)

    assert Enum.any?(all, &(&1 =~ "[REDACTED]"))
    refute Enum.any?(all, &(&1 =~ "hunter2pw"))
    refute Enum.any?(all, &(&1 =~ @secret))
  end

  describe "a project whose environment is refused" do
    setup do
      id = "otel-turn-refused-#{System.unique_integer([:positive])}"

      :ok =
        ForemanServer.ProjectionStore.apply_events([
          %{
            event_type: "ProjectRegistered",
            payload: %{
              project_id: id,
              path: "/tmp/#{id}",
              config: %{env: %{"FOREMAN_RUN_ID" => "sneaky-value-9"}}
            }
          }
        ])

      assert_raise ArgumentError, fn -> ForemanServer.ProjectEnvironment.secrets(id) end
      {:ok, refused: id}
    end

    test "the builders never raise and the built-in token patterns still redact",
         %{refused: id} do
      context = %{trigger_messages: [%{text: "tok password=hunter2 end"}]}

      input = TurnRunner.turn_span_attributes(id, "t", context, [])
      assert decode(input["gen_ai.input.messages"]) == "tok password=[REDACTED] end"

      ok = TurnRunner.turn_result_attributes(id, {:ok, %Turn{reply: "pw password=hunter2"}})
      assert decode(ok["gen_ai.output.messages"]) == "pw password=[REDACTED]"

      err = TurnRunner.turn_result_attributes(id, {:error, Error.new(:x, "bad password=hunter2")})
      assert err["error.message"] == "bad password=[REDACTED]"
    end
  end
end
