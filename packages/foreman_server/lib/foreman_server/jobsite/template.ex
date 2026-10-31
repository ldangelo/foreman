defmodule ForemanServer.Jobsite.Template do
  @moduledoc """
  Turns a natural-language prompt into a runnable remote-jobsite script.

  `generate/2` takes the same kind of input `ForemanServer.Jobsite.Spec.from_json/2` does: an
  untrusted, string-keyed, JSON-decoded map, here a PARTIAL spec. The generator fills what the
  caller left out (a name, a branch, the sandbox, an iteration budget when the prompt asks for a
  loop, ...), then hands the completed spec to `Spec.from_json/2`. There is no second copy of the
  whitelist anywhere: a spec the server would refuse is refused here, with the server's own error
  code, and no file is produced. What comes back is the spec `from_json/2` accepted, never an
  edited copy of it.

  Accepted keys (every other key is `:template_option_unsupported`): `project_id` (required),
  `prompt` (required), `name`, `agent` (`provider`, `model` only), `max_iterations`,
  `completion_signal`, `strategy` (`{"branch": name}` only), `sandbox` and `push`. Each is judged by
  `Spec.from_json/2`; this module only decides which of them to fill in:

    * `name` defaults to a slug of the prompt's first words, the branch to `agent/<slug of name>`.
    * the sandbox defaults to `docker`; `host` is only ever an explicit option.
    * `agent.approval_mode` is `auto_approve`: a headless run left on the harness default cannot
      write. `agent.provider` and `agent.model` are never defaulted (the model may come from the
      project's `thread_model`).
    * a prompt that asks for a loop (see `ForemanServer.Jobsite.Template.Feature`), or an explicit
      `max_iterations` or `completion_signal`, makes an iterating spec: `max_iterations` 5 and
      `<promise>COMPLETE</promise>` unless given, and the prompt file ends with the instruction
      that tells the agent how to finish.
    * a prompt that asks to publish sets `push: true` unless `push` is given.

  Explicit options always win over what the prompt suggests.

  `from_json/2` is the whitelist, not the whole server. The run-time gates stay with the server and
  are named in the script header instead of being faked here: `allow_remote_start`, the concurrent
  jobsite cap and the project's daily thread cap, the sandbox image existing on the server's
  Docker, the agent's credentials reaching a docker sandbox (`FOREMAN_AGENT_ENV`), and a missing
  `origin` for a push. `strategy: head` is never generated: the agent would edit the server's own
  checkout in place, with no branch to review, merge or push, and no keyword in a prompt should
  choose that.

  No model is called: the derivation is deterministic, so the same input always yields the same
  files.
  """

  alias ForemanServer.Jobsite.{Error, Spec}
  alias ForemanServer.Jobsite.Template.{Feature, Script}

  defmodule GeneratedFile do
    @moduledoc """
    One file of a generated template. `path` is relative to the project's `.foreman/` directory and
    is always `<name>.exs` or `prompts/<name>.md`, where `name` already passed the whitelist's name
    pattern (no path separator, no leading dot).
    """

    @enforce_keys [:path, :content]
    defstruct [:path, :content]

    @type t :: %__MODULE__{path: String.t(), content: String.t()}
  end

  @enforce_keys [:name, :spec, :features, :notes, :files]
  defstruct [:name, :spec, :features, :notes, :files]

  @typedoc """
  `spec` is the exact map `Spec.from_json/2` accepted (`project_id` included, so it can be POSTed
  as is). `features` are the prompt features that were applied, `notes` what a remote spec cannot
  express.
  """
  @type t :: %__MODULE__{
          name: String.t(),
          spec: %{required(String.t()) => term()},
          features: [String.t()],
          notes: [String.t()],
          files: [GeneratedFile.t()]
        }

  @supported_keys ~w(project_id prompt name agent max_iterations completion_signal strategy
                     sandbox push)
  @agent_keys ~w(provider model)

  @approval_mode "auto_approve"
  @default_iterations 5
  @default_signal "<promise>COMPLETE</promise>"

  @fallback_name "work"
  @name_words 4
  @name_max_length 40

  @doc """
  Generates the template for `params`, or the typed reason there is none.

  `opts` are forwarded to `Spec.from_json/2` (`:allow_host_sandbox`, `:agent_env_allowlist`), so the
  verdict is the one the server would give a request made now.
  """
  @spec generate(term(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def generate(params, opts \\ [])

  def generate(params, opts) when is_map(params) and not is_struct(params) do
    with :ok <- check_supported(params),
         features = applied_features(params),
         spec = build_spec(params, features),
         {:ok, _accepted} <- Spec.from_json(spec, opts) do
      {:ok, assemble(spec, features)}
    end
  end

  def generate(_params, _opts) do
    {:error, Error.new(:spec_invalid, "template request must be a JSON object", %{})}
  end

  # -- supported options ------------------------------------------------------------------------

  defp check_supported(params) do
    with :ok <- check_keys(Map.keys(params), @supported_keys, nil),
         :ok <- check_agent(Map.fetch(params, "agent")) do
      check_strategy(Map.fetch(params, "strategy"))
    end
  end

  defp check_keys(keys, supported, scope) do
    case keys |> Enum.reject(&(&1 in supported)) |> Enum.map(&show/1) |> Enum.sort() do
      [] ->
        :ok

      unsupported ->
        what = if scope, do: scope <> " option", else: "option"

        {:error,
         Error.new(
           :template_option_unsupported,
           "unsupported #{what}(s): #{Enum.join(unsupported, ", ")}; the template generator sets only " <>
             Enum.join(supported, ", "),
           %{keys: unsupported, supported: supported}
         )}
    end
  end

  defp show(key) when is_binary(key), do: key
  defp show(key), do: inspect(key)

  # A non-object `agent` is the validator's to reject (`:spec_agent_invalid`).
  defp check_agent({:ok, agent}) when is_map(agent) and not is_struct(agent),
    do: check_keys(Map.keys(agent), @agent_keys, "agent")

  defp check_agent(_absent_or_not_an_object), do: :ok

  defp check_strategy(:error), do: :ok

  defp check_strategy({:ok, %{"branch" => _name} = strategy}) when map_size(strategy) == 1,
    do: :ok

  defp check_strategy({:ok, _other}) do
    {:error,
     Error.new(
       :template_option_unsupported,
       ~s(strategy is not supported in this form: the generator names a branch only, as {"branch": name}),
       %{keys: ["strategy"], supported: [~s({"branch": name})]}
     )}
  end

  # -- features ---------------------------------------------------------------------------------

  # What the prompt asked for, minus what an explicit option overrides. An explicit `push` (true or
  # false) replaces the inference, so the publish feature is not "applied" then.
  defp applied_features(params) do
    params |> read_features() |> Enum.filter(&applied?(&1, params))
  end

  defp read_features(%{"prompt" => prompt}) when is_binary(prompt), do: Feature.read(prompt)
  defp read_features(_params), do: []

  defp applied?(%Feature{effect: :publish}, params), do: not Map.has_key?(params, "push")
  defp applied?(%Feature{}, _params), do: true

  defp feature?(features, effect), do: Enum.any?(features, &(&1.effect == effect))

  # -- the spec ---------------------------------------------------------------------------------

  # Builds the string-keyed spec handed to `Spec.from_json/2`. Values the caller supplied are passed
  # through untouched even when malformed, so the validator names the fault; a key the caller did
  # not supply is never added as nil.
  defp build_spec(params, features) do
    name = name_for(params)
    iterate? = iterate?(params, features)

    %{}
    |> put_if_present(params, "project_id")
    |> Map.put("name", name)
    |> put_prompt(params, iterate?)
    |> Map.put("agent", agent_for(params))
    |> Map.put("strategy", strategy_for(params, name))
    |> Map.put("sandbox", Map.get(params, "sandbox", "docker"))
    |> put_iteration(params, iterate?)
    |> put_push(params, features)
  end

  defp put_if_present(spec, params, key) do
    case Map.fetch(params, key) do
      {:ok, value} -> Map.put(spec, key, value)
      :error -> spec
    end
  end

  defp iterate?(params, features) do
    feature?(features, :iterate) or Map.has_key?(params, "max_iterations") or
      Map.has_key?(params, "completion_signal")
  end

  defp name_for(%{"name" => name}), do: name
  defp name_for(%{"prompt" => prompt}) when is_binary(prompt), do: slug(prompt)
  defp name_for(_params), do: @fallback_name

  # `agent/<slug of the name>`, never the raw name: a legal name such as `x.lock` or `v1.` is not a
  # legal branch component. A malformed explicit name is the validator's to reject.
  defp strategy_for(%{"strategy" => strategy}, _name), do: strategy
  defp strategy_for(_params, name) when is_binary(name), do: %{"branch" => "agent/" <> slug(name)}
  defp strategy_for(_params, _invalid_name), do: %{"branch" => "agent/" <> @fallback_name}

  defp agent_for(%{"agent" => agent}) when is_map(agent) and not is_struct(agent),
    do: Map.put(Map.take(agent, @agent_keys), "approval_mode", @approval_mode)

  defp agent_for(%{"agent" => not_an_object}), do: not_an_object
  defp agent_for(_params), do: %{"approval_mode" => @approval_mode}

  defp put_iteration(spec, _params, false), do: spec

  defp put_iteration(spec, params, true) do
    spec
    |> Map.put("max_iterations", Map.get(params, "max_iterations", @default_iterations))
    |> Map.put("completion_signal", Map.get(params, "completion_signal", @default_signal))
  end

  defp put_push(spec, params, features) do
    case Map.fetch(params, "push") do
      {:ok, false} -> spec
      {:ok, value} -> Map.put(spec, "push", value)
      :error -> if feature?(features, :publish), do: Map.put(spec, "push", true), else: spec
    end
  end

  # -- the prompt -------------------------------------------------------------------------------

  defp put_prompt(spec, %{"prompt" => prompt} = params, iterate?) when is_binary(prompt) do
    signal = Map.get(params, "completion_signal", @default_signal)
    Map.put(spec, "prompt", compose_prompt(prompt, iterate?, signal))
  end

  defp put_prompt(spec, params, _iterate?), do: put_if_present(spec, params, "prompt")

  # The user's words are kept as written; only trailing whitespace becomes one newline. A blank
  # prompt is returned as it is so the validator rejects it: the completion instruction must never
  # turn "nothing" into a prompt.
  defp compose_prompt(prompt, iterate?, signal) do
    if String.trim(prompt) == "" do
      prompt
    else
      body = String.trim_trailing(prompt)
      signal_text = signal_text(signal)

      if iterate? and not String.contains?(body, signal_text),
        do: body <> "\n\n" <> instruction(signal_text) <> "\n",
        else: body <> "\n"
    end
  end

  # A list signal names several; the agent is asked for the first. Anything else is malformed and
  # the validator rejects it, so the text used here is irrelevant.
  defp signal_text(signal) when is_binary(signal), do: signal
  defp signal_text([first | _rest]) when is_binary(first), do: first
  defp signal_text(_malformed), do: @default_signal

  defp instruction(signal_text) do
    "When — and only when — all work is complete and verified, end your final message with " <>
      "exactly:\n\n    #{signal_text}\n\n" <>
      "Do not emit that text early; the jobsite stops iterating the moment it appears."
  end

  # -- names ------------------------------------------------------------------------------------

  defp slug(text) do
    words =
      ~r/[a-z0-9]+/
      |> Regex.scan(String.downcase(text))
      |> List.flatten()
      |> Enum.take(@name_words)

    case words |> Enum.join("-") |> String.slice(0, @name_max_length) |> String.trim("-") do
      "" -> @fallback_name
      slug -> slug
    end
  end

  # -- result -----------------------------------------------------------------------------------

  defp assemble(spec, features) do
    ids = Enum.map(features, & &1.id)
    notes = for %Feature{effect: {:note, text}} <- features, do: text

    %__MODULE__{
      name: Map.fetch!(spec, "name"),
      spec: spec,
      features: ids,
      notes: notes,
      files: Script.files(spec, ids, notes)
    }
  end
end
