defmodule ForemanServer.Workflow.HotLoadIntegrationTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  alias ForemanServer.Workflow.{Loader, Validator}
  test "loader returns list" do
    assert is_list(Loader.load_all())
  end
  test "validator rejects invalid workflow" do
    assert {:error, _} = Validator.validate(%{})
  end
end