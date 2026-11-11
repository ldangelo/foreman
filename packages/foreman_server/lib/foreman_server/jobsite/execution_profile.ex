defmodule ForemanServer.Jobsite.ExecutionProfile do
  @moduledoc """
  What an execution backend enforces for one launch, and what it does not
  (REQ-006, AC-006-1).

  A profile names the `backend` and, for each of `filesystem`, `network`,
  `credentials` and `cleanup`, whether that property is `:enforced` or
  `{:unenforced, reason}`. An unenforced property is a recorded fact, never a
  silent default: nothing in a launch may claim a guarantee its backend does not
  give.

  The backend value is defined HERE, once (`host_backend/0`,
  `docker_backend/0`); `RunExecutor` and `NetworkPolicy` take it from these
  functions and name no backend of their own.

    * Host workflow (`RunExecutor`'s door). Agents run on the server host, so
      filesystem and network are always unenforced: the `VfsIsolation` registry
      is not an enforcement point (`allowed?/2` has no caller outside its tests,
      `RunExecutor.bind_vfs/2` is fail-open) and `NetworkPolicy` cannot enforce
      on the host. This holds whatever options are passed: a host profile's
      filesystem is NEVER `:enforced`.
    * Docker jobsite. The filesystem is the sandbox container's: only the
      mounted host paths are visible, so the profile carries exactly the mounts
      it is given (`mounts`) and is enforced unless one of them is the host
      root. The network is enforced where `NetworkPolicy.network_enforced_on/0`
      says it is.

  Credentials are unenforced on both backends here: run-scoped credentials
  belong to PRD-2026-aba4b79c (native execution telemetry). Cleanup follows the
  worktree spec's `cleanup`. On the host door it is NEVER enforced: the executor
  removes the worktree only on its own finish paths, a server crash skips them,
  and boot reconciliation reclaims a worktree only for a terminal run with a clean
  checkout. On the docker jobsite the spec maps directly (`:always` enforced;
  `:on_success`, `:never` and a run without a worktree are not).

  `to_map/1` is the recorded form: plain maps (`%{state:, reason:}` per
  property, the backend as a string), so the value survives Erlang-term storage,
  JSON storage and the codec's atom-or-string key decode. `ProjectionStore`
  normalises it back to one atom-keyed shape.
  """

  alias ForemanServer.Jobsite.NetworkPolicy

  @host_backend :host_workflow
  @docker_backend :docker_jobsite

  @type backend :: :host_workflow | :docker_jobsite
  @type property :: :enforced | {:unenforced, String.t()}
  @type cleanup_spec :: :always | :on_success | :never | :none | term()
  @type t :: %__MODULE__{
          backend: backend(),
          filesystem: property(),
          network: property(),
          credentials: property(),
          cleanup: property(),
          mounts: [String.t()]
        }

  @enforce_keys [:backend, :filesystem, :network, :credentials, :cleanup]
  defstruct [:backend, :filesystem, :network, :credentials, :cleanup, mounts: []]

  @properties [:filesystem, :network, :credentials, :cleanup]

  @doc "The backend every `RunExecutor` launch runs on."
  @spec host_backend() :: :host_workflow
  def host_backend, do: @host_backend

  @doc "The backend of the docker jobsite."
  @spec docker_backend() :: :docker_jobsite
  def docker_backend, do: @docker_backend

  @doc """
  Resolve the profile of `backend`.

  Options: `:cleanup`, the worktree spec's cleanup (`:always`, `:on_success`,
  `:never`, or `:none` for a run with no worktree; default `:never`), and, for
  the docker jobsite only, `:mounts`, the host paths bind-mounted into the
  sandbox.
  """
  @spec resolve(backend(), keyword()) :: t()
  def resolve(backend, opts \\ [])

  def resolve(@host_backend, opts) do
    %__MODULE__{
      backend: @host_backend,
      filesystem:
        {:unenforced,
         "the agent runs on the server host; the VfsIsolation registry is not an enforcement point"},
      network: network(@host_backend),
      credentials: credentials(),
      cleanup: host_cleanup(Keyword.get(opts, :cleanup, :never))
    }
  end

  def resolve(@docker_backend, opts) do
    mounts = opts |> Keyword.get(:mounts, []) |> List.wrap() |> Enum.filter(&is_binary/1)

    %__MODULE__{
      backend: @docker_backend,
      filesystem: docker_filesystem(mounts),
      network: network(@docker_backend),
      credentials: credentials(),
      cleanup: cleanup(Keyword.get(opts, :cleanup, :never)),
      mounts: mounts
    }
  end

  @doc """
  The recorded form: `%{backend: "host_workflow", filesystem: %{state:, reason:},
  ...}`. Plain maps and strings only.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = profile) do
    Map.new(@properties, fn key -> {key, property_map(Map.fetch!(profile, key))} end)
    |> Map.put(:backend, Atom.to_string(profile.backend))
  end

  defp property_map(:enforced), do: %{state: "enforced", reason: nil}
  defp property_map({:unenforced, reason}), do: %{state: "unenforced", reason: reason}

  defp network(backend) do
    if backend in NetworkPolicy.network_enforced_on() do
      :enforced
    else
      {:unenforced,
       "the #{backend} backend cannot enforce environment.network; it runs on the server host"}
    end
  end

  defp credentials do
    {:unenforced,
     "run-scoped credentials are not enforced by the execution backend (PRD-2026-aba4b79c)"}
  end

  defp docker_filesystem(mounts) do
    if Enum.any?(mounts, &host_root?/1) do
      {:unenforced, "the host root is mounted into the sandbox"}
    else
      :enforced
    end
  end

  defp host_root?(path), do: Path.expand(path) == "/"

  # The host door reclaims a worktree only on the executor's own finish paths, so
  # no spec value makes host cleanup a guarantee: a server crash mid-phase skips
  # them, and boot reconciliation reclaims a worktree only for a terminal run with
  # a clean checkout (a dirty one is preserved). `:always` is therefore recorded
  # unenforced too, with the reason that says so.
  defp host_cleanup(:always) do
    {:unenforced,
     "removed by the executor on its own finish paths; a server crash leaves the worktree, " <>
       "and boot reclaims it only for a terminal run with a clean worktree"}
  end

  defp host_cleanup(spec), do: cleanup(spec)

  defp cleanup(:always), do: :enforced

  defp cleanup(:on_success),
    do: {:unenforced, "the worktree is reclaimed on success only; a failed run's is kept"}

  defp cleanup(:never),
    do: {:unenforced, "the worktree is kept until the run is deleted (worktree cleanup: never)"}

  defp cleanup(:none), do: {:unenforced, "the run has no worktree to clean up"}

  defp cleanup(other),
    do: {:unenforced, "the worktree cleanup policy #{inspect(other)} is not recognised"}
end
