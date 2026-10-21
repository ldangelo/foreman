defmodule ForemanServer.Jobsite.SpecProjectDefaultsTest do
  # A jobsite spec without agent.model / agent.effort inherits the project's
  # thread_model / thread_effort. The provider is never defaulted. The resolved
  # Agent is what `Executor.start_payload/2` persists in `JobsiteStarted`.
  use ExUnit.Case, async: false

  alias ForemanServer.Jobsite.{Agent, Error, Spec}
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    :ok
  end

  defp register(id, config) do
    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectRegistered",
          payload: %{project_id: id, path: "/srv/repos/#{id}", config: config}
        }
      ])
  end

  defp spec(id, agent),
    do: %{"project_id" => id, "prompt" => "Fix it", "agent" => agent}

  defp agent_of(result) do
    assert {:ok, opts} = result
    Keyword.fetch!(opts, :agent)
  end

  test "a spec with only provider records the project's model and effort" do
    register("pd-1", %{thread_model: "proj-m", thread_effort: "high"})

    assert %Agent{provider: :claude, model: "proj-m", effort: :high} =
             agent_of(Spec.from_json(spec("pd-1", %{"provider" => "claude"})))
  end

  test "explicit agent.model and agent.effort win" do
    register("pd-2", %{thread_model: "proj-m", thread_effort: "high"})

    assert %Agent{model: "explicit-m", effort: :low} =
             agent_of(
               Spec.from_json(
                 spec("pd-2", %{
                   "provider" => "claude",
                   "model" => "explicit-m",
                   "effort" => "low"
                 })
               )
             )
  end

  test "a project without settings behaves as before: model stays required, effort nil" do
    register("pd-3", %{})

    assert {:error, %Error{code: :spec_agent_invalid}} =
             Spec.from_json(spec("pd-3", %{"provider" => "claude"}))

    assert %Agent{effort: nil} =
             agent_of(Spec.from_json(spec("pd-3", %{"provider" => "claude", "model" => "m"})))
  end

  test "the provider is never defaulted from the project" do
    register("pd-4", %{thread_model: "proj-m"})

    assert {:error, %Error{code: :spec_provider_invalid}} =
             Spec.from_json(spec("pd-4", %{}))
  end

  test "an invalid explicit effort is still rejected even when the project has one" do
    register("pd-5", %{thread_model: "proj-m", thread_effort: "high"})

    assert {:error, %Error{code: :spec_agent_invalid}} =
             Spec.from_json(spec("pd-5", %{"provider" => "claude", "effort" => "turbo"}))
  end
end
