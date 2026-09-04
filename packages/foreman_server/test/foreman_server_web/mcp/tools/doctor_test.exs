defmodule ForemanServerWeb.MCP.Tools.DoctorTest do
  use ExUnit.Case, async: false

  alias ForemanServer.MCP.Tools
  alias ForemanServer.MCP.ToolError
  alias ForemanServerWeb.MCP.Tools.Doctor
  alias Jido.Harness.{Adapter, AdapterSpec, Capabilities, ProviderStatus}

  defmodule StubSupport do
    def status_for(provider) do
      Application.get_env(:foreman_server, :doctor_statuses, %{})
      |> Map.get(provider, {:error, :missing_status})
    end

    def provider_status(provider, installed) do
      %ProviderStatus{
        provider: provider,
        installed: installed,
        compatible: installed,
        authenticated: true,
        smoke_ready: installed,
        capabilities: %Capabilities{streaming?: true, resume?: true},
        executable: Atom.to_string(provider)
      }
    end
  end

  defmodule PiStub do
    @behaviour Adapter

    @impl true
    def spec do
      %AdapterSpec{
        provider: :pi,
        name: "doctor pi stub",
        executable: "pi",
        capabilities: %Capabilities{streaming?: true, resume?: true},
        normalized_options: [],
        provider_options: []
      }
    end

    @impl true
    def status(_config), do: StubSupport.status_for(:pi)

    @impl true
    def run(_request, _context), do: {:error, :not_implemented}
  end

  defmodule ClaudeStub do
    @behaviour Adapter

    @impl true
    def spec do
      %AdapterSpec{
        provider: :claude,
        name: "doctor claude stub",
        executable: "claude",
        capabilities: %Capabilities{streaming?: true, resume?: true},
        normalized_options: [],
        provider_options: []
      }
    end

    @impl true
    def status(_config), do: StubSupport.status_for(:claude)

    @impl true
    def run(_request, _context), do: {:error, :not_implemented}
  end

  setup do
    original_providers = Application.get_env(:jido_harness, :providers, %{})
    original_statuses = Application.get_env(:foreman_server, :doctor_statuses, %{})

    Application.put_env(:jido_harness, :providers, %{pi: PiStub, claude: ClaudeStub})
    Application.put_env(:foreman_server, :doctor_statuses, %{})

    on_exit(fn ->
      Application.put_env(:jido_harness, :providers, original_providers)
      Application.put_env(:foreman_server, :doctor_statuses, original_statuses)
    end)

    :ok
  end

  test "run/0 formats installed and missing providers" do
    put_status(:pi, {:ok, StubSupport.provider_status(:pi, true)})
    put_status(:claude, {:ok, StubSupport.provider_status(:claude, false)})

    assert {:ok, output} = Doctor.run()
    assert output =~ "Provider readiness"
    assert output =~ "✓ pi available"
    assert output =~ "✗ claude not found — install with: npm install -g @anthropic-ai/claude-code"
  end

  test "run(strict: true) returns provider_missing with the rendered report when any provider is missing" do
    put_status(:pi, {:ok, StubSupport.provider_status(:pi, true)})
    put_status(:claude, {:error, :missing})

    assert {:error, :provider_missing, output} = Doctor.run(strict: true)
    assert output =~ "Provider readiness"
    assert output =~ "✗ claude not found — install with: npm install -g @anthropic-ai/claude-code"
  end

  test "MCP tool registry exposes foreman_doctor and returns formatted output" do
    put_status(:pi, {:ok, StubSupport.provider_status(:pi, true)})
    put_status(:claude, {:ok, StubSupport.provider_status(:claude, true)})

    assert Enum.any?(Tools.list_tools(), &(&1.name == "foreman_doctor"))

    assert {:ok, %{output: output}} = Tools.call_tool("foreman_doctor", %{})
    assert output =~ "Provider readiness"
    assert output =~ "✓ pi available"
    assert output =~ "✓ claude available"
  end

  test "MCP tool strict mode returns provider missing error" do
    put_status(:pi, {:ok, StubSupport.provider_status(:pi, false)})
    put_status(:claude, {:ok, StubSupport.provider_status(:claude, true)})

    assert Tools.call_tool("foreman_doctor", %{strict: true}) ==
             {:error,
              %ToolError{
                code: "PROVIDER_MISSING",
                message: "One or more required providers are unavailable"
              }}
  end

  defp put_status(provider, value) do
    statuses = Application.get_env(:foreman_server, :doctor_statuses, %{})
    Application.put_env(:foreman_server, :doctor_statuses, Map.put(statuses, provider, value))
  end
end
