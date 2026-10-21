defmodule ForemanServer.Coordinator.Agent.Stub do
  @moduledoc """
  Scripted coordinator agent for tests: no provider, deterministic.

  Driven by a per-test script process (never global application env, so
  concurrent tests cannot interfere): `start_supervised!({Stub, responses: [...]})`
  returns the script; pass it as `script: pid` in the agent opts. Each `turn/2`
  pops the next response and records the `Context` it was given. An exhausted
  script answers `{:ok, %Turn{reply: "ok", actions: []}}`.

  A response is one of

    * `{:ok, %Turn{}}` / `{:error, %Error{}}` - returned as is
    * `{:raw, text}` - parsed by `Coordinator.ActionSource` (exercises the parser)
    * `fun/1` - called with the context; may block (`receive`) to hold a turn open
      and returns any of the above
  """
  use Agent

  @behaviour ForemanServer.Coordinator.Agent

  alias ForemanServer.Coordinator.{ActionSource, Error, Turn}

  def start_link(opts) do
    state = %{responses: Keyword.get(opts, :responses, []), calls: []}
    Agent.start_link(fn -> state end, Keyword.take(opts, [:name]))
  end

  def child_spec(opts) do
    %{id: Keyword.get(opts, :id, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Queue more responses."
  def push(script, responses) when is_list(responses),
    do: Agent.update(script, &%{&1 | responses: &1.responses ++ responses})

  @doc "Contexts the script was called with, oldest first."
  def calls(script), do: script |> all_calls() |> Enum.map(&elem(&1, 0))

  @doc "Agent opts (provider, model, effort, ...) of each call, oldest first."
  def call_opts(script), do: script |> all_calls() |> Enum.map(&elem(&1, 1))

  defp all_calls(script), do: script |> Agent.get(& &1.calls) |> Enum.reverse()

  @impl ForemanServer.Coordinator.Agent
  def turn(context, opts) do
    script = Keyword.fetch!(opts, :script)

    response =
      Agent.get_and_update(script, fn state ->
        {next, rest} =
          case state.responses do
            [head | tail] -> {head, tail}
            [] -> {{:ok, %Turn{reply: "ok", actions: []}}, []}
          end

        {next, %{state | responses: rest, calls: [{context, opts} | state.calls]}}
      end)

    resolve(response, context)
  end

  defp resolve(fun, context) when is_function(fun, 1), do: resolve(fun.(context), context)
  defp resolve({:raw, text}, _context), do: ActionSource.parse(text)
  defp resolve({:ok, %Turn{}} = ok, _context), do: ok
  defp resolve({:error, %Error{}} = error, _context), do: error
end
