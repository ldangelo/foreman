defmodule ForemanServer.TestSupport.BrFixtures do
  @moduledoc """
  Verbatim stdout captured from a real `br` (see `test/fixtures/br/README.md`).

  Tests that stub `BrRunner` must return these files instead of hand-written
  JSON, so a change in the shape real `br` emits fails CI rather than shipping.
  """

  @dir Path.expand("../fixtures/br", __DIR__)

  @doc "Absolute path of a captured fixture."
  @spec path(String.t()) :: String.t()
  def path(name) when is_binary(name), do: Path.join(@dir, name)

  @doc "The verbatim captured stdout of a fixture."
  @spec read!(String.t()) :: String.t()
  def read!(name) when is_binary(name), do: File.read!(path(name))

  @doc "The fixture's stdout decoded as JSON."
  @spec decode!(String.t()) :: term()
  def decode!(name) when is_binary(name), do: name |> read!() |> Jason.decode!()

  @doc "The issue map of a `show --json`/`create --json` fixture (unwraps the one-element array)."
  @spec issue!(String.t()) :: map()
  def issue!(name) do
    case decode!(name) do
      [%{} = issue] -> issue
      %{} = issue -> issue
    end
  end
end
