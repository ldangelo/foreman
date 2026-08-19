defmodule ForemanServer.Actions.ValidationMiddlewareTest do
  use ExUnit.Case, async: true

  defmodule SampleAction do
    use Jido.Action,
      name: "sample_validation_action",
      description: "Test action for validation middleware",
      schema: [
        name: [type: :string, required: true],
        age: [type: :non_neg_integer, required: false]
      ]

    @impl true
    def run(params, _context) do
      {:ok, %{greeting: "Hello, #{params.name}", age: params.age}}
    end
  end

  defp passthrough(action_module) do
    fn params, context -> action_module.run(params, context) end
  end

  describe "call/4 with valid keyword list params" do
    test "passes through to the next function" do
      next = passthrough(SampleAction)

      result =
        ForemanServer.Actions.ValidationMiddleware.call(
          SampleAction,
          [name: "World"],
          %{},
          next
        )

      assert {:ok, %{greeting: "Hello, World", age: nil}} = result
    end
  end

  describe "call/4 with valid map params (converted to keyword list)" do
    test "passes through to the next function" do
      next = passthrough(SampleAction)

      result =
        ForemanServer.Actions.ValidationMiddleware.call(
          SampleAction,
          %{name: "World", age: 30},
          %{},
          next
        )

      assert {:ok, %{greeting: "Hello, World", age: 30}} = result
    end

    test "map with only required fields passes validation" do
      next = passthrough(SampleAction)

      result =
        ForemanServer.Actions.ValidationMiddleware.call(
          SampleAction,
          %{name: "Alice"},
          %{},
          next
        )

      assert {:ok, %{greeting: "Hello, Alice", age: nil}} = result
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

    test "rejects params with wrong type for required field" do
      result =
        ForemanServer.Actions.ValidationMiddleware.call(
          SampleAction,
          %{name: 123},
          %{},
          passthrough(SampleAction)
        )

      assert {:error, {:invalid_params, %{name: 123}}} = result
    end

    test "rejects params with wrong type for optional field" do
      result =
        ForemanServer.Actions.ValidationMiddleware.call(
          SampleAction,
          [name: "Bob", age: "not_an_integer"],
          %{},
          passthrough(SampleAction)
        )

      assert {:error, {:invalid_params, [name: "Bob", age: "not_an_integer"]}} = result
    end
  end

  describe "call/4 with non-map, non-list params" do
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

    test "returns :invalid_params error for atom" do
      next = passthrough(SampleAction)

      assert {:error, {:invalid_params, :some_atom}} =
               ForemanServer.Actions.ValidationMiddleware.call(
                 SampleAction,
                 :some_atom,
                 %{},
                 next
               )
    end

    test "returns :invalid_params error for integer" do
      next = passthrough(SampleAction)

      assert {:error, {:invalid_params, 42}} =
               ForemanServer.Actions.ValidationMiddleware.call(
                 SampleAction,
                 42,
                 %{},
                 next
               )
    end
  end

  describe "call/4 context passthrough" do
    test "passes context through to the next function" do
      test_pid = self()
      context = %{request_id: "req-123"}

      next = fn params, ctx ->
        send(test_pid, {:called, ctx})
        {:ok, params}
      end

      result =
        ForemanServer.Actions.ValidationMiddleware.call(
          SampleAction,
          [name: "Charlie"],
          context,
          next
        )

      assert {:ok, [name: "Charlie"]} = result
      assert_received {:called, ^context}
    end
  end
end
