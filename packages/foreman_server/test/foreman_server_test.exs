defmodule ForemanServerTest do
  use ExUnit.Case

  test "starts with the configured project supervision topology" do
    assert is_list(ForemanServer.active_projects())
  end
end
