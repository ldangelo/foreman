defmodule ForemanServer.ProjectContext do
  @moduledoc """
  The ONE producer of standing project context (instructions, repositories,
  and provider-supplied sections such as memory and library). Both the
  workflow door and the jobsite door call `build/2`; there is no second
  implementation.

  Pure with respect to caching: every call re-reads the projection and the
  providers, so memory written by an earlier phase is visible to a later one.

  Rendering order is fixed: Instructions, Repositories, Memory, Library, then
  any other provider section. Each body is capped (`:section_caps`); if the
  rendered whole still exceeds `:max_bytes`, sections shrink lowest priority
  first (Library, Memory, Repositories, other, Instructions last). Every cut
  is announced inside the text by a `[truncated: ...]` marker and recorded in
  `Bundle.truncated`. A project with nothing to inject yields
  `system_text: nil`.
  """

  alias ForemanServer.Identity
  alias ForemanServer.Overwatch.WorkerLogPolicy
  alias ForemanServer.ProjectContext.Bundle
  alias ForemanServer.ProjectContext.Section
  alias ForemanServer.ProjectionStore
  alias ForemanServer.ProjectSettings
  alias ForemanServer.WorkerEnvironment

  require Logger

  @order [:instructions, :repositories, :memory, :library]
  @default_max_bytes 24_000
  @default_caps %{instructions: 16_000, repositories: 1_000, memory: 6_000, library: 3_000}
  @other_cap 3_000

  @spec build(String.t(), keyword()) :: {:ok, Bundle.t()} | {:error, :project_not_found}
  def build(project_id, opts \\ []) when is_binary(project_id) do
    case ProjectionStore.project(project_id) do
      nil ->
        {:error, :project_not_found}

      project ->
        providers =
          Keyword.get_lazy(opts, :section_providers, fn -> config(:section_providers, []) end)

        sections = base_sections(project) ++ provider_sections(providers, project_id)
        {:ok, assemble(sections, project_id, opts)}
    end
  end

  @doc """
  Decides how standing context reaches an agent of `provider`. Returns
  `{system_prompt, prompt}`: providers that declare the `system_prompt`
  normalized option get the text as their system prompt; the others get it
  prefixed to the prompt, so context is never silently dropped and an
  unsupported option never fails the launch. Both doors use this.
  """
  @spec deliver(String.t() | nil, atom() | String.t(), String.t()) ::
          {String.t() | nil, String.t()}
  def deliver(nil, _provider, prompt), do: {nil, prompt}

  def deliver(text, provider, prompt) when is_binary(text) do
    if supports_system_prompt?(provider) do
      {text, prompt}
    else
      Logger.info("project context prefixed to prompt: provider #{provider} has no system_prompt")
      {nil, text <> "\n\n---\n\n" <> prompt}
    end
  end

  defp supports_system_prompt?(provider) when is_atom(provider) do
    case Jido.Harness.Registry.spec(provider) do
      {:ok, spec} -> :system_prompt in spec.normalized_options
      {:error, _} -> false
    end
  end

  defp supports_system_prompt?(_provider), do: false

  @doc "Assembles a bundle from already-gathered sections (pure; used by tests)."
  @spec assemble([Section.t()], String.t() | nil, keyword()) :: Bundle.t()
  def assemble(sections, project_id, opts \\ []) do
    max_bytes =
      Keyword.get_lazy(opts, :max_bytes, fn -> config(:max_bytes, @default_max_bytes) end)

    caps =
      Map.merge(
        @default_caps,
        Keyword.get_lazy(opts, :section_caps, fn -> config(:section_caps, %{}) end) |> Map.new()
      )

    secrets = secrets_for(project_id, opts)

    {scrubbed, redactions} =
      sections
      |> Enum.reject(&(String.trim(&1.body) == ""))
      |> drop_lone_repositories()
      |> Enum.map_reduce(0, fn section, acc ->
        {body, n} = redact(section.body, secrets)
        {%{section | body: body}, acc + n}
      end)

    if redactions > 0 do
      Logger.warning(
        "project context for #{inspect(project_id)}: redacted #{redactions} secret span(s) " <>
          "in sections " <> Enum.map_join(changed_ids(sections, scrubbed), ",", &to_string/1)
      )
    end

    ordered = Enum.sort_by(scrubbed, &order_index(&1.id))
    entries = Enum.map(ordered, &cap_section(&1, Map.get(caps, &1.id, @other_cap)))
    entries = fit_budget(entries, max_bytes)

    finalize(entries, redactions)
  end

  # The repository list is orientation for other context, never context on its
  # own: a project with no instructions/memory/library sees no behaviour change.
  defp drop_lone_repositories([%Section{id: :repositories}]), do: []
  defp drop_lone_repositories(sections), do: sections

  defp changed_ids(before_sections, after_sections) do
    before_sections
    |> Enum.reject(&(String.trim(&1.body) == ""))
    |> drop_lone_repositories()
    |> Enum.zip(after_sections)
    |> Enum.filter(fn {a, b} -> a.body != b.body end)
    |> Enum.map(fn {a, _} -> a.id end)
  end

  # --- sections -------------------------------------------------------------

  defp base_sections(project) do
    settings = ProjectSettings.from_config(Map.get(project, :config))

    instructions =
      case settings.instructions do
        text when is_binary(text) ->
          [
            Section.new(:instructions, "Project instructions", text,
              hint: "ask the operator for the full instructions (foreman project settings <id>)"
            )
          ]

        _ ->
          []
      end

    instructions ++ repositories(project)
  end

  defp repositories(project) do
    case Map.get(project, :path) do
      path when is_binary(path) and path != "" ->
        [Section.new(:repositories, "Repositories", "- primary: #{path}")]

      _ ->
        []
    end
  end

  defp provider_sections(providers, project_id) do
    Enum.flat_map(providers, fn module ->
      case module.section(project_id) do
        {:ok, %Section{} = section} -> [section]
        :skip -> []
      end
    end)
  end

  # --- budget ---------------------------------------------------------------

  defp cap_section(%Section{} = section, cap) do
    {body, omitted_bytes, omitted_lines} = truncate_lines(section.body, cap)

    %{
      section: section,
      body: body,
      omitted_bytes: omitted_bytes,
      omitted_lines: omitted_lines,
      cap: cap
    }
  end

  defp fit_budget(entries, max_bytes) do
    entries
    |> shrink_ids()
    |> Enum.reduce_while(entries, fn id, acc ->
      if rendered_size(acc) <= max_bytes,
        do: {:halt, acc},
        else: {:cont, shrink_entry(acc, id, max_bytes)}
    end)
  end

  # lowest priority first: library, memory, repositories, other, instructions last
  defp shrink_ids(entries) do
    present = Enum.map(entries, & &1.section.id)
    others = Enum.reject(present, &(&1 in @order))

    Enum.filter([:library, :memory, :repositories] ++ others ++ [:instructions], &(&1 in present))
  end

  defp shrink_entry(entries, id, max_bytes) do
    entry = Enum.find(entries, &(&1.section.id == id))
    excess = rendered_size(entries) - max_bytes
    target = max(byte_size(entry.body) - excess - marker_slack(entry), 0)
    {body, omitted_bytes, omitted_lines} = truncate_lines(entry.section.body, target)

    updated = %{entry | body: body, omitted_bytes: omitted_bytes, omitted_lines: omitted_lines}
    next = Enum.map(entries, fn e -> if e.section.id == id, do: updated, else: e end)

    if rendered_size(next) > max_bytes and body != "" and target < byte_size(entry.body),
      do: shrink_entry_again(next, id, max_bytes, target),
      else: next
  end

  # The marker line itself costs bytes; shrink further until the whole fits.
  defp shrink_entry_again(entries, id, max_bytes, previous_target) do
    entry = Enum.find(entries, &(&1.section.id == id))
    target = max(previous_target - (rendered_size(entries) - max_bytes), 0)
    {body, omitted_bytes, omitted_lines} = truncate_lines(entry.section.body, target)
    updated = %{entry | body: body, omitted_bytes: omitted_bytes, omitted_lines: omitted_lines}
    next = Enum.map(entries, fn e -> if e.section.id == id, do: updated, else: e end)

    if rendered_size(next) > max_bytes and body != "" and target < previous_target,
      do: shrink_entry_again(next, id, max_bytes, target),
      else: next
  end

  defp marker_slack(%{omitted_bytes: 0} = entry),
    do: byte_size(marker_text(entry.section, 999_999)) + 1

  defp marker_slack(_entry), do: 0

  defp rendered_size(entries), do: entries |> render_entries() |> byte_size()

  @doc false
  # Cuts `text` to at most `cap` bytes at a line boundary (never inside a UTF-8
  # codepoint). A single line longer than `cap` is hard-cut at a codepoint
  # boundary. Returns `{kept, omitted_bytes, omitted_lines}`.
  @spec truncate_lines(String.t(), non_neg_integer()) ::
          {String.t(), non_neg_integer(), non_neg_integer()}
  def truncate_lines(text, cap) when byte_size(text) <= cap, do: {text, 0, 0}

  def truncate_lines(text, cap) do
    window = trim_partial_codepoint(binary_part(text, 0, cap))

    kept =
      cond do
        binary_part(text, byte_size(window), 1) == "\n" ->
          window

        match?([_ | _], :binary.matches(window, "\n")) ->
          binary_part(window, 0, last_newline(window))

        true ->
          window
      end

    omitted = binary_part(text, byte_size(kept), byte_size(text) - byte_size(kept))
    omitted_lines = omitted |> String.split("\n") |> Enum.reject(&(&1 == "")) |> length()
    {kept, byte_size(omitted), max(omitted_lines, 1)}
  end

  defp last_newline(window), do: window |> :binary.matches("\n") |> List.last() |> elem(0)

  defp trim_partial_codepoint(bin) do
    if String.valid?(bin),
      do: bin,
      else: trim_partial_codepoint(binary_part(bin, 0, byte_size(bin) - 1))
  end

  # --- rendering ------------------------------------------------------------

  defp finalize(entries, redactions) do
    text = render_entries(entries)

    sections =
      Enum.map(entries, fn e -> %{e.section | body: marked(e)} end)

    truncated =
      for e <- entries, e.omitted_bytes > 0 do
        %{section: e.section.id, omitted_bytes: e.omitted_bytes, omitted_lines: e.omitted_lines}
      end

    case text do
      "" ->
        %Bundle{
          system_text: nil,
          sections: [],
          truncated: [],
          bytes: 0,
          sha256: nil,
          redactions: redactions
        }

      _ ->
        %Bundle{
          system_text: text,
          sections: sections,
          truncated: truncated,
          bytes: byte_size(text),
          sha256: Identity.sha256(text),
          redactions: redactions
        }
    end
  end

  defp render_entries(entries) do
    Enum.map_join(entries, "\n\n", fn e -> "## #{e.section.title}\n#{marked(e)}" end)
  end

  defp marked(%{omitted_bytes: 0, body: body}), do: body

  defp marked(%{section: section, body: body, omitted_lines: lines}) do
    marker = marker_text(section, lines)
    if body == "", do: marker, else: body <> "\n" <> marker
  end

  defp marker_text(section, lines),
    do: "[truncated: #{lines} lines omitted from #{section.title}; #{section.hint}]"

  defp order_index(id) do
    Enum.find_index(@order, &(&1 == id)) || length(@order)
  end

  # --- secrets --------------------------------------------------------------

  defp secrets_for(nil, _opts), do: []

  defp secrets_for(project_id, opts) do
    case Keyword.fetch(opts, :secrets) do
      {:ok, secrets} ->
        secrets

      :error ->
        project_id |> WorkerEnvironment.build_env_map() |> WorkerEnvironment.extract_secrets()
    end
  end

  defp redact(body, secrets) do
    redacted = WorkerLogPolicy.redact(body, secrets)
    {redacted, count_redactions(body, redacted)}
  end

  defp count_redactions(before_text, after_text) do
    if before_text == after_text, do: 0, else: marks(after_text) - marks(before_text)
  end

  defp marks(text), do: length(String.split(text, "[REDACTED]")) - 1

  defp config(key, default) do
    :foreman_server |> Application.get_env(:project_context, []) |> Keyword.get(key, default)
  end
end
