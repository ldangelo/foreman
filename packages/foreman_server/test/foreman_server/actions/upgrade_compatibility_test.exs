defmodule ForemanServer.Actions.UpgradeCompatibilityTest do
  @moduledoc """
  ADT-T004 — Jido package upgrade compatibility test.

  Per TRD-2026-4212be7e / ADT-T004 / TRD-086: after a candidate upstream
  Jido release is adopted (JRM-T004), this test confirms the
  representative action (`GitStatusAction`) still loads, its schema is
  unchanged, and `run/2` still produces the documented output shape.

  Tag `:upgrade_compat` keeps the test opt-in for the upstream-upgrade
  workflow (`.github/workflows/jido-upstream-upgrade.yml`) so it does
  not bloat the default fast feedback loop.
  """
  use ExUnit.Case, async: false

  @moduletag :upgrade_compat

  alias ForemanServer.Actions.GitStatusAction

  test "GitStatusAction is still loadable against the current Jido pin" do
    assert Code.ensure_loaded?(GitStatusAction)
    assert function_exported?(GitStatusAction, :run, 2)
  end

  test "GitStatusAction schema is unchanged across Jido versions" do
    # Schema baseline is recorded at TRD-083. This test asserts the
    # input/output schema still resolves to the documented fields and
    # types. Any drift here means a Jido.Action contract regression.
    schema = GitStatusAction.schema()
    assert is_list(schema)
    assert Keyword.has_key?(schema, :path)
    assert schema[:path][:type] == :string
    refute schema[:path][:required]
  end

  test "GitStatusAction run/2 still produces the documented output shape" do
    tmp =
      Path.join(System.tmp_dir!(), "adt_t004_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "README.md"), "init")

    try do
      {_, 0} = System.cmd("git", ["init", tmp])
      {_, 0} = System.cmd("git", ["-C", tmp, "config", "user.email", "test@example.com"])
      {_, 0} = System.cmd("git", ["-C", tmp, "config", "user.name", "Test User"])
      {_, 0} = System.cmd("git", ["-C", tmp, "add", "README.md"])
      {_, 0} = System.cmd("git", ["-C", tmp, "commit", "-m", "initial"])

      assert {:ok, %{porcelain: porcelain, exit_code: 0}} =
               GitStatusAction.run(%{path: tmp}, %{})

      assert is_list(porcelain)
    after
      File.rm_rf!(tmp)
    end
  end
end
