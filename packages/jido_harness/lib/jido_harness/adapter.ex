defmodule Jido.Harness.Adapter do
  @moduledoc "Behaviour implemented by built-in and custom harness providers."

  alias Jido.Harness.{AdapterSpec, Event, ProviderStatus, RunRequest}

  @type context :: %{
          required(:run_id) => String.t(),
          required(:provider) => atom(),
          required(:config) => map(),
          required(:telemetry_context) => map(),
          required(:process_manager) => module(),
          optional(:run_owner) => pid()
        }

  @callback spec() :: AdapterSpec.t()
  @callback run(RunRequest.t(), context()) :: {:ok, Enumerable.t(Event.t())} | {:error, term()}
  @callback status(map()) :: {:ok, ProviderStatus.t()} | {:error, term()}
  @callback install(map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback cancel(String.t(), context()) :: :ok | {:error, term()}

  @doc """
  Encodes one line of streaming input for a run started with the `live_input: true`
  provider option (see `Jido.Harness.Run.send_input/3`).
  """
  @callback live_input_line(input_id :: String.t(), text :: String.t()) :: binary()

  @optional_callbacks install: 2, cancel: 2, live_input_line: 2
end
