defmodule ForemanServer.Projects.Recommendations do
  @moduledoc """
  Setup recommendations for a project: what is missing or misconfigured and how
  to fix it (Foreman's analogue of Claude Projects' setup suggestions).

  `evaluate/1` is PURE over `Recommendations.Facts`: no I/O, deterministic,
  stable ids, ordered `action` > `warn` > `info`, then by id. A fact that could
  not be observed (`:unavailable`, `:timeout` where not itself the finding)
  produces no recommendation, never a false alarm. `recommend_bounded/1` is the
  one entry point with I/O (`Facts.collect/2` then `evaluate/1`, under a time
  budget): GET, the MCP tool, `foreman doctor`, the CLI, the coordinator's
  setup proposal and its `apply_recommendation` action all go through it.

  A `fix` is either `%{kind: :command, type, payload}` - a Foreman command
  computed from observed data that an operator may dispatch - or
  `%{kind: :manual, text}` for advice Foreman cannot safely apply itself.

  ## Detector ids

  `task_provider.wire_beads`, `task_provider.br_missing`,
  `repo.agents_md_missing`, `branch.default_unresolved`, `ci.none_detected`,
  `gh.unauthenticated`, `gh.check_timeout`, `git.no_remote`,
  `workflows.not_installed`, `workflows.unmapped_types`,
  `provider.coordinator_unavailable`, `provider.none_installed`,
  `settings.instructions_empty`, `settings.goal_empty`, `settings.env_empty`,
  `settings.env_plain_secrets`, `memory.empty`, `project.paused`,
  `stack.test_hint`.
  """

  alias ForemanServer.Projects.Recommendations.Facts

  defmodule Recommendation do
    @moduledoc "One setup recommendation."
    @enforce_keys [:id, :severity, :title, :detail]
    defstruct [:id, :severity, :title, :detail, evidence: %{}, fix: nil]

    @type fix ::
            nil
            | %{kind: :command, type: String.t(), payload: map()}
            | %{kind: :manual, text: String.t()}

    @type t :: %__MODULE__{
            id: String.t(),
            severity: :action | :warn | :info,
            title: String.t(),
            detail: String.t(),
            evidence: map(),
            fix: fix()
          }
  end

  @severity_rank %{action: 0, warn: 1, info: 2}

  @test_commands [
    {"mix.exs", "mix test"},
    {"package.json", "npm test"},
    {"go.mod", "go test ./..."},
    {"pyproject.toml", "pytest"},
    {"Cargo.toml", "cargo test"},
    {"Gemfile", "bundle exec rspec"}
  ]

  @doc "Collect facts for `project_id` and evaluate them."
  @spec recommend(String.t(), keyword()) ::
          {:ok, [Recommendation.t()]} | {:error, :project_not_found}
  def recommend(project_id, opts \\ []) when is_binary(project_id) do
    with {:ok, facts} <- Facts.collect(project_id, opts), do: {:ok, evaluate(facts)}
  end

  @doc """
  `recommend/2` under the configured budget: the entry point every surface uses,
  so HTTP, MCP, `foreman doctor`, the coordinator's setup proposal and
  `apply_recommendation` see the same recommendations.

  `config :foreman_server, :recommendations, probe:, probe_timeout_ms:,
  total_timeout_ms:` overrides the probe and the budgets (test seam). Per-probe
  bounds hold the collection to about `total_timeout_ms`; the outer bound is the
  guarantee, with one probe's worth of slack so a late last probe still counts.
  """
  @spec recommend_bounded(String.t()) ::
          {:ok, [Recommendation.t()]} | {:error, :project_not_found | :timeout}
  def recommend_bounded(project_id) when is_binary(project_id) do
    config = Application.get_env(:foreman_server, :recommendations, [])
    total = Keyword.get(config, :total_timeout_ms, Facts.total_timeout_ms())

    opts =
      config
      |> Keyword.take([:probe, :probe_timeout_ms])
      |> Keyword.put(:deadline_ms, System.monotonic_time(:millisecond) + total)

    outer = total + Keyword.get(opts, :probe_timeout_ms, Facts.probe_timeout_ms())

    case Facts.Probe.System.call(fn -> recommend(project_id, opts) end, outer) do
      {:ok, result} -> result
      {:error, :timeout} -> {:error, :timeout}
      {:error, :failed} -> raise "project recommendations failed for #{project_id}"
    end
  end

  @doc "Pure evaluation of `facts`; see the moduledoc."
  @spec evaluate(Facts.t()) :: [Recommendation.t()]
  def evaluate(%Facts{} = facts) do
    [
      wire_beads(facts),
      br_missing(facts),
      agents_md_missing(facts),
      branch_unresolved(facts),
      ci_none(facts),
      gh(facts),
      no_remote(facts),
      workflows_not_installed(facts),
      unmapped_types(facts),
      coordinator_provider(facts),
      instructions_empty(facts),
      goal_empty(facts),
      env_empty(facts),
      env_secrets(facts),
      memory_empty(facts),
      paused(facts),
      test_hint(facts)
    ]
    |> List.flatten()
    |> Enum.sort_by(&{Map.fetch!(@severity_rank, &1.severity), &1.id})
  end

  @doc "Fixes of kind `:command` are the only ones a coordinator may apply."
  @spec applicable?(Recommendation.t()) :: boolean()
  def applicable?(%Recommendation{fix: %{kind: :command}}), do: true
  def applicable?(%Recommendation{}), do: false

  # -- detectors ----------------------------------------------------------------

  defp wire_beads(%Facts{has_beads_dir: true, beads_db_path: db, task_provider: current} = facts)
       when is_binary(db) and current != "beads" do
    [
      rec(
        "task_provider.wire_beads",
        :action,
        "Wire the beads task provider",
        "This repository has a beads database (#{db}) but the project's task provider is " <>
          "#{facts.task_provider || "not set"}, so beads tasks are not imported.",
        %{database_path: db},
        %{
          kind: :command,
          type: "project.update",
          payload: %{
            project_id: facts.project_id,
            task_provider: %{provider: "beads", config: %{database_path: db}}
          }
        }
      )
    ]
  end

  defp wire_beads(_), do: []

  defp br_missing(%Facts{task_provider: "beads", br_binary: false}) do
    [
      rec(
        "task_provider.br_missing",
        :warn,
        "`br` is not installed",
        "The project uses the beads task provider but the `br` binary is not on the server's PATH.",
        %{},
        manual("Install beads_rust (`br`) on the machine running the Foreman server.")
      )
    ]
  end

  defp br_missing(_), do: []

  defp agents_md_missing(%Facts{repo_path: repo, files: %{agents_md: false, claude_md: false}})
       when is_binary(repo) do
    [
      rec(
        "repo.agents_md_missing",
        :warn,
        "No AGENTS.md or CLAUDE.md",
        "Agents read repository guidance from AGENTS.md or CLAUDE.md in their working directory. " <>
          "Foreman does not inject one for you.",
        %{},
        manual(
          "Add an AGENTS.md covering: how to build and test, code conventions, and what not to touch."
        )
      )
    ]
  end

  defp agents_md_missing(_), do: []

  # A run starts from the branch checked out in the repo and its pull request
  # targets it; on a detached HEAD there is none to name
  # (`auto_pr_base_branch_unresolved`).
  defp branch_unresolved(%Facts{checked_out_branch: :detached, repo_path: repo})
       when is_binary(repo) do
    [
      rec(
        "branch.default_unresolved",
        :warn,
        "Base branch cannot be determined",
        "#{repo} is on a detached HEAD, so Foreman cannot tell which branch runs start from " <>
          "or which branch their pull requests should target.",
        %{repo_path: repo},
        manual(
          "Check out the branch pull requests should target (for example `git switch main`) in that repository."
        )
      )
    ]
  end

  defp branch_unresolved(_), do: []

  defp ci_none(%Facts{repo_path: repo, files: %{ci: []}}) when is_binary(repo) do
    [
      rec(
        "ci.none_detected",
        :info,
        "No CI configuration found",
        "No .github/workflows, .gitlab-ci.yml or .circleci config was found. PR watching relies on checks reported by CI.",
        %{},
        nil
      )
    ]
  end

  defp ci_none(_), do: []

  defp gh(%Facts{gh: status}) when status in [:unauthenticated, :missing] do
    [
      rec(
        "gh.unauthenticated",
        :warn,
        "GitHub CLI is not authenticated",
        "`gh` is #{if status == :missing, do: "not installed", else: "not logged in"}; opening and watching pull requests needs it.",
        %{gh: Atom.to_string(status)},
        manual("Install the GitHub CLI and run `gh auth login` on the Foreman server.")
      )
    ]
  end

  defp gh(%Facts{gh: :timeout}) do
    [
      rec(
        "gh.check_timeout",
        :warn,
        "GitHub CLI check timed out",
        "`gh auth status` did not answer within #{div(Facts.probe_timeout_ms(), 1000)}s, so GitHub authentication is unknown.",
        %{timeout_ms: Facts.probe_timeout_ms()},
        manual("Run `gh auth status` on the Foreman server and check network access to GitHub.")
      )
    ]
  end

  defp gh(_), do: []

  defp no_remote(%Facts{git_remote: false}) do
    [
      rec(
        "git.no_remote",
        :warn,
        "No git remote configured",
        "The repository has no remote, so branches cannot be pushed or pull requests opened.",
        %{},
        manual("Add a remote: `git remote add origin <url>`.")
      )
    ]
  end

  defp no_remote(_), do: []

  defp workflows_not_installed(%Facts{workflows_installed: false}) do
    [
      rec(
        "workflows.not_installed",
        :warn,
        "No workflows installed",
        "The workflow catalog has no manifests, so runs cannot start.",
        %{},
        manual(
          "Install the default workflows: `foreman workflow install` (or `foreman init --force`)."
        )
      )
    ]
  end

  defp workflows_not_installed(_), do: []

  defp unmapped_types(%Facts{unmapped_issue_types: [_ | _] = types}) do
    [
      rec(
        "workflows.unmapped_types",
        :warn,
        "Some bead types have no workflow",
        "Beads of these types will not dispatch: #{Enum.join(types, ", ")}.",
        %{unmapped_types: types},
        manual("Map the types to workflows in a workflow manifest, or retype the beads.")
      )
    ]
  end

  defp unmapped_types(_), do: []

  defp coordinator_provider(%Facts{provider_rows: rows, settings: settings})
       when is_list(rows) do
    configured =
      case settings do
        %{coordinator_provider: p} when is_binary(p) and p != "" -> p
        _ -> nil
      end

    installed = for {name, :installed} <- rows, do: Atom.to_string(name)

    cond do
      configured != nil and configured not in installed ->
        [
          rec(
            "provider.coordinator_unavailable",
            :warn,
            "Configured provider is not installed",
            "The project's coordinator provider `#{configured}` is not installed on the Foreman server.",
            %{provider: configured, installed: installed},
            manual("Install the `#{configured}` CLI, or change the coordinator provider setting.")
          )
        ]

      is_nil(configured) and rows != [] and installed == [] ->
        [
          rec(
            "provider.none_installed",
            :warn,
            "No agent provider is installed",
            "None of the supported agent provider CLIs is installed on the Foreman server.",
            %{},
            manual("Run `foreman doctor` and install at least one provider CLI.")
          )
        ]

      true ->
        []
    end
  end

  defp coordinator_provider(_), do: []

  defp instructions_empty(%Facts{settings: %{instructions: i}}) when i in [nil, ""] do
    [
      rec(
        "settings.instructions_empty",
        :info,
        "No project instructions",
        "Project instructions are added to every thread's context.",
        %{},
        manual("Set them with `foreman project update <id> --instructions-file <file>`.")
      )
    ]
  end

  defp instructions_empty(_), do: []

  defp goal_empty(%Facts{settings: %{goal: g}}) when g in [nil, ""] do
    [
      rec(
        "settings.goal_empty",
        :info,
        "No project goal",
        "A one-line goal helps agents and operators see what the project is for.",
        %{},
        manual("Set it with `foreman project update <id> --goal \"...\"`.")
      )
    ]
  end

  defp goal_empty(_), do: []

  defp env_empty(%Facts{env_names: []}) do
    [
      rec(
        "settings.env_empty",
        :info,
        "No project environment or secrets",
        "No variables or secrets are configured for this project, so its agents receive no project-specific environment.",
        %{},
        manual(
          "Add what builds and tests need: `foreman project env set <id> NAME=value`, " <>
            "and credentials with `foreman project secret set --from-env VAR <id> NAME`."
        )
      )
    ]
  end

  defp env_empty(_), do: []

  defp env_secrets(%Facts{env_secret_keys: [_ | _] = keys}) do
    [
      rec(
        "settings.env_plain_secrets",
        :warn,
        "Secret-looking values in plain project environment",
        "Plain values for #{Enum.join(keys, ", ")} are stored in the project's legacy environment " <>
          "config, in clear text in project events; `project env set` rejects secret-looking names.",
        %{keys: keys},
        manual(
          "Store each one in the project secret store (`foreman project secret set --from-env VAR <id> NAME`), " <>
            "then re-save the remaining variables with `foreman project env set --replace <id> NAME=value ...` " <>
            "so the legacy plain config is ignored."
        )
      )
    ]
  end

  defp env_secrets(_), do: []

  defp memory_empty(%Facts{memory_count: 0}) do
    [
      rec(
        "memory.empty",
        :info,
        "Project memory is empty",
        "Project memory keeps durable facts (conventions, decisions) available to every thread.",
        %{},
        manual("Record conventions with the project memory tools once you have settled them.")
      )
    ]
  end

  defp memory_empty(_), do: []

  defp paused(%Facts{project_status: "paused"} = facts) do
    [
      rec(
        "project.paused",
        :action,
        "Project is paused",
        "A paused project refuses new runs, threads and imports.",
        %{},
        %{kind: :command, type: "project.resume", payload: %{project_id: facts.project_id}}
      )
    ]
  end

  defp paused(_), do: []

  defp test_hint(%Facts{settings: %{instructions: i}, files: %{manifests: [first | _]}})
       when i in [nil, ""] do
    command = Enum.find_value(@test_commands, fn {file, cmd} -> file == first && cmd end)

    if command do
      [
        rec(
          "stack.test_hint",
          :info,
          "Draft instructions from the detected stack",
          "Found #{first}; a minimal instruction is to tell agents how to run the tests.",
          %{manifest: first},
          manual("Run tests with `#{command}`.")
        )
      ]
    else
      []
    end
  end

  defp test_hint(_), do: []

  defp rec(id, severity, title, detail, evidence, fix),
    do: %Recommendation{
      id: id,
      severity: severity,
      title: title,
      detail: detail,
      evidence: evidence,
      fix: fix
    }

  defp manual(text), do: %{kind: :manual, text: text}
end
