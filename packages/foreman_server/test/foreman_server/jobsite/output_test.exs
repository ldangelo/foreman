defmodule ForemanServer.Jobsite.OutputTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Jobsite.{Error, Output}

  describe "object/1 + extract/2" do
    test "a valid tag parses and validates" do
      schema = Zoi.object(%{name: Zoi.string(), count: Zoi.integer()})
      spec = Output.object(tag: "result", schema: schema)

      text = ~s(Here is my answer:\n<result>{"name": "foo", "count": 3}</result>\nDone.)

      assert {:ok, %{name: "foo", count: 3}} = Output.extract(spec, text)
    end

    test "the last of two tags wins" do
      schema = Zoi.object(%{value: Zoi.integer()})
      spec = Output.object(tag: "result", schema: schema)

      text = ~s(<result>{"value": 1}</result> then I reconsidered <result>{"value": 2}</result>)

      assert {:ok, %{value: 2}} = Output.extract(spec, text)
    end

    test "a missing tag is :output_tag_missing" do
      schema = Zoi.object(%{value: Zoi.integer()})
      spec = Output.object(tag: "result", schema: schema)

      assert {:error, %Error{code: :output_tag_missing}} = Output.extract(spec, "no tags here")
    end

    test "a schema mismatch is :output_invalid carrying raw_matched" do
      schema = Zoi.object(%{value: Zoi.integer()})
      spec = Output.object(tag: "result", schema: schema)

      text = ~s(<result>{"value": "not a number"}</result>)

      assert {:error, %Error{code: :output_invalid, details: %{raw_matched: raw}}} =
               Output.extract(spec, text)

      assert raw == ~s({"value": "not a number"})
    end

    test "invalid JSON is :output_invalid" do
      schema = Zoi.object(%{value: Zoi.integer()})
      spec = Output.object(tag: "result", schema: schema)

      assert {:error, %Error{code: :output_invalid}} =
               Output.extract(spec, "<result>not json</result>")
    end
  end

  describe "string/1 + extract/2" do
    test "returns the trimmed captured text with no decoding" do
      spec = Output.string(tag: "answer")
      assert {:ok, "42"} = Output.extract(spec, "<answer>  42  </answer>")
    end
  end
end
