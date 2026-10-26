defmodule ForemanServer.TestSupport.FakeClaudeCli do
  @moduledoc """
  Stand-ins for the claude CLI that `ForemanServer.Approvals.ClaudeCli` probes (the one named by
  `FOREMAN_CLAUDE_CLI`). Started with `--permission-prompt-tool` and no value they print what the
  real CLI prints (commander's parse error, observed on claude 2.1.308 and the npm builds 0.2.60,
  1.0.0, 1.0.119 and 2.0.50) and exit 1:

    * `:known` - a CLI that has the flag;
    * `:unknown` - one that predates it.

  Every call appends its arguments, one line per call, to `<path>.argv`.
  """

  @doc "Write the fake as `<dir>/<name>`; `body` is `:known`, `:unknown` or the script's own text."
  @spec write!(Path.t(), String.t(), :known | :unknown | String.t()) :: Path.t()
  def write!(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\necho \"$*\" >> \"#{path}.argv\"\n" <> script(body))
    File.chmod!(path, 0o755)
    path
  end

  @doc "The arguments the fake at `path` was called with, one string per call."
  @spec calls(Path.t()) :: [String.t()]
  def calls(path) do
    case File.read(path <> ".argv") do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  @doc "Point `FOREMAN_CLAUDE_CLI` at `path` until the calling test exits."
  @spec use!(Path.t()) :: :ok
  def use!(path) do
    previous = System.get_env("FOREMAN_CLAUDE_CLI")
    System.put_env("FOREMAN_CLAUDE_CLI", path)

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: System.put_env("FOREMAN_CLAUDE_CLI", previous),
        else: System.delete_env("FOREMAN_CLAUDE_CLI")
    end)
  end

  defp script(:known),
    do: "echo \"error: option '--permission-prompt-tool <tool>' argument missing\" >&2\nexit 1\n"

  defp script(:unknown) do
    "echo \"error: unknown option '--permission-prompt-tool'\" >&2\n" <>
      "echo \"(Did you mean --permission-mode?)\" >&2\nexit 1\n"
  end

  defp script(text) when is_binary(text), do: text
end
