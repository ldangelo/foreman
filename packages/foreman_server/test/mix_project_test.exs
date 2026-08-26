defmodule ForemanServer.MixProjectTest do
  use ExUnit.Case, async: false

  @mix_exs_path Path.expand("../mix.exs", __DIR__)

  test "Mox is in :test deps" do
    assert Code.ensure_loaded?(Mix.Project)

    source = File.read!(@mix_exs_path)

    assert source =~ "{:mox, \"~> 1.0\", only: :test}"
  end

  test "elixirc_paths(:test) returns ['lib', 'test/support']" do
    source = File.read!(@mix_exs_path)

    assert source =~ ~S|defp elixirc_paths(:test), do: ["lib", "test/support"]|
  end

  test "production elixirc_paths does not include test/support" do
    source = File.read!(@mix_exs_path)

    assert source =~ ~S|defp elixirc_paths(_), do: ["lib"]|
  end

  test "Mix.Project loads" do
    assert Code.ensure_loaded?(Mix.Project)
  end
end
