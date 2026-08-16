defmodule ForemanServer.TestSupport.ParityStubs do
  @moduledoc false

  alias ForemanServer.AgentRuntime.Adapters.PiAdapter
  alias Jido.Harness.{Adapter, AdapterSpec, Capabilities, Event, ProviderStatus}

  @prompt "Create the parity fixture files and summary report."
  @text "fixture-ok"
  @artifact_path "artifacts/summary.txt"
  @package_json ~s({\n  "name": "test"\n}\n)
  @artifact_text "parity summary\n"
  @readme_text "# Parity Fixture\n"

  def prompt, do: @prompt
  def text, do: @text
  def artifact_path, do: @artifact_path

  def fixture_files do
    %{
      "README.md" => @readme_text,
      "package.json" => @package_json,
      @artifact_path => @artifact_text
    }
  end

  def tool_events do
    [
      %{
        type: :tool_call,
        payload: %{
          "call_id" => "read-readme",
          "name" => "read_file",
          "input" => %{"path" => "README.md"}
        }
      },
      %{
        type: :tool_result,
        payload: %{
          "call_id" => "read-readme",
          "name" => "read_file",
          "output" => @readme_text,
          "is_error" => false
        }
      },
      %{
        type: :tool_call,
        payload: %{
          "call_id" => "write-package-json",
          "name" => "write_file",
          "input" => %{"path" => "package.json", "content" => @package_json}
        }
      },
      %{
        type: :tool_result,
        payload: %{
          "call_id" => "write-package-json",
          "name" => "write_file",
          "output" => "wrote package.json",
          "is_error" => false
        }
      },
      %{
        type: :tool_call,
        payload: %{
          "call_id" => "write-summary",
          "name" => "write_file",
          "input" => %{"path" => @artifact_path, "content" => @artifact_text}
        }
      },
      %{
        type: :tool_result,
        payload: %{
          "call_id" => "write-summary",
          "name" => "write_file",
          "output" => "wrote #{@artifact_path}",
          "is_error" => false
        }
      }
    ]
  end

  def fixture_metadata(worktree_dir) when is_binary(worktree_dir) do
    %{
      worktree_dir: worktree_dir,
      files: fixture_files(),
      artifact_paths: [@artifact_path],
      tool_events: tool_events()
    }
  end

  def setup!(test_pid \\ self()) do
    original_foreman = Application.get_env(:foreman_server, :jido_harness)
    original_providers = Application.get_env(:jido_harness, :providers)
    original_test_pid = Application.get_env(:jido_harness, :adapter_test_pid)
    original_path = System.get_env("PATH")

    bin_dir = Path.join(System.tmp_dir!(), "parity-stubs-bin-#{System.unique_integer([:positive])}")
    File.mkdir_p!(bin_dir)
    write_executable!(Path.join(bin_dir, "pi"))
    write_executable!(Path.join(bin_dir, "claude"))

    Application.put_env(:foreman_server, :jido_harness, enabled: true)
    Application.put_env(:jido_harness, :providers, %{pi: __MODULE__.PiJidoAdapterStub, claude: __MODULE__.ClaudeJidoAdapterStub})
    Application.put_env(:jido_harness, :adapter_test_pid, test_pid)
    System.put_env("PATH", bin_dir <> ":" <> (original_path || ""))

    {:ok, _} = Application.ensure_all_started(:meck)
    :meck.new(PiAdapter, [:no_link, :passthrough])

    :meck.expect(PiAdapter, :execute, fn request, opts ->
      pi_execute(request, opts, test_pid)
    end)

    ExUnit.Callbacks.on_exit({__MODULE__, make_ref()}, fn ->
      restore_env(:foreman_server, :jido_harness, original_foreman)
      restore_env(:jido_harness, :providers, original_providers)
      restore_env(:jido_harness, :adapter_test_pid, original_test_pid)
      restore_path(original_path)

      if :meck.validate(PiAdapter) do
        :meck.unload(PiAdapter)
      end

      File.rm_rf!(bin_dir)
    end)

    :ok
  end

  def pi_execute(%{prompt: @prompt, context: context} = request, opts, test_pid) when is_map(context) do
    worktree_dir = working_directory!(context)
    metadata = materialize_fixture!(worktree_dir)

    if test_pid do
      send(test_pid, {:parity_stub_run, :pi, request, opts, metadata})
    end

    # Return only the adapter-level metadata so it matches
    # `RunResult.normalize/1`'s shape exactly. Rich fixture data (files,
    # artifact paths, tool events) flows to other tests via the
    # `:parity_stub_run` message above.
    {:ok, @text, %{provider: :pi, adapter: :pi}}
  end

  def pi_execute(request, _opts, _test_pid) do
    {:error, {:unexpected_prompt, Map.get(request, :prompt)}}
  end

  def canonical_events(provider \\ :pi) do
    Enum.map(tool_events(), fn %{type: type, payload: payload} ->
      Event.new!(provider: provider, type: type, payload: payload)
    end) ++
      [
        Event.new!(provider: provider, type: :output_text_final, payload: %{"text" => @text}),
        Event.new!(provider: provider, type: :run_completed, payload: %{})
      ]
  end

  def materialize_fixture!(worktree_dir) when is_binary(worktree_dir) do
    File.mkdir_p!(worktree_dir)

    for {relative_path, content} <- fixture_files() do
      full_path = Path.join(worktree_dir, relative_path)
      File.mkdir_p!(Path.dirname(full_path))
      File.write!(full_path, content)
    end

    fixture_metadata(worktree_dir)
  end

  defp working_directory!(context) do
    Map.get(context, :working_directory) ||
      Map.get(context, "working_directory") ||
      raise ArgumentError, "expected :working_directory in parity stub context"
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp restore_path(nil), do: System.delete_env("PATH")
  defp restore_path(value), do: System.put_env("PATH", value)

  defp write_executable!(path) do
    File.write!(path, "#!/bin/sh\nexit 0\n")
    File.chmod!(path, 0o755)
  end

  defmodule PiJidoAdapterStub do
    @moduledoc false
    @behaviour Adapter

    @impl true
    def spec do
      %AdapterSpec{
        provider: :pi,
        name: "TRD-006 parity stub",
        executable: "stub",
        capabilities: %Capabilities{streaming?: true, tool_calls?: true, tool_results?: true, resume?: true},
        normalized_options: [],
        provider_options: []
      }
    end

    @impl true
    def status(_config) do
      {:ok,
       %ProviderStatus{
         provider: :pi,
         installed: true,
         compatible: true,
         authenticated: true,
         smoke_ready: true,
         capabilities: %Capabilities{streaming?: true, tool_calls?: true, tool_results?: true, resume?: true},
         executable: "stub"
       }}
    end

    @impl true
    def run(request, context) do
      prompt = Map.get(request, :prompt)
      cwd =
        Map.get(request, :cwd) || Map.get(context, :working_directory) || File.cwd!()

      provider = Map.get(context, :provider, Map.get(request, :provider, :pi))
      expected_prompt = ForemanServer.TestSupport.ParityStubs.prompt()

      case prompt do
        ^expected_prompt ->
          metadata = ForemanServer.TestSupport.ParityStubs.materialize_fixture!(cwd)

          if pid = Application.get_env(:jido_harness, :adapter_test_pid) do
            send(pid, {:parity_stub_run, :jido, request, context, metadata})
          end

          {:ok, ForemanServer.TestSupport.ParityStubs.canonical_events(provider)}

        other ->
          {:error, {:unexpected_prompt, other}}
      end
    end

  end

  defmodule ClaudeJidoAdapterStub do
    @moduledoc false
    @behaviour Adapter

    @impl true
    def spec do
      %AdapterSpec{
        provider: :claude,
        name: "TRD-006 parity stub",
        executable: "stub",
        capabilities: %Capabilities{streaming?: true, tool_calls?: true, tool_results?: true, resume?: true},
        normalized_options: [],
        provider_options: []
      }
    end

    @impl true
    def status(_config) do
      {:ok,
       %ProviderStatus{
         provider: :claude,
         installed: true,
         compatible: true,
         authenticated: true,
         smoke_ready: true,
         capabilities: %Capabilities{streaming?: true, tool_calls?: true, tool_results?: true, resume?: true},
         executable: "stub"
       }}
    end

    @impl true
    def run(request, context), do: PiJidoAdapterStub.run(request, context)
  end
end
