defmodule ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapterParityTest do
  @moduledoc """
  TRD-006 parity test: given the same prompt, `PiAdapter` and
  `JidoHarnessAdapter` must produce equivalent persisted outcomes.

  Both adapters are stubbed hermetically — no `pi` binary on the test
  runner, no network, no real Claude or pi provider. The test is purely
  additive and does not touch any production module.

  Stubbing is centralized in `ForemanServer.TestSupport.ParityStubs`,
  which:

    * registers `Jido.Harness.Adapter` behaviour stubs for `:pi`/`:claude`
      via `Application.put_env(:jido_harness, :providers, ...)` — the
      same env key the existing `jido_harness_adapter_test.exs` uses,
    * replaces `PiAdapter.execute/2` via `:meck` so it returns the
      canonical fixture,
    * materializes the canonical fixture file set (`README.md`,
      `package.json`, `artifacts/summary.txt`) inside the worktree dir
      passed via `request.context.working_directory`,
    * records canonical tool events at the persisted boundary via
      `send/2` so the test can compare event ordering.

  Parity assertions:

    1. Text equivalence — the `text` field of the `:ok` tuple.
    2. Same file set produced in each adapter's worktree.
    3. Same tool-event ordering at the persisted boundary.
    4. Same artifact locations (`artifacts/summary.txt`).

  Metadata maps are NOT asserted to be identical — `PiAdapter` returns
  `%{provider: :pi, adapter: :pi}` while `JidoHarnessAdapter` returns
  `%{provider: :pi, adapter: :jido_harness}`. The parity contract is on
  text, files, and events; the `adapter:` key is intentionally distinct
  so consumers can tell which path produced the result.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime.Adapters.{JidoHarnessAdapter, PiAdapter}
  alias ForemanServer.TestSupport.ParityStubs

  setup do
    ParityStubs.setup!()

    pi_worktree = tmp_worktree("pi")
    jido_worktree = tmp_worktree("jido")
    File.mkdir_p!(pi_worktree)
    File.mkdir_p!(jido_worktree)

    on_exit(fn ->
      File.rm_rf!(pi_worktree)
      File.rm_rf!(jido_worktree)
    end)

    %{pi_worktree: pi_worktree, jido_worktree: jido_worktree}
  end

  test "PiAdapter and JidoHarnessAdapter produce the same text output for the same prompt",
       %{pi_worktree: pi_worktree, jido_worktree: jido_worktree} do
    pi_request = %{prompt: ParityStubs.prompt(), context: %{working_directory: pi_worktree}}
    assert {:ok, pi_text, pi_meta} = PiAdapter.execute(pi_request, [])

    jido_request = %{prompt: ParityStubs.prompt(), context: %{provider: :pi, working_directory: jido_worktree}}
    assert {:ok, jido_text, jido_meta} = JidoHarnessAdapter.execute(jido_request, [])

    # Text parity at the persisted boundary.
    assert pi_text == jido_text
    assert pi_text == ParityStubs.text()

    # Metadata intentionally differs by `adapter:` key — that is the
    # signal downstream consumers use to tell which path produced the
    # result. Both paths return the same provider.
    assert pi_meta.provider == jido_meta.provider
    assert pi_meta == %{provider: :pi, adapter: :pi}
    assert jido_meta == %{provider: :pi, adapter: :jido_harness}
  end

  test "PiAdapter and JidoHarnessAdapter produce the same file set",
       %{pi_worktree: pi_worktree, jido_worktree: jido_worktree} do
    pi_request = %{prompt: ParityStubs.prompt(), context: %{working_directory: pi_worktree}}
    assert {:ok, _, _} = PiAdapter.execute(pi_request, [])

    jido_request = %{prompt: ParityStubs.prompt(), context: %{provider: :pi, working_directory: jido_worktree}}
    assert {:ok, _, _} = JidoHarnessAdapter.execute(jido_request, [])

    expected_files = ParityStubs.fixture_metadata(pi_worktree).files

    assert snapshot_worktree(pi_worktree) == expected_files
    assert snapshot_worktree(jido_worktree) == expected_files
    assert snapshot_worktree(pi_worktree) == snapshot_worktree(jido_worktree)
  end

  test "PiAdapter and JidoHarnessAdapter emit the same tool event ordering",
       %{pi_worktree: pi_worktree, jido_worktree: jido_worktree} do
    pi_request = %{prompt: ParityStubs.prompt(), context: %{working_directory: pi_worktree}}
    assert {:ok, _, _} = PiAdapter.execute(pi_request, [])
    assert_receive {:parity_stub_run, :pi, _pi_req, _pi_opts, pi_meta}

    jido_request = %{prompt: ParityStubs.prompt(), context: %{provider: :pi, working_directory: jido_worktree}}
    assert {:ok, _, _} = JidoHarnessAdapter.execute(jido_request, [])
    assert_receive {:parity_stub_run, :jido, _jido_req, _jido_ctx, jido_meta}

    expected_events = ParityStubs.tool_events()

    assert pi_meta.tool_events == expected_events
    assert jido_meta.tool_events == expected_events
    assert pi_meta.tool_events == jido_meta.tool_events
  end

  test "PiAdapter and JidoHarnessAdapter write artifacts to the same location",
       %{pi_worktree: pi_worktree, jido_worktree: jido_worktree} do
    pi_request = %{prompt: ParityStubs.prompt(), context: %{working_directory: pi_worktree}}
    assert {:ok, _, _} = PiAdapter.execute(pi_request, [])
    assert_receive {:parity_stub_run, :pi, _, _, pi_meta}

    jido_request = %{prompt: ParityStubs.prompt(), context: %{provider: :pi, working_directory: jido_worktree}}
    assert {:ok, _, _} = JidoHarnessAdapter.execute(jido_request, [])
    assert_receive {:parity_stub_run, :jido, _, _, jido_meta}

    assert pi_meta.artifact_paths == jido_meta.artifact_paths
    assert pi_meta.artifact_paths == [ParityStubs.artifact_path()]

    [artifact_rel] = pi_meta.artifact_paths
    pi_artifact = Path.join(pi_worktree, artifact_rel)
    jido_artifact = Path.join(jido_worktree, artifact_rel)

    assert File.exists?(pi_artifact)
    assert File.exists?(jido_artifact)
    assert File.read!(pi_artifact) == File.read!(jido_artifact)
  end

  defp tmp_worktree(tag) do
    Path.join(System.tmp_dir!(), "parity-#{tag}-#{System.unique_integer([:positive])}")
  end

  defp snapshot_worktree(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Map.new(fn path ->
      {Path.relative_to(path, root), File.read!(path)}
    end)
  end
end