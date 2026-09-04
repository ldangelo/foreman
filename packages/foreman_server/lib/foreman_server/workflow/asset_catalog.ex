defmodule ForemanServer.Workflow.AssetCatalog do
  @moduledoc """
  Resolves installed workflow asset paths.

  An `AssetCatalog` is a *path helper* only — it does not parse YAML or hold
  loaded workflow state. The supervised `ForemanServer.Workflow.Catalog`
  process owns the parsed snapshots; this module exists so callers can
  resolve manifest and prompt paths against an explicit install root.
  """

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
    new(Path.join([System.user_home!(), ".foreman", "workflows"]))
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

  @doc "List every installed prompt file path under `prompts/`, sorted for determinism."
  @spec prompts(t()) :: [Path.t()]
  def prompts(%__MODULE__{prompts_dir: prompts_dir}) do
    case File.ls(prompts_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.sort()
        |> Enum.map(&Path.join(prompts_dir, &1))

      {:error, _} ->
        []
    end
  end

  @doc "Resolve a prompt relative to the catalog's prompts directory."
  @spec resolve_prompt(t(), String.t() | nil) :: Path.t() | nil
  def resolve_prompt(%__MODULE__{prompts_dir: _prompts_dir}, nil), do: nil

  def resolve_prompt(%__MODULE__{prompts_dir: prompts_dir}, prompt) when is_binary(prompt) do
    Path.join(prompts_dir, prompt)
  end

  @doc "Compute a stable 16-char hex digest of the manifest file on disk."
  @spec digest(Path.t()) :: String.t() | nil
  def digest(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} ->
        :crypto.hash(:sha256, contents)
        |> Base.encode16(case: :lower)
        |> binary_part(0, 16)

      {:error, _} ->
        nil
    end
  end
end
