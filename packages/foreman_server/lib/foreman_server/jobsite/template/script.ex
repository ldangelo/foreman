defmodule ForemanServer.Jobsite.Template.Script do
  @moduledoc """
  Renders the two files of a generated template from a spec `Spec.from_json/2` has accepted: the
  runnable `<name>.exs` and the prompt file it reads.

  The script is a client of the Remote Jobsite API written against `Foreman.Client`'s current
  surface (`new/0` and `run/2`; a test reads `packages/foreman_client/lib/foreman/client.ex` and
  fails when the script calls anything that module does not define). It carries the same
  `Mix.install` line and run-time inputs as the scripts `foreman init --template` scaffolds:
  `FOREMAN_API_TOKEN`, `FOREMAN_PROJECT_ID`, `FOREMAN_API_URL` and `FOREMAN_AGENT_ENV`.

  Every value taken from the spec is written with `inspect/2`, so it is an Elixir string literal
  whatever it contains (quotes, `\#{}`, backslashes, newlines). The user's prompt is never written
  into the script: it lives only in `prompts/<name>.md`, which the script reads with `File.read!/1`,
  so there is no escaping problem to get wrong. All the script carries of the prompt is the name
  derived from its first words, which the whitelist restricts to letters, digits, `.`, `_` and `-`.
  `project_id` is not written either; the script reads it from `FOREMAN_PROJECT_ID`, so one template
  works for any registered project.
  """

  alias ForemanServer.Jobsite.Template.GeneratedFile

  # The order the spec literal is written in; the same as the scripts `foreman init --template`
  # scaffolds. A spec key missing from this list would be silently dropped from the script, so
  # `files/3` refuses to render one.
  @key_order ~w(project_id name strategy sandbox agent prompt max_iterations completion_signal push)
  @agent_order ~w(provider model approval_mode)

  @preamble ~S"""
  # Pin `ref: "<tag or sha>"` here to stop following the default branch.
  Mix.install([{:foreman_client, github: "ldangelo/foreman", sparse: "packages/foreman_client"}])

  project_id = System.get_env("FOREMAN_PROJECT_ID") || raise "FOREMAN_PROJECT_ID is not set"
  client = Foreman.Client.new()

  agent_env =
    "FOREMAN_AGENT_ENV"
    |> System.get_env("")
    |> String.split(",", trim: true)
    |> Map.new(fn name ->
      name = String.trim(name)
      {name, System.get_env(name) || raise("#{name} is listed in FOREMAN_AGENT_ENV but is not set")}
    end)

  """

  @run ~S"""

  spec = if agent_env == %{}, do: spec, else: put_in(spec, ["agent", "env"], agent_env)

  case Foreman.Client.run(client, spec) do
    {:ok, jobsite} ->
      IO.puts("jobsite_id=#{jobsite["jobsite_id"]} status=#{jobsite["status"]} branch=#{jobsite["branch"]}")
      IO.puts("iterations=#{length(jobsite["iterations"] || [])} commits=#{length(jobsite["commits"] || [])}")

    {:error, reason} ->
      IO.puts(:stderr, "jobsite did not complete: #{inspect(reason)}")
      System.halt(1)
  end
  """

  @doc """
  The script and its prompt file, in that order. `spec` must be a spec `Spec.from_json/2` accepted;
  `features` and `notes` are what the prompt reader found, written into the script header.
  """
  @spec files(%{required(String.t()) => term()}, [String.t()], [String.t()]) :: [
          GeneratedFile.t()
        ]
  def files(spec, features, notes) when is_map(spec) and is_list(features) and is_list(notes) do
    case Map.keys(spec) -- @key_order do
      [] ->
        :ok

      unrendered ->
        raise ArgumentError, "spec keys the script cannot render: #{inspect(unrendered)}"
    end

    name = Map.fetch!(spec, "name")

    [
      %GeneratedFile{
        path: name <> ".exs",
        content:
          header(spec, name, features, notes) <> @preamble <> spec_literal(spec, name) <> @run
      },
      %GeneratedFile{path: prompt_path(name), content: Map.fetch!(spec, "prompt")}
    ]
  end

  defp prompt_path(name), do: "prompts/" <> name <> ".md"

  # -- the spec literal -------------------------------------------------------------------------

  defp spec_literal(spec, name) do
    fields =
      for key <- @key_order, Map.has_key?(spec, key) do
        "  " <> literal(key) <> " => " <> field_source(key, Map.fetch!(spec, key), name)
      end

    "spec = %{\n" <> Enum.join(fields, ",\n") <> "\n}\n"
  end

  defp field_source("project_id", _value, _name), do: "project_id"

  defp field_source("prompt", _value, name),
    do: "File.read!(Path.join(__DIR__, #{literal(prompt_path(name))}))"

  defp field_source("agent", agent, _name), do: map_literal(agent, @agent_order)
  defp field_source(_key, value, _name), do: literal(value)

  # Total over the types a validated spec holds. Anything else is a bug in the generator and
  # fails here rather than being written out as something plausible.
  defp literal(text) when is_binary(text), do: inspect(text, printable_limit: :infinity)
  defp literal(number) when is_integer(number), do: Integer.to_string(number)
  defp literal(flag) when is_boolean(flag), do: Atom.to_string(flag)
  defp literal(list) when is_list(list), do: "[" <> Enum.map_join(list, ", ", &literal/1) <> "]"
  defp literal(%{} = map), do: map_literal(map, [])

  defp map_literal(map, order) do
    keys = Enum.filter(order, &Map.has_key?(map, &1)) ++ Enum.sort(Map.keys(map) -- order)

    "%{" <>
      Enum.map_join(keys, ", ", &(literal(&1) <> " => " <> literal(Map.fetch!(map, &1)))) <> "}"
  end

  # -- the header -------------------------------------------------------------------------------

  defp header(spec, name, features, notes) do
    lines =
      [
        ".foreman/#{name}.exs - a Foreman Jobsite generated from a prompt by `foreman jobsite template`.",
        "The prompt the agent receives is .foreman/prompts/#{name}.md, read when the script runs.",
        "",
        "Run with plain Elixir (OTP 27+); no Foreman checkout, no database:",
        "",
        "  export FOREMAN_API_TOKEN=...            # the server's bearer token",
        "  export FOREMAN_PROJECT_ID=my-project    # a project registered on the server",
        "  elixir .foreman/#{name}.exs",
        "",
        "FOREMAN_API_URL defaults to http://127.0.0.1:4766. The server must enable remote start",
        "(`config :foreman_server, :jobsites, allow_remote_start: true`); the agent runs on the",
        "SERVER, in its checkout of the project, and this script only sends the spec and waits.",
        "",
        "Optional:",
        "  FOREMAN_AGENT_ENV=A,B   names of variables in THIS shell to pass to the agent as agent.env",
        "                          (e.g. ANTHROPIC_API_KEY). The server must allowlist them",
        "                          (FOREMAN_JOBSITES_AGENT_ENV_ALLOWLIST). A docker sandbox sees none of",
        "                          your own credentials, so without this the agent cannot log in."
      ] ++
        sandbox_lines(spec) ++
        iteration_lines(spec, name) ++ push_lines(spec) ++ inferred_lines(features, notes)

    Enum.map_join(lines, "\n", &comment/1) <> "\n\n"
  end

  defp comment(""), do: "#"
  defp comment(line), do: "# " <> line

  defp sandbox_lines(%{"sandbox" => "host"}) do
    [
      "",
      "Sandbox host: the agent runs directly on the server's machine with approval_mode auto_approve.",
      "The server refuses it unless `config :foreman_server, :jobsites, allow_host_sandbox: true`."
    ]
  end

  defp sandbox_lines(_spec) do
    [
      "",
      "Sandbox docker: the image `foreman-jobsite:<repository directory name>` must exist on the",
      "SERVER's Docker. See .foreman/README.md and .foreman/Dockerfile (`foreman init --template`)."
    ]
  end

  defp iteration_lines(%{"max_iterations" => max, "completion_signal" => _signal}, name) do
    [
      "",
      "Loops for at most #{max} iteration(s) and stops as soon as the agent prints the completion",
      "signal; the end of prompts/#{name}.md tells it when to do so."
    ]
  end

  defp iteration_lines(_spec, _name), do: []

  defp push_lines(%{"push" => true}) do
    [
      "",
      "push: the branch is published to `origin` of the server's checkout after the commit. A failed",
      "push fails the jobsite and keeps the commits local."
    ]
  end

  defp push_lines(_spec), do: []

  defp inferred_lines([], []) do
    ["", "Nothing was inferred from the prompt: one agent turn on a named branch."]
  end

  defp inferred_lines(features, notes) do
    [
      "",
      "Read from the prompt (inferred, not stated by you; check these before trusting the run):"
    ] ++
      Enum.map(features, &"  * feature #{&1}") ++ Enum.map(notes, &"  * note: #{&1}")
  end
end
