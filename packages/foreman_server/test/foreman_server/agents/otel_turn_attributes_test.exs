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

  test "an ok turn carries the reply as assistant output plus token usage", %{project_id: p} do
    usage = %Usage{input_tokens: 7, output_tokens: 3}
    attrs = TurnRunner.turn_result_attributes(p, {:ok, %Turn{reply: "done", usage: usage}})

    assert [%{"role" => "assistant"}] = Jason.decode!(attrs["gen_ai.output.messages"])
    assert decode(attrs["gen_ai.output.messages"]) == "done"
    assert attrs["gen_ai.usage.input_tokens"] == 7
    assert attrs["gen_ai.usage.output_tokens"] == 3
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
end
