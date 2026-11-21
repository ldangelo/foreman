defmodule ForemanServer.PrReadySignalTest do
  # TRD-008: the head `run.pr.ready` records is the head GitHub names. These tests drive the
  # real command dispatch, event store and aggregate; only `gh` is scripted.
  use ExUnit.Case, async: false

  alias ForemanServer.PrReadySignal
  alias ForemanServer.TestSupport.PrReadyGithub
  alias ForemanServer.TestSupport.PrWatchSupport, as: Support

  @pr_url "https://github.com/acme/widgets/pull/808"

  setup do
    run = Support.start_run!(complete: true)
    on_exit(&PrReadySignal.clear_command_runner/0)
    %{run: run}
  end

  defp attrs(run, extra \\ %{}) do
    Map.merge(
      %{
        run_id: run.run_id,
        project_id: run.project_id,
        task_id: run.task_id,
        pr_url: @pr_url,
        branch_name: "foreman/#{run.run_id}/implement",
        base_branch: "main"
      },
      extra
    )
  end

  defp ready_events(run_id),
    do: run_id |> Support.run_events() |> Enum.filter(&(&1.event_type == "PrReady"))

  test "dispatches run.pr.ready with the head GitHub names, lower-cased", %{run: run} do
    h2 = PrReadyGithub.sha("h2")
    PrReadyGithub.install!(%{@pr_url => String.upcase(h2)})

    assert :ok = PrReadySignal.signal(attrs(run))
    assert_received {:pr_ready_gh, @pr_url}

    assert [ready] = ready_events(run.run_id)
    assert ready.data.head_sha == h2
    assert ready.data.pr_url == @pr_url
    assert ready.data.branch_name == "foreman/#{run.run_id}/implement"
    assert ready.data.base_branch == "main"
    refute Map.has_key?(ready.data, :repo_id)
  end

  test "a read GitHub fails is {:head_read_failed, reason} and appends no PrReady", %{run: run} do
    PrReadyGithub.install!(fn _ -> {:error, 4} end)

    assert {:error, {:head_read_failed, {:gh_failed, 4, _output}}} =
             PrReadySignal.signal(attrs(run))

    assert [] = ready_events(run.run_id)
  end

  test "a payload without a head is a failed read, never a PrReady", %{run: run} do
    PrReadySignal.set_command_runner(fn "gh", ["pr", "view" | _], _opts -> {"{}", 0} end)

    assert {:error, {:head_read_failed, {:gh_unexpected_payload, _}}} =
             PrReadySignal.signal(attrs(run))

    assert [] = ready_events(run.run_id)
  end

  test "a hung gh is {:head_read_failed, {:timeout, ms}} within the bound and appends no PrReady",
       %{run: run} do
    PrReadySignal.set_command_runner(fn "gh", ["pr", "view" | _], _opts ->
      Process.sleep(:infinity)
    end)

    started = System.monotonic_time(:millisecond)

    assert {:error, {:head_read_failed, {:timeout, 100}}} =
             PrReadySignal.signal(attrs(run), timeout_ms: 100)

    assert System.monotonic_time(:millisecond) - started < 5_000
    assert [] = ready_events(run.run_id)
  end

  test "a repeat is the same command: one PrReady, the head it first recorded", %{run: run} do
    PrReadyGithub.install!(%{@pr_url => PrReadyGithub.sha("first")})
    assert :ok = PrReadySignal.signal(attrs(run))

    PrReadyGithub.install!(%{@pr_url => PrReadyGithub.sha("moved")})
    assert :ok = PrReadySignal.signal(attrs(run))

    assert [ready] = ready_events(run.run_id)
    assert ready.data.head_sha == PrReadyGithub.sha("first")
  end

  test "a secondary repository signals under its own command id with its repo_id", %{run: run} do
    PrReadyGithub.install!(fn url -> PrReadyGithub.sha(url) end)
    other = "https://github.com/acme/other/pull/9"

    assert :ok = PrReadySignal.signal(attrs(run))
    assert :ok = PrReadySignal.signal(attrs(run, %{pr_url: other, repo_id: "b"}))
    assert :ok = PrReadySignal.signal(attrs(run, %{pr_url: other, repo_id: "b"}))

    assert [primary, secondary] = ready_events(run.run_id)
    refute Map.has_key?(primary.data, :repo_id)
    assert secondary.data.repo_id == "b"
    assert secondary.data.head_sha == PrReadyGithub.sha(other)
  end

  test "opts[:command_runner] overrides the installed runner for one call", %{run: run} do
    PrReadyGithub.install!(%{@pr_url => PrReadyGithub.sha("installed")})
    override = PrReadyGithub.runner(self(), %{@pr_url => PrReadyGithub.sha("override")})

    assert :ok = PrReadySignal.signal(attrs(run), command_runner: override)
    assert [ready] = ready_events(run.run_id)
    assert ready.data.head_sha == PrReadyGithub.sha("override")
  end
end
