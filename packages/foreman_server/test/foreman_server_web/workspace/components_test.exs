defmodule ForemanServerWeb.Workspace.ComponentsTest do
  use ExUnit.Case, async: true

  alias ForemanServerWeb.Workspace.Components

  describe "run_detail_path/3" do
    test "orders run_id, tab, file, token and encodes the file" do
      assert Components.run_detail_path("R", "T", tab: "changes", file: "docs/TRD/a b.md") ==
               "/dashboard/runs?run_id=R&tab=changes&file=docs%2FTRD%2Fa+b.md&token=T"
    end

    test "omits tab, file and token when absent" do
      assert Components.run_detail_path("R", nil) == "/dashboard/runs?run_id=R"

      assert Components.run_detail_path("R", nil, tab: "logs") ==
               "/dashboard/runs?run_id=R&tab=logs"

      assert Components.run_detail_path("R", "T") == "/dashboard/runs?run_id=R&token=T"
    end

    test "encodes & = space / and unicode in run_id, file and token" do
      path = Components.run_detail_path("a&b=c d/é", "t&k=1 /é", tab: "changes", file: "x&y=z /é")

      assert path ==
               "/dashboard/runs?run_id=a%26b%3Dc+d%2F%C3%A9&tab=changes&file=x%26y%3Dz+%2F%C3%A9" <>
                 "&token=t%26k%3D1+%2F%C3%A9"

      query = path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert query == %{
               "run_id" => "a&b=c d/é",
               "tab" => "changes",
               "file" => "x&y=z /é",
               "token" => "t&k=1 /é"
             }
    end

    test "a file holding &token=evil cannot add a token parameter" do
      path = Components.run_detail_path("R", "T", tab: "changes", file: "a&token=evil")

      assert path == "/dashboard/runs?run_id=R&tab=changes&file=a%26token%3Devil&token=T"
      assert Regex.scan(~r/[?&]token=/, path) |> length() == 1
    end

    test "accepts every known tab" do
      for tab <- ~w(summary logs changes actions) do
        assert Components.run_detail_path("R", nil, tab: tab) ==
                 "/dashboard/runs?run_id=R&tab=#{tab}"
      end
    end

    test "raises on a missing or empty run_id and on an unknown tab" do
      assert_raise ArgumentError, fn -> Components.run_detail_path(nil, "T") end
      assert_raise ArgumentError, fn -> Components.run_detail_path("", "T") end
      assert_raise ArgumentError, fn -> Components.run_detail_path("R", "T", tab: "bogus") end
    end
  end
end
