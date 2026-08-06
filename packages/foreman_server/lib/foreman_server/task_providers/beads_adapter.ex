defmodule ForemanServer.TaskProviders.BeadsAdapter do
  @moduledoc "Production TaskProvider implementation backed by the `br` CLI. Unimplemented callbacks (list_ready, get, claim, complete, fail, reopen, set_priority, add_dependency) return {:error, :not_implemented} until TRD-011..TRD-018 fill them in."

  @behaviour ForemanServer.TaskProvider

  alias ForemanServer.TaskProviders.BeadsAdapter.CodeMap

  @runner Application.compile_env(
            :foreman_server,
            :br_runner,
            ForemanServer.TaskProviders.SystemBrRunner
          )

  @impl true
  def name, do: :beads

  @impl true
  def capabilities do
    %{
      provider_id: :beads,
      contract_version: "br.capabilities.v1",
      supports: [
        :claim,
        :close,
        :reopen,
        :annotate,
        :set_priority,
        :set_assignee,
        :list_dependencies,
        :add_dependency,
        :remove_dependency
      ]
    }
  end

  @impl true
  def available? do
    case System.find_executable("br") do
      nil -> false
      _path -> true
    end
  end

  @impl true
  def list_ready(_actor, _opts), do: {:error, :not_implemented}

  @impl true
  def get(_id, _opts), do: {:error, :not_implemented}

  @impl true
  def claim(_id, _actor, _opts), do: {:error, :not_implemented}

  @impl true
  def complete(_id, _actor, _opts), do: {:error, :not_implemented}

  @impl true
  def fail(_id, _actor, _opts), do: {:error, :not_implemented}

  @impl true
  def reopen(_id, _actor, _opts), do: {:error, :not_implemented}

  @impl true
  def set_priority(_id, _priority, _opts), do: {:error, :not_implemented}

  @impl true
  def add_dependency(_id, _depends_on_id, _opts), do: {:error, :not_implemented}

  @doc false
  def __runner__, do: @runner

  @doc false
  def __code_map__, do: CodeMap

  @doc false
  def behaviour_info(:callbacks), do: ForemanServer.TaskProvider.behaviour_info(:callbacks)

  def behaviour_info(:optional_callbacks), do: []
end
