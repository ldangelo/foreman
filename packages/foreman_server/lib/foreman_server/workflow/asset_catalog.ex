defmodule ForemanServer.Workflow.AssetCatalog do
  @moduledoc """
  Locates installed workflow assets (YAML manifests + Markdown prompts).

  An `AssetCatalog` is rooted at a workflow install directory; manifests live
  in the directory itself and prompts are resolved from `prompts/` next to it.
  Returns deterministic paths so the same workflow always resolves to the same
  on-disk artifact regardless of caller process.
  """

  alias ForemanServer.Workflow.Interpreter

  @type t :: %__MODULE__{
          root: Path.t(),
          prompts_dir: Path.t()
        }

  defstruct [:root, :prompts_dir]

  @spec new(Path.t()) :: t()
  def new(root) when is_binary(root) do
    %__MODULE__{
      root: root,
      prompts_dir: Path.join(root, "prompts")
    }
  end

  @doc "Default install root: `~/.foreman/workflows`."
  @spec default() :: t()
  def default do
    home = System.fetch_env!("HOME")
    new(Path.join([home, ".foreman", "workflows"]))
  end

  @doc "List every installed workflow manifest path (sorted for determinism)."
  @spec manifests(t()) :: [Path.t()]
  def manifests(%__MODULE__{root: root}) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".yaml"))
        |> Enum.sort()
        |> Enum.map(&Path.join(root, &1))

      {:error, _} ->
        []
    end
  end

  @doc "Load a workflow manifest by filename (e.g. `\"implement.yaml\"`)."
  @spec load(t(), String.t()) :: {:ok, map()} | {:error, term()}
  def load(%__MODULE__{root: root} = catalog, filename) when is_binary(filename) do
    path = Path.join(root, filename)

    try do
      case Interpreter.load!(path) do
        {:ok, workflow} ->
          resolved = %{
            name: workflow["name"],
            description: workflow["description"],
            phases:
              Enum.map(workflow["phases"], fn phase ->
                phase
                |> Map.put(:prompt_path, resolve_prompt(catalog, phase["prompt"]))
                |> Map.put(:artifact_template, phase["artifact"])
              end),
            manifest_path: path,
            digest: digest(path)
          }

          {:ok, resolved}

        {:error, reason} ->
          {:error, {:invalid_manifest, filename, reason}}
      end
    rescue
      e in [File.Error, ArgumentError, KeyError, Workflow.MissingRequiredPhaseError] ->
        {:error, {:manifest_load_failed, filename, Exception.message(e)}}
    end
  end

  @doc "Resolve a prompt relative to the catalog's prompts directory."
  @spec resolve_prompt(t(), String.t() | nil) :: Path.t() | nil
  def resolve_prompt(%__MODULE__{prompts_dir: prompts_dir}, nil), do: nil

  def resolve_prompt(%__MODULE__{prompts_dir: prompts_dir}, prompt) when is_binary(prompt) do
    Path.join(prompts_dir, prompt)
  end

  @doc "Compute a stable 16-char hex digest of the manifest file on disk."
  @spec digest(Path.t()) :: String.t() | nil
  def digest(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} ->
        <<hex::binary-size(16), _::binary>> = ForemanServer.Identity.sha256(contents)
        hex

      {:error, _} ->
        nil
    end
  end
end