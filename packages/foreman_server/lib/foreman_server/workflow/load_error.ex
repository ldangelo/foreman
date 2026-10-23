defmodule ForemanServer.Workflow.LoadError do
  @moduledoc """
  Typed record of a workflow manifest the catalog REFUSED to load (AGENTS.md
  §5.1): which file, at which stage, and why.

  A manifest that fails validation is still refused — nothing here makes an
  invalid workflow startable. What this struct prevents is the refusal being
  invisible: `Catalog.invalid/0` hands these to `foreman doctor`, the
  coordinator's workflow list, and `foreman_workflow_list`, so an operator sees
  "lvclaude.yaml is invalid because ..." instead of "not an available workflow".

  `stage`:

    * `:validation` — `Interpreter.load/1` refused the file (unreadable, unparsable
      YAML, or a rule such as `models`/`worktree`/`commit`);
    * `:resolution` — the file validated but the catalog could not resolve it
      (`Catalog.resolve_workflow/3`).

  `serving_previous` is true when an earlier VALID version of the same file is
  still held in the catalog: a reload that fails keeps serving the last good
  snapshot, and the operator must be told the edit did not take effect.
  """

  @derive Jason.Encoder
  @enforce_keys [:filename, :path, :stage, :message, :file_digest, :serving_previous]
  defstruct [:filename, :path, :stage, :message, :file_digest, :serving_previous]

  @type stage :: :validation | :resolution
  @type t :: %__MODULE__{
          filename: String.t(),
          path: Path.t(),
          stage: stage(),
          message: String.t(),
          file_digest: String.t() | nil,
          serving_previous: boolean()
        }

  @doc """
  Build the error from the reason `Catalog` got back for `path`. Only the two
  shapes `Interpreter.load/1` and `Catalog.resolve_workflow/3` produce are
  accepted; anything else is a programming error and raises rather than being
  filed under a made-up stage (§5.2).
  """
  @spec new(Path.t(), term(), String.t() | nil, boolean()) :: t()
  def new(path, {:manifest_load_failed, _path, message}, file_digest, serving_previous)
      when is_binary(path) and is_binary(message) and is_boolean(serving_previous) do
    build(path, :validation, message, file_digest, serving_previous)
  end

  def new(path, {:resolution_failed, message}, file_digest, serving_previous)
      when is_binary(path) and is_binary(message) and is_boolean(serving_previous) do
    build(path, :resolution, message, file_digest, serving_previous)
  end

  @doc "String-keyed, JSON-ready view shared by the doctor row and the MCP list."
  @spec to_map(t()) :: %{String.t() => term()}
  def to_map(%__MODULE__{} = error) do
    %{
      "filename" => error.filename,
      "path" => error.path,
      "stage" => Atom.to_string(error.stage),
      "reason" => error.message,
      "serving_previous" => error.serving_previous
    }
  end

  @doc "One-line operator text for a coordinator prompt or a refusal message."
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{} = error) do
    suffix =
      if error.serving_previous,
        do: " (the previous valid version is still being served)",
        else: ""

    error.message <> suffix
  end

  defp build(path, stage, message, file_digest, serving_previous) do
    %__MODULE__{
      filename: Path.basename(path),
      path: path,
      stage: stage,
      message: message,
      file_digest: file_digest,
      serving_previous: serving_previous
    }
  end
end
