defmodule ForemanServer.Coordinator.Tuning do
  @moduledoc """
  A project's coordinator tuning, read from its settings.

    * `propose_before_start` - ENFORCED: the Executor makes every thread it
      creates a proposal (an open task awaiting `task.approve`), whatever the
      model emitted.
    * `max_active_threads` - ENFORCED: a thread beyond the cap is rejected with
      `{:cap_exceeded, :active_threads, cap}`. (`set_tuning` also writes the
      project's `max_concurrent_runs`, which `project.reserve_run` enforces for
      every actor.)
    * `reuse_threads` - ENFORCED where a match exists (same `bead_id` or an
      explicit `reuse_thread_id`: `start_thread` becomes `route_followup`);
      otherwise ADVISORY, because "same area" is semantic.

  Unset settings fall back to `config :foreman_server, :coordinator`
  (`propose_before_start: false`, `reuse_threads: true`, no thread cap).
  """

  alias ForemanServer.ProjectionStore

  @type t :: %__MODULE__{
          propose_before_start: boolean(),
          max_active_threads: pos_integer() | nil,
          reuse_threads: boolean()
        }
  defstruct propose_before_start: false, max_active_threads: nil, reuse_threads: true

  @doc "Tuning of a project (defaults for an unknown one)."
  @spec read(String.t()) :: t()
  def read(project_id) when is_binary(project_id) do
    settings = ProjectionStore.project_settings(project_id)
    config = Application.get_env(:foreman_server, :coordinator, [])

    %__MODULE__{
      propose_before_start:
        setting(
          settings,
          :coordinator_propose_before_start,
          Keyword.get(config, :propose_before_start, false)
        ),
      max_active_threads:
        setting(
          settings,
          :coordinator_max_active_threads,
          Keyword.get(config, :max_active_threads)
        ),
      reuse_threads:
        setting(settings, :coordinator_reuse_threads, Keyword.get(config, :reuse_threads, true))
    }
  end

  defp setting(nil, _key, default), do: default

  defp setting(settings, key, default) do
    case Map.get(settings, key) do
      nil -> default
      value -> value
    end
  end
end
