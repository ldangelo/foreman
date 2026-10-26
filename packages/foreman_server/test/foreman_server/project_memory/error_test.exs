defmodule ForemanServer.ProjectMemory.ErrorTest do
  use ExUnit.Case, async: true

  alias ForemanServer.ProjectMemory.Error

  @lib Path.expand("../../../lib/foreman_server", __DIR__)
  # error.ex defines the codes (and quotes `Error.new(:code, ...)` in a comment); every
  # other project-memory source produces them.
  @sources Path.wildcard(Path.join(@lib, "project_memory.ex")) ++
             (Path.wildcard(Path.join(@lib, "project_memory/*.ex")) --
                [Path.join(@lib, "project_memory/error.ex")])

  test "every code a project-memory source constructs has a category" do
    assert length(@sources) >= 5

    produced =
      @sources
      |> Enum.flat_map(fn file ->
        ~r/Error\.new\(\s*:([a-z_]+)/ |> Regex.scan(File.read!(file), capture: :all_but_first)
      end)
      |> List.flatten()
      |> Enum.map(&String.to_atom/1)
      |> Enum.uniq()
      |> Enum.sort()

    assert produced != []
    assert produced -- Error.codes() == []
  end

  test "codes/0 and category/1 agree, and only name known categories" do
    for code <- Error.codes() do
      assert Error.category(code) in [:invalid_input, :not_found, :conflict, :internal]
    end
  end

  test "the surfaces' external classes are preserved" do
    assert Error.category(:name_invalid) == :invalid_input
    assert Error.category(:content_not_durable) == :invalid_input
    assert Error.category(:not_found) == :not_found
    assert Error.category(:project_not_found) == :not_found
    assert Error.category(:project_archived) == :conflict
    assert Error.category(:project_path_unknown) == :conflict
    assert Error.category(:write_failed) == :internal
    assert Error.category(:audit_failed) == :internal
  end

  test "an unknown code is a loud failure, never a silent class" do
    assert_raise KeyError, fn -> Error.category(:brand_new_code) end
  end
end
