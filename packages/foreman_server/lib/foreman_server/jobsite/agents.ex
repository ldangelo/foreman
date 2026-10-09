defmodule ForemanServer.Jobsite.Agents do
  @moduledoc "Constructors for `ForemanServer.Jobsite.Agent`."

  alias ForemanServer.Jobsite.Agent

  @doc "A Pi agent. `binary` defaults to `\"pi\"` and is what the sandbox's `cli_path` shim `exec`s."
  @spec pi(String.t(), keyword()) :: Agent.t()
  def pi(model, opts \\ []), do: build(:pi, model, "pi", opts)

  @doc "A Claude agent. `binary` defaults to `\"claude\"` and is what the sandbox's `cli_path` shim `exec`s."
  @spec claude(String.t(), keyword()) :: Agent.t()
  def claude(model, opts \\ []), do: build(:claude, model, "claude", opts)

  defp build(provider, model, default_binary, opts) do
    %Agent{
      provider: provider,
      model: model,
      effort: Keyword.get(opts, :effort),
      env: Keyword.get(opts, :env, %{}),
      provider_options: Keyword.get(opts, :provider_options, %{}),
      binary: Keyword.get(opts, :binary, default_binary),
      approval_mode: Keyword.get(opts, :approval_mode)
    }
  end
end
