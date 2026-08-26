defmodule ForemanServer.Workflow.LoaderTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Workflow.Loader

  test "load_all returns a list" do
    assert is_list(Loader.load_all())
  end
end
