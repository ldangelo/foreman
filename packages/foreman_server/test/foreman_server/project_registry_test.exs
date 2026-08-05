defmodule ForemanServer.ProjectRegistryTest do
  use ExUnit.Case, async: true

  alias ForemanServer.ProjectRegistry

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  describe "via/1 helper" do
    test "returns a via tuple referencing the project_registry" do
      assert {:via, Registry, {:project_registry, "x"}} = ProjectRegistry.via("x")
    end

    test "different project_ids produce different via tuples" do
      assert ProjectRegistry.via("a") != ProjectRegistry.via("b")
    end
  end
end
