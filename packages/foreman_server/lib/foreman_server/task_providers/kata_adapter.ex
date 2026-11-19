defmodule ForemanServer.TaskProviders.KataAdapter do
  @moduledoc """
  `ForemanServer.TaskProvider` backed by the `kata` CLI (kenn.io/kata).

  Every call runs `kata` through the module bound to `:kata_runner`
  (`SystemKataRunner` in production, `KataRunnerMock` under test) in the project's
  `project_config[:cwd]`, with `--json` wherever a payload is read. The adapter opens
  no Kata database, speaks no daemon protocol and starts no other binary (AC-001-3).
  Kata validates by field mapping, not JSON Schema, and is authoritative for claim
  state.

  | callback | kata command |
  | --- | --- |
  | `available?/0` | `kata --version` |
  | `list_ready/2` | `kata ready --unowned --json` |
  | `get/2` | `kata show <ref> --json` |
  | `create/2` | `kata create --idempotency-key <key> --json <flags> -- <title>` |
  | `claim/3` | `kata claim <ref> --if-unowned --json` |
  | `complete/3` | `kata close <ref> --done --message <msg> [--commit <sha>] [--evidence <e>] --json` |
  | `fail/3` | `kata status`, `kata reopen`, `kata comment`, `kata unassign` (see `fail/3`) |
  | `reopen/3` | `kata reopen <ref> --comment <note> --json` |
  | `set_priority/3` | `kata edit <ref> --priority <0..4> --json` |
  | `add_dependency/3` | `kata edit <dependent> --blocked-by <dependency> --json` |
  | `annotate/3` | `kata comment <ref> --body <body> --json` |

  An issue reference is a Kata short id and must match `id_format` (`^[a-z0-9]+$`); a
  reference that does not is refused before any command runs, so it can never be read
  as a flag.

  ## Payloads

  A payload is validated field by field. `short_id`, `title` and `status` are
  required; `priority`, `owner`, `body` and `labels` are optional and mean "none" when
  absent. A required field that is absent, or any field of the wrong type, is a typed
  `SCHEMA_VALIDATION_FAILED` error naming the field (`context.missing_fields`), never
  a placeholder or a partly-filled `Issue`. `short_id` becomes `Issue.id`, `body`
  `description` and `owner` `assignee`; the other Kata fields (`uid`, `author`,
  `revision`, `qualified_id`, `web_url`, the timestamps, ...) are kept, with their
  string keys, under `metadata`. `notes` and `design` stay empty: Kata has no such
  fields.

  ## Tokens

  `complete/3` reads the completion token `%{run_id:, artifact_path:}` that
  `RunExecutor` builds, plus the optional `:transition_comment` (the close message),
  `:commit_sha` and `:evidence` (a list of typed evidence strings such as
  `"pr:<url>"`). `fail/3` reads the failure token `RunExecutor.build_failure_token/2`
  builds: `:run_id`, `:reason` (the rendered reason text) and `:transition_comment`.
  `claim/3` ignores its claim token: Kata resolves the acting identity itself.

  ## Errors

  Every error is a `ProviderError` built by `KataAdapter.BuildProviderError`, in the
  `BeadsAdapter.CodeMap` vocabulary. A wrongly typed argument is a programming error
  and raises.
  """

  @behaviour ForemanServer.TaskProvider

  alias ForemanServer.TaskProvider.{Comment, Issue}
  alias ForemanServer.TaskProvider.Registry, as: TaskProviderRegistry
  alias ForemanServer.TaskProviders.BeadsAdapter.CodeMap.ProviderErrorInput
  alias ForemanServer.TaskProviders.ConcurrencyLimiter
  alias ForemanServer.TaskProviders.KataAdapter.BuildProviderError
  alias ForemanServer.TaskProviders.ProviderError

  @runner Application.compile_env(
            :foreman_server,
            :kata_runner,
            ForemanServer.TaskProviders.SystemKataRunner
          )

  # Declared to the registry. `valid_ref?/1` enforces the same rule with `\A...\z`, so a
  # trailing newline cannot pass.
  @id_format "^[a-z0-9]+$"

  @required_issue_fields ["short_id", "title", "status"]
  @optional_issue_fields ["priority", "owner", "body", "labels"]
  @mapped_issue_keys @required_issue_fields ++ @optional_issue_fields

  # Kata refuses `close --done` with a shorter message (checked on kata v0.23.0).
  @close_message_minimum 40
  @close_message_padding " - closed by the Foreman task runner"

  @priority_range 0..4

  @impl true
  def name, do: "kata"

  @doc """
  Creates a Kata issue in the project bound to `project_id` and returns it.

  `attrs` is the canonical map (`TaskProvider.create/2`): `title`, `task_id` and
  `command_id` are required; `description`, `priority` (0..4), `labels`, `task_type`
  and `dedupe_key` are optional. The correlation handles and `task_type` are stored as
  `foreman.*` Kata metadata; `dedupe_key` (else `command_id`) is the idempotency key,
  so a retried create returns the original issue.
  """
  @impl true
  def create(project_id, attrs)
      when is_binary(project_id) and project_id != "" and is_map(attrs) do
    with :ok <- validate_create_attrs(attrs),
         {:ok, cwd} <- resolve_project_cwd(project_id),
         {:ok, envelope} <- call_json(create_argv(attrs), cwd),
         {:ok, record} <- fetch_record(envelope, "issue") do
      parse_issue(record)
    end
  end

  @impl true
  def capabilities do
    %{
      provider_id: :kata,
      contract_version: "kata.capabilities.v1",
      id_format: @id_format,
      storage_scheme: :cli_process,
      supports: [
        :create,
        :claim,
        :close,
        :reopen,
        :annotate,
        :set_priority,
        :set_assignee,
        :list_dependencies,
        :add_dependency,
        :remove_dependency
      ]
    }
  end

  @doc """
  `true` only when `kata` is on `PATH` and `kata --version` exits zero.

  There is no version gate: a kata outside `accepted_kata_versions` is a
  `foreman doctor` warning, not an unavailable provider.
  """
  @impl true
  def available? do
    case System.find_executable("kata") do
      nil -> false
      _path -> version_probe_succeeds?()
    end
  end

  @doc "Lists the open, unblocked, unowned issues of the project as `Issue` structs."
  @impl true
  def list_ready(project_config, _opts) when is_map(project_config) do
    with {:ok, envelope} <-
           call_json(["ready", "--unowned", "--json"], fetch_cwd!(project_config)),
         {:ok, records} <- fetch_list(envelope, "issues") do
      parse_issues(records)
    end
  end

  @doc """
  Fetches one issue. `labels` come from `show`'s `labels` and `dependencies` from the
  `blocks` links that point at the issue (the short ids of the issues blocking it).
  """
  @impl true
  def get(task_id, project_config) when is_map(project_config) do
    with :ok <- validate_ref(task_id),
         {:ok, envelope} <- call_json(["show", task_id, "--json"], fetch_cwd!(project_config)),
         {:ok, record} <- fetch_record(envelope, "issue"),
         {:ok, issue} <- parse_issue(record),
         {:ok, labels} <- show_labels(envelope),
         {:ok, dependencies} <- show_dependencies(envelope, record) do
      {:ok,
       %Issue{
         issue
         | labels: labels,
           dependencies: dependencies,
           metadata: put_web_url(issue.metadata, envelope)
       }}
    end
  end

  @doc """
  Claims the issue with one atomic `kata claim --if-unowned` and returns it, owned.

  An issue another actor owns is `CLAIMED_BY_OTHER`, not retryable.
  """
  @impl true
  def claim(task_id, _claim_token, project_config) when is_map(project_config) do
    with :ok <- validate_ref(task_id),
         {:ok, envelope} <-
           call_json(["claim", task_id, "--if-unowned", "--json"], fetch_cwd!(project_config)),
         {:ok, record} <- fetch_record(envelope, "issue") do
      parse_issue(record, ["owner"])
    end
  end

  @doc """
  Closes the issue as done.

  Returns `{:ok, :terminal}` when this call closed it and `{:ok, :already_terminal}`
  when Kata reports `changed: false` (it was already closed). Without a
  `:transition_comment` the close message is the deterministic
  `foreman-run:<run_id>:<artifact_path>`, padded to Kata's 40-character minimum.
  """
  @impl true
  def complete(task_id, completion_token, project_config)
      when is_map(completion_token) and is_map(project_config) do
    with :ok <- validate_ref(task_id),
         {:ok, message} <- close_message(completion_token),
         {:ok, changed?} <-
           call_changed(
             close_argv(task_id, message, completion_token),
             fetch_cwd!(project_config)
           ) do
      if changed?, do: {:ok, :terminal}, else: {:ok, :already_terminal}
    end
  end

  @doc """
  Records a failed run on the issue and releases Foreman's claim; returns
  `{:ok, :reopened}`. Kata has no failure close reason, so the issue is never closed.

  Four calls, each with `--json`, in this order:

    1. `kata status <ref>`: the effective `actor` and the current `owner` (absent when
       the issue is unowned). One call on the one issue being failed, not a sweep. An
       owner that is not the actor means someone else holds the issue: nothing is
       written and the result is a non-retryable `CLAIMED_BY_OTHER`.
    2. `kata reopen <ref>`: `changed: false` (already open) is success.
    3. `kata comment <ref> --body <reason> --idempotency-key foreman-fail:<run_id>:<hash>`
       where `<hash>` is the first 16 hex characters of the SHA-256 of the body, so a
       retried failure replays the comment (`changed: false`) instead of repeating it.
       An unowned issue still gets steps 2 and 3, so the failure is always recorded.
    4. `kata unassign <ref> --expect-owner <actor>`, unless the issue was already
       unowned. The actor is `status`'s, never `kata whoami`'s and never the owner.
       Exit 5 means ownership changed since step 1: `CLAIMED_BY_OTHER`.
  """
  @impl true
  def fail(task_id, failure_token, project_config)
      when is_map(failure_token) and is_map(project_config) do
    cwd = fetch_cwd!(project_config)

    with :ok <- validate_ref(task_id),
         {:ok, body} <- failure_comment(failure_token),
         run_id = fetch_run_id!(failure_token),
         {:ok, status} <- call_json(["status", task_id, "--json"], cwd),
         {:ok, {actor, owner}} <- read_ownership(status),
         :ok <- ensure_not_owned_by_other(actor, owner),
         {:ok, _reopened?} <- call_changed(["reopen", task_id, "--json"], cwd),
         {:ok, _commented?} <-
           call_changed(
             [
               "comment",
               task_id,
               "--body",
               body,
               "--idempotency-key",
               failure_idempotency_key(run_id, body),
               "--json"
             ],
             cwd
           ),
         :ok <- release_claim(task_id, actor, owner, cwd) do
      {:ok, :reopened}
    end
  end

  @doc "Reopens the issue with `transition_comment` as the reason; an open issue is a no-op."
  @impl true
  def reopen(task_id, transition_comment, project_config) when is_map(project_config) do
    with :ok <- validate_ref(task_id),
         :ok <- validate_comment(transition_comment),
         {:ok, _changed?} <-
           call_changed(
             ["reopen", task_id, "--comment", transition_comment, "--json"],
             fetch_cwd!(project_config)
           ) do
      :ok
    end
  end

  @impl true
  def set_priority(task_id, priority, project_config) when is_map(project_config) do
    with :ok <- validate_ref(task_id),
         :ok <- validate_priority(priority),
         {:ok, _changed?} <-
           call_changed(
             ["edit", task_id, "--priority", Integer.to_string(priority), "--json"],
             fetch_cwd!(project_config)
           ) do
      :ok
    end
  end

  @doc """
  Makes `dependent_id` blocked by `dependency_id`. An edge that already exists is
  success, as in Beads.
  """
  @impl true
  def add_dependency(dependent_id, dependency_id, project_config) when is_map(project_config) do
    with :ok <- validate_ref(dependent_id),
         :ok <- validate_ref(dependency_id),
         :ok <- validate_not_self_dependency(dependent_id, dependency_id),
         {:ok, _changed?} <-
           call_changed(
             ["edit", dependent_id, "--blocked-by", dependency_id, "--json"],
             fetch_cwd!(project_config)
           ) do
      :ok
    end
  end

  @doc "Appends `body` as a comment; Kata must report that it added one."
  @impl true
  def annotate(task_id, body, project_config) when is_map(project_config) do
    with :ok <- validate_ref(task_id),
         :ok <- validate_comment(body),
         {:ok, added?} <-
           call_changed(
             ["comment", task_id, "--body", body, "--json"],
             fetch_cwd!(project_config)
           ),
         :ok <- require_comment_added(added?) do
      {:ok, %Comment{provider_issue_id: task_id, status: "comment_added", provider_metadata: %{}}}
    end
  end

  ## Concurrency

  # Every `@runner.cmd/3` call goes through here and holds one `ConcurrencyLimiter` slot, keyed by
  # the directory the command runs in (the project's workspace), for exactly as long as the
  # runner runs; a raise from the runner still returns it. A caller that gets no slot within the
  # limiter's configured timeout never starts a process and receives the retryable
  # `BR_TIMEOUT_QUEUE` instead. The limiter is the one the application supervises.
  defp run_kata(argv, cwd) do
    case ConcurrencyLimiter.acquire(cwd) do
      :ok ->
        try do
          @runner.cmd(argv, cwd, [])
        after
          ConcurrencyLimiter.release(cwd)
        end

      {:error, :timeout} ->
        {:error, queue_timeout_error()}
    end
  end

  ## Runner calls

  # Runs one kata command and decodes the JSON object it printed.
  defp call_json(argv, cwd) do
    case run_kata(argv, cwd) do
      {:ok, stdout} ->
        decode_envelope(stdout)

      {:error, %ProviderError{} = runner_error} ->
        {:error, BuildProviderError.from_runner_error(argv, runner_error)}
    end
  end

  defp decode_envelope(stdout) when is_binary(stdout) do
    case Jason.decode(stdout) do
      {:ok, %{} = envelope} -> {:ok, envelope}
      {:ok, _not_an_object} -> {:error, parse_error()}
      {:error, %Jason.DecodeError{}} -> {:error, parse_error()}
    end
  end

  # Mutation envelopes are `{kata_api_version, issue, event, changed}`; `changed` says
  # whether this call altered anything.
  defp call_changed(argv, cwd) do
    with {:ok, envelope} <- call_json(argv, cwd) do
      fetch_changed(envelope)
    end
  end

  defp fetch_changed(%{"changed" => changed}) when is_boolean(changed), do: {:ok, changed}
  defp fetch_changed(_envelope), do: {:error, schema_error(["changed"])}

  # A comment sent without an idempotency key is always new, so `changed: false` would mean
  # kata did not add it.
  defp require_comment_added(true), do: :ok

  defp require_comment_added(false) do
    {:error, contract_error("Kata reported that the comment was not added.")}
  end

  defp version_probe_succeeds? do
    case run_kata(["--version"], File.cwd!()) do
      {:ok, _banner} -> true
      {:error, %ProviderError{}} -> false
    end
  end

  ## Project configuration

  defp fetch_cwd!(%{cwd: cwd}) when is_binary(cwd) and cwd != "", do: cwd

  defp fetch_cwd!(other) do
    raise ArgumentError, "expected project_config with a binary :cwd, got: #{inspect(other)}"
  end

  defp resolve_project_cwd(project_id) do
    case TaskProviderRegistry.project_config(project_id) do
      {:ok, %{config: %{cwd: cwd}}} when is_binary(cwd) and cwd != "" ->
        {:ok, cwd}

      {:ok, %{config: _config}} ->
        {:error,
         local_error(
           "VALIDATION_FAILED",
           "Kata project has no working directory configured.",
           "Bind the project to a kata workspace so its config carries :cwd."
         )}

      {:error, reason} when is_atom(reason) ->
        {:error,
         local_error(
           "VALIDATION_FAILED",
           "Kata project configuration could not be resolved.",
           "Register the project with the kata provider before creating issues."
         )}
    end
  end

  ## Argument validation

  defp validate_ref(ref) when is_binary(ref) do
    if valid_ref?(ref) do
      :ok
    else
      {:error,
       local_error(
         "INVALID_TASK_ID",
         "Kata issue reference must match #{@id_format}.",
         "Pass the short_id of a Kata issue, for example abc4."
       )}
    end
  end

  defp validate_ref(nil) do
    {:error,
     local_error(
       "INVALID_TASK_ID",
       "Kata issue reference is missing.",
       "Pass the short_id of a Kata issue, for example abc4."
     )}
  end

  defp validate_ref(other) do
    raise ArgumentError, "expected a binary Kata issue reference, got: #{inspect(other)}"
  end

  defp valid_ref?(ref), do: Regex.match?(~r/\A[a-z0-9]+\z/, ref)

  defp validate_comment(comment) when is_binary(comment) do
    if String.trim(comment) == "", do: {:error, invalid_comment_error()}, else: :ok
  end

  defp validate_comment(nil), do: {:error, invalid_comment_error()}

  defp validate_comment(other) do
    raise ArgumentError, "expected a binary comment, got: #{inspect(other)}"
  end

  defp invalid_comment_error do
    local_error(
      "INVALID_TRANSITION_COMMENT",
      "Kata comment must be a non-empty string.",
      "Pass the comment text before retrying."
    )
  end

  defp validate_priority(priority) when is_integer(priority) and priority in @priority_range,
    do: :ok

  defp validate_priority(_priority), do: {:error, invalid_priority_error()}

  defp invalid_priority_error do
    local_error(
      "INVALID_PRIORITY",
      "Kata issue priority must be an integer between 0 and 4.",
      "Pass a priority in the inclusive range 0..4."
    )
  end

  defp validate_not_self_dependency(same_id, same_id) do
    {:error,
     local_error(
       "DEPENDENCY_CYCLE",
       "Dependency edge would create a cycle.",
       "Choose a dependency that is not the issue itself."
     )}
  end

  defp validate_not_self_dependency(_dependent_id, _dependency_id), do: :ok

  defp validate_create_attrs(attrs) do
    cond do
      not non_empty_string?(Map.get(attrs, :title)) ->
        {:error, invalid_title_error("Kata issue title must be a non-empty string.")}

      not non_empty_string?(Map.get(attrs, :task_id)) ->
        {:error, invalid_title_error("Kata create requires a non-empty :task_id handle.")}

      not non_empty_string?(Map.get(attrs, :command_id)) ->
        {:error, invalid_title_error("Kata create requires a non-empty :command_id handle.")}

      not valid_create_priority?(Map.get(attrs, :priority)) ->
        {:error, invalid_priority_error()}

      not valid_labels?(Map.get(attrs, :labels)) ->
        {:error,
         local_error(
           "VALIDATION_FAILED",
           "Kata labels must be a list of non-empty strings without commas.",
           "Pass :labels as a list of comma-free label strings."
         )}

      not valid_task_type?(Map.get(attrs, :task_type)) ->
        {:error,
         local_error(
           "INVALID_ISSUE_TYPE",
           "Kata task_type must be a non-empty string when present.",
           "Pass :task_type as a string or omit it."
         )}

      true ->
        :ok
    end
  end

  defp invalid_title_error(message) do
    local_error("INVALID_TITLE", message, "Pass the missing value before retrying.")
  end

  defp valid_create_priority?(nil), do: true
  defp valid_create_priority?(priority), do: is_integer(priority) and priority in @priority_range

  defp valid_labels?(nil), do: true

  defp valid_labels?(labels) when is_list(labels) do
    Enum.all?(labels, &(non_empty_string?(&1) and not String.contains?(&1, ",")))
  end

  defp valid_labels?(_labels), do: false

  defp valid_task_type?(nil), do: true
  defp valid_task_type?(task_type), do: non_empty_string?(task_type)

  defp non_empty_string?(value), do: is_binary(value) and value != ""

  ## argv builders

  # The title is the one free-text positional, so it follows `--`: a title that begins with
  # a dash must not be read as a flag.
  defp create_argv(attrs) do
    ["create", "--idempotency-key", idempotency_key(attrs), "--json"] ++
      body_args(Map.get(attrs, :description)) ++
      priority_args(Map.get(attrs, :priority)) ++
      Enum.flat_map(Map.get(attrs, :labels) || [], &["--label", &1]) ++
      meta_args(attrs) ++
      ["--", attrs.title]
  end

  defp body_args(description) when is_binary(description) and description != "",
    do: ["--body", description]

  defp body_args(_description), do: []

  defp priority_args(priority) when is_integer(priority),
    do: ["--priority", Integer.to_string(priority)]

  defp priority_args(nil), do: []

  defp meta_args(attrs) do
    task_type_meta =
      case Map.get(attrs, :task_type) do
        nil -> []
        task_type -> ["--meta", "foreman.task_type=" <> task_type]
      end

    [
      "--meta",
      "foreman.task_id=" <> attrs.task_id,
      "--meta",
      "foreman.command_id=" <> attrs.command_id
    ] ++
      task_type_meta
  end

  defp idempotency_key(attrs) do
    case Map.get(attrs, :dedupe_key) do
      key when is_binary(key) and key != "" -> key
      _absent -> attrs.command_id
    end
  end

  defp close_argv(task_id, message, completion_token) do
    ["close", task_id, "--done", "--message", message] ++
      commit_args(Map.get(completion_token, :commit_sha)) ++
      evidence_args(Map.get(completion_token, :evidence)) ++
      ["--json"]
  end

  defp commit_args(nil), do: []
  defp commit_args(sha) when is_binary(sha) and sha != "", do: ["--commit", sha]

  defp commit_args(other) do
    raise ArgumentError, "expected :commit_sha to be a non-empty binary, got: #{inspect(other)}"
  end

  defp evidence_args(nil), do: []

  defp evidence_args(evidence) when is_list(evidence) do
    Enum.flat_map(evidence, fn
      item when is_binary(item) and item != "" ->
        ["--evidence", item]

      other ->
        raise ArgumentError,
              "expected :evidence entries to be non-empty binaries, got: #{inspect(other)}"
    end)
  end

  defp evidence_args(other) do
    raise ArgumentError, "expected :evidence to be a list, got: #{inspect(other)}"
  end

  ## Completion and failure tokens

  defp close_message(completion_token) do
    case Map.get(completion_token, :transition_comment) do
      message when is_binary(message) and message != "" -> {:ok, message}
      _absent -> default_close_message(completion_token)
    end
  end

  defp default_close_message(%{run_id: run_id} = completion_token)
       when is_binary(run_id) and run_id != "" do
    message = "foreman-run:#{run_id}:#{Map.get(completion_token, :artifact_path)}"

    if String.length(message) >= @close_message_minimum,
      do: {:ok, message},
      else: {:ok, message <> @close_message_padding}
  end

  defp default_close_message(_completion_token) do
    {:error,
     local_error(
       "INVALID_TRANSITION_COMMENT",
       "Kata close needs a message or a run id to derive one from.",
       "Pass :transition_comment, or :run_id in the completion token."
     )}
  end

  defp failure_comment(failure_token) do
    case {Map.get(failure_token, :reason), Map.get(failure_token, :transition_comment)} do
      {reason, _comment} when is_binary(reason) and reason != "" ->
        {:ok, reason}

      {_reason, comment} when is_binary(comment) and comment != "" ->
        {:ok, comment}

      _neither ->
        {:error,
         local_error(
           "INVALID_TRANSITION_COMMENT",
           "Kata failure comment must be a non-empty string.",
           "Pass :reason or :transition_comment in the failure token."
         )}
    end
  end

  defp fetch_run_id!(%{run_id: run_id}) when is_binary(run_id) and run_id != "", do: run_id

  defp fetch_run_id!(other) do
    raise ArgumentError, "expected failure_token with a binary :run_id, got: #{inspect(other)}"
  end

  defp failure_idempotency_key(run_id, body) do
    hash =
      :sha256
      |> :crypto.hash(body)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "foreman-fail:#{run_id}:#{hash}"
  end

  ## fail/3 steps

  defp read_ownership(%{"actor" => actor} = status) when is_binary(actor) and actor != "" do
    case Map.get(status, "owner") do
      nil -> {:ok, {actor, nil}}
      owner when is_binary(owner) and owner != "" -> {:ok, {actor, owner}}
      _malformed -> {:error, schema_error(["owner"])}
    end
  end

  defp read_ownership(_status), do: {:error, schema_error(["actor"])}

  defp ensure_not_owned_by_other(_actor, nil), do: :ok
  defp ensure_not_owned_by_other(actor, actor), do: :ok

  defp ensure_not_owned_by_other(_actor, _other_owner) do
    {:error,
     local_error(
       "CLAIMED_BY_OTHER",
       "Kata issue is owned by another actor; nothing was written to it.",
       "Release the issue with kata unassign, or leave it to its owner."
     )}
  end

  # An issue that was already unowned has no claim to release.
  defp release_claim(_task_id, _actor, nil, _cwd), do: :ok

  defp release_claim(task_id, actor, _owner, cwd) do
    with {:ok, envelope} <-
           call_json(["unassign", task_id, "--expect-owner", actor, "--json"], cwd) do
      case envelope do
        %{"changed" => true, "event" => %{"type" => "issue.unassigned"}} ->
          :ok

        _other ->
          {:error, contract_error("Kata did not report the claim as released.")}
      end
    end
  end

  ## Payload mapping

  defp fetch_record(envelope, key) do
    case Map.get(envelope, key) do
      %{} = record -> {:ok, record}
      _absent_or_malformed -> {:error, schema_error([key])}
    end
  end

  defp fetch_list(envelope, key) do
    case Map.get(envelope, key) do
      records when is_list(records) -> {:ok, records}
      _absent_or_malformed -> {:error, schema_error([key])}
    end
  end

  defp parse_issues(records) do
    records
    |> Enum.reduce_while({:ok, []}, fn
      record, {:ok, issues} when is_map(record) ->
        case parse_issue(record) do
          {:ok, issue} -> {:cont, {:ok, [issue | issues]}}
          {:error, %ProviderError{}} = error -> {:halt, error}
        end

      _not_a_record, {:ok, _issues} ->
        {:halt, {:error, schema_error(["issues"])}}
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      {:error, %ProviderError{}} = error -> error
    end
  end

  defp parse_issue(record, extra_required \\ []) do
    case invalid_issue_fields(record, extra_required) do
      [] -> {:ok, to_issue(record)}
      fields -> {:error, schema_error(fields)}
    end
  end

  defp invalid_issue_fields(record, extra_required) do
    missing =
      Enum.reject(
        @required_issue_fields ++ extra_required,
        &non_empty_string?(Map.get(record, &1))
      )

    malformed =
      Enum.reject(@optional_issue_fields, &valid_optional_field?(&1, Map.get(record, &1)))

    Enum.uniq(missing ++ malformed)
  end

  defp valid_optional_field?(_field, nil), do: true
  defp valid_optional_field?("priority", priority), do: is_integer(priority) and priority >= 0

  defp valid_optional_field?("labels", labels),
    do: is_list(labels) and Enum.all?(labels, &is_binary/1)

  defp valid_optional_field?(_text_field, value), do: is_binary(value)

  defp to_issue(record) do
    %Issue{
      id: record["short_id"],
      title: record["title"],
      status: record["status"],
      priority: record["priority"],
      dependencies: [],
      dependents: [],
      assignee: record["owner"],
      description: record["body"],
      notes: nil,
      design: nil,
      labels: record["labels"] || [],
      metadata: Map.drop(record, @mapped_issue_keys)
    }
  end

  # `show` lists the labels at the top level as `%{"label" => name, ...}` objects.
  defp show_labels(envelope) do
    case Map.get(envelope, "labels") do
      nil ->
        {:ok, []}

      entries when is_list(entries) ->
        names = for %{"label" => name} when is_binary(name) <- entries, do: name

        if length(names) == length(entries),
          do: {:ok, names},
          else: {:error, schema_error(["labels"])}

      _malformed ->
        {:error, schema_error(["labels"])}
    end
  end

  # An issue's dependencies are the issues that block it: the `from` side of every
  # `blocks` link whose `to` side is this issue.
  defp show_dependencies(envelope, record) do
    case Map.get(envelope, "links") do
      nil ->
        {:ok, []}

      links when is_list(links) ->
        links
        |> Enum.reduce_while({:ok, []}, fn link, {:ok, blockers} ->
          case blocker(link, record) do
            {:blocker, short_id} -> {:cont, {:ok, [short_id | blockers]}}
            :unrelated -> {:cont, {:ok, blockers}}
            :malformed -> {:halt, {:error, schema_error(["links"])}}
          end
        end)
        |> case do
          {:ok, blockers} -> {:ok, Enum.reverse(blockers)}
          {:error, %ProviderError{}} = error -> error
        end

      _malformed ->
        {:error, schema_error(["links"])}
    end
  end

  defp blocker(%{"type" => "blocks", "from" => %{} = from, "to" => %{} = to}, record) do
    case from do
      %{"short_id" => short_id} when is_binary(short_id) ->
        if same_issue?(to, record), do: {:blocker, short_id}, else: :unrelated

      _no_short_id ->
        :malformed
    end
  end

  defp blocker(%{"type" => "blocks"}, _record), do: :malformed
  defp blocker(%{"type" => type}, _record) when is_binary(type), do: :unrelated
  defp blocker(_link, _record), do: :malformed

  # Link endpoints carry the issue's `uid` and `short_id`; the uid is exact, so it decides
  # whenever both sides have one.
  defp same_issue?(%{"uid" => uid}, %{"uid" => uid}) when is_binary(uid), do: true

  defp same_issue?(%{"uid" => uid}, %{"uid" => other}) when is_binary(uid) and is_binary(other),
    do: false

  defp same_issue?(endpoint, record), do: endpoint["short_id"] == record["short_id"]

  defp put_web_url(metadata, envelope) do
    case Map.get(envelope, "web_url") do
      nil -> metadata
      web_url -> Map.put(metadata, "web_url", web_url)
    end
  end

  ## Errors (every one is built by `BuildProviderError`)

  defp queue_timeout_error do
    local_error(
      "BR_TIMEOUT_QUEUE",
      "Kata command timed out while waiting for a concurrency slot.",
      "Retry after the adapter queue drains."
    )
  end

  defp local_error(code, message, hint, missing_fields \\ []) do
    code
    |> ProviderErrorInput.from_local(message, hint, false, missing_fields)
    |> BuildProviderError.build_provider_error(nil, 0)
  end

  defp parse_error do
    local_error(
      "BR_PARSE_ERROR",
      "Kata output could not be parsed as a JSON object.",
      "Check that the installed kata version matches the adapter contract."
    )
  end

  defp schema_error(fields) do
    local_error(
      "SCHEMA_VALIDATION_FAILED",
      "Kata payload is missing required fields or carries invalid ones.",
      "Check that the installed kata version matches the adapter contract.",
      fields
    )
  end

  defp contract_error(message) do
    local_error(
      "BR_CONTRACT_MISMATCH",
      message,
      "Check that the installed kata version matches the adapter contract."
    )
  end
end
