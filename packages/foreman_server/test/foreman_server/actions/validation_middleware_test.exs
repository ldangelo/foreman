defmodule ForemanServer.Actions.ValidationMiddlewareTest do
  use ExUnit.Case, async: true

  defmodule SampleAction do
    use Jido.Action,
      name: "sample_validation_action",
      description: "Test action for validation middleware",
      schema: [
        name: [type: :string, required: true]
      ]

    @impl true
    def run(params, _context) do
      {:ok, %{greeting: "Hello, " <> params.name}}
    end
  end

  defp passthrough(action_module) do
    fn params, context -> action_module.run(params, context) end
  end

  describe "call/4 with valid params" do
    test "passes through to the next function" do
      next = passthrough(SampleAction)

      result =
        ForemanServer.Actions.ValidationMiddleware.call(
          SampleAction,
          %{name: "World"},
          %{},
          next
        )

      assert {:ok, %{greeting: "Hello, World"}} = result
    end
  end

  describe "call/4 with invalid params" do
    test "rejects missing required params and does not invoke next" do
      test_pid = self()

      next = fn _params, _context ->
        send(test_pid, :next_called)
        {:ok, %{}}
      end

      result =
        ForemanServer.Actions.ValidationMiddleware.call(
          SampleAction,
          %{},
          %{},
          next
        )

      assert {:error, {:invalid_params, %{}}} = result
      refute_received :next_called
    end

    test "rejects params with wrong type" do
      result =
        ForemanServer.Actions.ValidationMiddleware.call(
          SampleAction,
          %{name: 123},
          %{},
          passthrough(SampleAction)
        )

      assert {:error, {:invalid_params, %{name: 123}}} = result
    end
  end

  describe "call/4 with non-map params" do
    test "returns :invalid_params error" do
      next = passthrough(SampleAction)

      assert {:error, {:invalid_params, "not a map"}} =
               ForemanServer.Actions.ValidationMiddleware.call(
                 SampleAction,
                 "not a map",
                 %{},
                 next
               )
    end
  end
end
