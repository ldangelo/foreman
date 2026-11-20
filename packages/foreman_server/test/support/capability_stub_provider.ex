defmodule ForemanServer.Test.Support.CapabilityStubProvider do
  @moduledoc false
  # Throwaway `ForemanServer.TaskProvider` modules whose `capabilities/0` returns whatever a test
  # needs, malformed values included, so registry, projector and routing tests do not each carry
  # a 13-callback stub. Every module is uniquely named, so nothing is redefined between tests.
  #
  # Options:
  #   * `:capabilities` (required) - the exact term `capabilities/0` returns.
  #   * `:name` - what `name/0` returns (default `:capability_stub`).
  #   * `:available?` - what `available?/0` returns (default `true`).
  #   * `:preflight` - when given, the module also exports `preflight_database/2`, returning
  #     `:ok` or `{:error, %ProviderError{code: code}}` for `{:error, code}`.
  #
  # `claim/3`, `complete/3`, `fail/3` and `reopen/3` send `{callback, id, token, project_config}`
  # to the calling process, so a test can assert which config the provider was handed.

  @spec define!(keyword()) :: module()
  def define!(opts) do
    capabilities = Keyword.fetch!(opts, :capabilities)
    name = Keyword.get(opts, :name, :capability_stub)
    available? = Keyword.get(opts, :available?, true)
    module = Module.concat(__MODULE__, "Stub#{System.unique_integer([:positive])}")

    contents =
      quote do
        @behaviour ForemanServer.TaskProvider

        @impl true
        def name, do: unquote(Macro.escape(name))

        @impl true
        def capabilities, do: unquote(Macro.escape(capabilities))

        @impl true
        def available?, do: unquote(available?)

        @impl true
        def list_ready(_project_config, _opts), do: {:ok, []}

        @impl true
        def get(_id, _project_config),
          do: {:error, ForemanServer.TaskProviders.ProviderError.new("test", "unavailable")}

        @impl true
        def claim(id, token, project_config) do
          send(self(), {:claim, id, token, project_config})
          :ok
        end

        @impl true
        def complete(id, token, project_config) do
          send(self(), {:complete, id, token, project_config})
          :ok
        end

        @impl true
        def fail(id, token, project_config) do
          send(self(), {:fail, id, token, project_config})
          :ok
        end

        @impl true
        def reopen(id, token, project_config) do
          send(self(), {:reopen, id, token, project_config})
          :ok
        end

        @impl true
        def set_priority(_id, _priority, _project_config), do: :ok

        @impl true
        def create(_project_id, _attrs),
          do: {:error, ForemanServer.TaskProviders.ProviderError.new("test", "unavailable")}

        @impl true
        def add_dependency(_id, _depends_on_id, _project_config), do: :ok

        @impl true
        def annotate(_id, _body, _project_config), do: {:error, :not_implemented}
      end

    Module.create(
      module,
      [contents, preflight_clause(opts[:preflight])],
      Macro.Env.location(__ENV__)
    )

    module
  end

  defp preflight_clause(nil), do: nil

  defp preflight_clause(:ok) do
    quote do
      def preflight_database(_database_path, _opts), do: :ok
    end
  end

  defp preflight_clause({:error, code}) do
    quote do
      def preflight_database(_database_path, _opts),
        do:
          {:error,
           ForemanServer.TaskProviders.ProviderError.new(unquote(code), "preflight failed")}
    end
  end
end
