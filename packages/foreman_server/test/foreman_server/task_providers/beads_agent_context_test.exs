defmodule ForemanServer.TaskProviders.BeadsAgentContextTest do
  use ExUnit.Case, async: true

  alias ForemanServer.TaskProviders.BeadsAgentContext

  test "decodes the JSON string real br 0.6.0 emits" do
    raw = ~s({"foreman":{"task_id":"t1"},"trd_path":"docs/x.md"})

    assert {:ok, %{"foreman" => %{"task_id" => "t1"}, "trd_path" => "docs/x.md"}} =
             BeadsAgentContext.decode(raw)
  end

  test "passes an object through" do
    assert {:ok, %{"a" => 1}} = BeadsAgentContext.decode(%{"a" => 1})
  end

  test "absent is not malformed" do
    assert :absent = BeadsAgentContext.decode(nil)
    assert :absent = BeadsAgentContext.decode("")
  end

  test "malformed is loud, not absent" do
    assert {:error, :malformed} = BeadsAgentContext.decode("{not json")
    assert {:error, :malformed} = BeadsAgentContext.decode("[1,2]")
    assert {:error, :malformed} = BeadsAgentContext.decode("\"str\"")
    assert {:error, :malformed} = BeadsAgentContext.decode(42)
  end
end
