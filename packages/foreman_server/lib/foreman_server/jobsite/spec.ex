defmodule ForemanServer.Jobsite.Spec do
  @moduledoc """
  Validates a remote caller's JSON jobsite spec and turns it into the keyword
  list `ForemanServer.Jobsite.run_async/1` takes.

  The input is a string-keyed, JSON-decoded map and is untrusted: every key
  is matched against literal strings (no atom is ever created from caller
  input), the repo is named by a registered `project_id` (never a path), the
  prompt is inline text only, and nothing function-like or process-like can
  enter. The built keyword is finally run through
  `ForemanServer.Jobsite.Options.validate/1`.

  Accepted top-level keys: `project_id` (required), `prompt` (required),
  `agent` (required), `strategy`, `sandbox`, `name`, `max_iterations`,
  `completion_signal`, `idle_timeout_seconds`, `completion_timeout_seconds`,
  `hooks`, `exclude_paths`, `copy_to_worktree`, `resume_session`, `push`.

  `push: true` makes the jobsite publish its branch to `origin` after the commit
  (the remote is fixed, never caller-chosen) and requires a `{"branch": name}`
  strategy.

  Configuration (read at call time; each can be overridden through `opts`):

    * `:allow_host_sandbox` / `config :foreman_server, :jobsites, allow_host_sandbox` (default `false`)
    * `:agent_env_allowlist` / `config :foreman_server, :jobsites, agent_env_allowlist` (default `[]`)

  Error codes (all in `ForemanServer.Jobsite.Error`): `:spec_invalid`,
  `:spec_unknown_key`, `:spec_forbidden_key`, `:spec_non_json_value`,
  `:spec_project_id_missing`, `:spec_project_id_invalid`,
  `:spec_project_not_found`, `:spec_project_unavailable`,
  `:spec_prompt_missing`, `:spec_prompt_invalid`, `:spec_prompt_file_forbidden`,
  `:spec_agent_missing`, `:spec_agent_invalid`, `:spec_provider_invalid`,
  `:spec_approval_mode_invalid`, `:spec_env_not_allowed`,
  `:spec_sandbox_invalid`, `:spec_sandbox_not_allowed`, `:spec_strategy_invalid`,
  `:spec_option_invalid`, `:spec_hooks_invalid`, `:spec_hooks_forbidden`.
  """

  alias ForemanServer.AgentRuntime.JidoHarness
  alias ForemanServer.Jobsite.{Agent, Error, Hooks, Options, Sandboxes}
  alias ForemanServer.ProjectionStore

  @allowed_keys ~w(project_id prompt agent strategy sandbox name max_iterations completion_signal
                   idle_timeout_seconds completion_timeout_seconds hooks exclude_paths
                   copy_to_worktree resume_session push)

  # Keys a remote caller must never supply, each with a reason in its error.
  @forbidden_keys ~w(on_event reply_to logging resume? resume repo_path path base)

  @agent_keys ~w(provider model effort approval_mode env)

  @approval_modes ~w(default prompt auto_edit auto_approve)
  @efforts ~w(minimal low medium high xhigh)

  @hook_targets ~w(sandbox)
  @hook_phases ~w(on_worktree_ready on_sandbox_ready)

  @branch_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._\/-]*\z/

  @spec from_json(term(), keyword()) :: {:ok, keyword()} | {:error, Error.t()}
  def from_json(spec, opts \\ [])

  def from_json(spec, opts) when is_map(spec) and not is_struct(spec) do
    with :ok <- check_keys(spec),
         :ok <- check_json_values(spec),
         {:ok, repo_path} <- resolve_project(spec),
         {:ok, prompt} <- fetch_prompt(spec),
         {:ok, agent} <- build_agent(spec, opts),
         {:ok, sandbox} <- build_sandbox(spec, opts),
         {:ok, optional} <- build_optional(spec),
         built =
           [repo_path: repo_path] ++
             optional.strategy ++
             [sandbox: sandbox, agent: agent, prompt: prompt] ++ optional.rest,
         :ok <- check_push_strategy(built),
         :ok <- Options.validate(built) do
      {:ok, built}
    end
  end

  def from_json(_spec, _opts) do
    {:error, Error.new(:spec_invalid, "spec must be a JSON object", %{})}
  end

  # A push publishes a named branch to `origin`. Any other strategy (`:head`, the
  # default, or `:merge_to_head`) has no branch of its own to publish.
  defp check_push_strategy(built) do
    cond do
      Keyword.get(built, :push, false) != true ->
        :ok

      match?({:branch, _}, Keyword.get(built, :strategy)) ->
        :ok

      true ->
        {:error,
         Error.new(
           :spec_push_requires_branch,
           ~s(push requires a {"branch": name} strategy: only a named branch can be published),
           %{}
         )}
    end
  end

  # -- keys -------------------------------------------------------------

  defp check_keys(spec) do
    Enum.reduce_while(Map.keys(spec), :ok, fn key, :ok ->
      cond do
        is_binary(key) and key in @forbidden_keys ->
          {:halt,
           {:error,
            Error.new(:spec_forbidden_key, "#{key} cannot be supplied in a remote spec", %{
              key: key
            })}}

        key == "prompt_file" ->
          {:halt,
           {:error,
            Error.new(
              :spec_prompt_file_forbidden,
              "prompt_file is not allowed in a remote spec; send the prompt text as prompt",
              %{
                key: key
              }
            )}}

        is_binary(key) and key in @allowed_keys ->
          {:cont, :ok}

        true ->
          shown = if is_binary(key), do: key, else: inspect(key)

          {:halt,
           {:error,
            Error.new(:spec_unknown_key, "unknown spec key #{inspect(shown)}", %{key: shown})}}
      end
    end)
  end

  # Decoded JSON only ever holds maps, lists, binaries, numbers, booleans and
  # nil. Anything else (function, pid, ref, port, tuple, atom) is rejected.
  defp check_json_values(spec) do
    case find_non_json(spec, []) do
      nil ->
        :ok

      path ->
        {:error,
         Error.new(
           :spec_non_json_value,
           "spec contains a non-JSON value at #{Enum.join(path, ".")}",
           %{path: path}
         )}
    end
  end

  defp find_non_json(value, _path)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: nil

  defp find_non_json(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.find_value(fn {v, i} -> find_non_json(v, path ++ [Integer.to_string(i)]) end)
  end

  defp find_non_json(map, path) when is_map(map) and not is_struct(map) do
    Enum.find_value(map, fn {k, v} ->
      if is_binary(k), do: find_non_json(v, path ++ [k]), else: path ++ [inspect(k)]
    end)
  end

  defp find_non_json(_other, path), do: if(path == [], do: ["spec"], else: path)

  # -- project ----------------------------------------------------------

  defp resolve_project(spec) do
    case Map.fetch(spec, "project_id") do
      :error ->
        {:error, Error.new(:spec_project_id_missing, "project_id is required", %{})}

      {:ok, id} when is_binary(id) and id != "" ->
        lookup_project(id)

      {:ok, _other} ->
        {:error,
         Error.new(:spec_project_id_invalid, "project_id must be a non-empty string", %{})}
    end
  end

  defp lookup_project(id) do
    case ProjectionStore.project_projection(id) do
      nil ->
        {:error,
         Error.new(:spec_project_not_found, "no registered project #{inspect(id)}", %{
           project_id: id
         })}

      %{archived?: true} ->
        {:error,
         Error.new(:spec_project_unavailable, "project #{inspect(id)} is archived", %{
           project_id: id
         })}

      %{path: path} when is_binary(path) and path != "" ->
        {:ok, path}

      _no_path ->
        {:error,
         Error.new(:spec_project_unavailable, "project #{inspect(id)} has no repository path", %{
           project_id: id
         })}
    end
  end

  # -- prompt -----------------------------------------------------------

  defp fetch_prompt(spec) do
    case Map.fetch(spec, "prompt") do
      :error ->
        {:error, Error.new(:spec_prompt_missing, "prompt is required", %{})}

      {:ok, prompt} when is_binary(prompt) ->
        if String.trim(prompt) == "" do
          {:error, Error.new(:spec_prompt_invalid, "prompt must not be blank", %{})}
        else
          {:ok, prompt}
        end

      {:ok, _other} ->
        {:error, Error.new(:spec_prompt_invalid, "prompt must be a string", %{})}
    end
  end

  # -- agent ------------------------------------------------------------

  defp build_agent(spec, opts) do
    case Map.fetch(spec, "agent") do
      :error ->
        {:error, Error.new(:spec_agent_missing, "agent is required", %{})}

      {:ok, agent} when is_map(agent) ->
        with :ok <- check_agent_keys(agent),
             {:ok, provider} <- agent_provider(agent),
             {:ok, model} <- agent_model(agent),
             {:ok, effort} <- agent_effort(agent),
             {:ok, approval_mode} <- agent_approval_mode(agent),
             {:ok, env} <- agent_env(agent, opts) do
          {:ok,
           %Agent{
             provider: provider,
             model: model,
             effort: effort,
             env: env,
             provider_options: %{},
             binary: Atom.to_string(provider),
             approval_mode: approval_mode
           }}
        end

      {:ok, _other} ->
        {:error, Error.new(:spec_agent_invalid, "agent must be an object", %{})}
    end
  end

  defp check_agent_keys(agent) do
    case Enum.find(Map.keys(agent), &(&1 not in @agent_keys)) do
      nil ->
        :ok

      key ->
        shown = if is_binary(key), do: key, else: inspect(key)

        {:error,
         Error.new(:spec_agent_invalid, "unknown agent key #{inspect(shown)}", %{key: shown})}
    end
  end

  # Compared as strings against the registry; the atom returned is the
  # registry's own atom, never one minted from input.
  defp agent_provider(agent) do
    case Map.fetch(agent, "provider") do
      {:ok, name} when is_binary(name) ->
        case Enum.find(JidoHarness.providers(), &(Atom.to_string(&1) == name)) do
          nil ->
            supported = Enum.map(JidoHarness.providers(), &Atom.to_string/1)

            {:error,
             Error.new(:spec_provider_invalid, "unsupported provider #{inspect(name)}", %{
               provider: name,
               supported: supported
             })}

          provider ->
            {:ok, provider}
        end

      _missing_or_malformed ->
        {:error,
         Error.new(:spec_provider_invalid, "agent.provider is required and must be a string", %{})}
    end
  end

  defp agent_model(agent) do
    case Map.fetch(agent, "model") do
      {:ok, model} when is_binary(model) and model != "" ->
        {:ok, model}

      _other ->
        {:error,
         Error.new(
           :spec_agent_invalid,
           "agent.model is required and must be a non-empty string",
           %{}
         )}
    end
  end

  defp agent_effort(agent) do
    case Map.fetch(agent, "effort") do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, "minimal"} ->
        {:ok, :minimal}

      {:ok, "low"} ->
        {:ok, :low}

      {:ok, "medium"} ->
        {:ok, :medium}

      {:ok, "high"} ->
        {:ok, :high}

      {:ok, "xhigh"} ->
        {:ok, :xhigh}

      {:ok, other} ->
        {:error,
         Error.new(
           :spec_agent_invalid,
           "agent.effort must be one of #{Enum.join(@efforts, ", ")}",
           %{effort: other}
         )}
    end
  end

  defp agent_approval_mode(agent) do
    case Map.fetch(agent, "approval_mode") do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, "default"} ->
        {:ok, :default}

      {:ok, "prompt"} ->
        {:ok, :prompt}

      {:ok, "auto_edit"} ->
        {:ok, :auto_edit}

      {:ok, "auto_approve"} ->
        {:ok, :auto_approve}

      {:ok, other} ->
        {:error,
         Error.new(
           :spec_approval_mode_invalid,
           "agent.approval_mode must be one of #{Enum.join(@approval_modes, ", ")}",
           %{
             approval_mode: other
           }
         )}
    end
  end

  defp agent_env(agent, opts) do
    case Map.fetch(agent, "env") do
      :error ->
        {:ok, %{}}

      {:ok, env} when is_map(env) ->
        allowlist = config(opts, :agent_env_allowlist, [])

        cond do
          not Enum.all?(env, fn {k, v} -> is_binary(k) and is_binary(v) end) ->
            {:error, Error.new(:spec_agent_invalid, "agent.env must map strings to strings", %{})}

          (denied = env |> Map.keys() |> Enum.reject(&(&1 in allowlist))) != [] ->
            {:error,
             Error.new(
               :spec_env_not_allowed,
               "agent.env keys not allowlisted: #{Enum.join(Enum.sort(denied), ", ")}",
               %{keys: Enum.sort(denied)}
             )}

          true ->
            {:ok, env}
        end

      {:ok, _other} ->
        {:error, Error.new(:spec_agent_invalid, "agent.env must be an object", %{})}
    end
  end

  # -- sandbox ----------------------------------------------------------

  defp build_sandbox(spec, opts) do
    case Map.get(spec, "sandbox", "docker") do
      "docker" ->
        {:ok, Sandboxes.docker()}

      "host" ->
        if config(opts, :allow_host_sandbox, false) == true do
          {:ok, Sandboxes.host()}
        else
          {:error,
           Error.new(
             :spec_sandbox_not_allowed,
             "the host sandbox is not enabled on this server",
             %{sandbox: "host"}
           )}
        end

      other ->
        {:error,
         Error.new(:spec_sandbox_invalid, ~s(sandbox must be "docker" or "host"), %{
           sandbox: other
         })}
    end
  end

  # -- optional keys ----------------------------------------------------

  defp build_optional(spec) do
    with {:ok, strategy} <- build_strategy(spec),
         {:ok, name} <- optional_name(spec),
         {:ok, max_iterations} <- optional_pos_int(spec, "max_iterations", :max_iterations),
         {:ok, signal} <- optional_signal(spec),
         {:ok, idle} <- optional_pos_int(spec, "idle_timeout_seconds", :idle_timeout_seconds),
         {:ok, completion} <-
           optional_pos_int(spec, "completion_timeout_seconds", :completion_timeout_seconds),
         {:ok, hooks} <- optional_hooks(spec),
         {:ok, exclude} <- optional_relative_paths(spec, "exclude_paths", :exclude_paths),
         {:ok, copy} <- optional_relative_paths(spec, "copy_to_worktree", :copy_to_worktree),
         {:ok, resume_session} <- optional_string(spec, "resume_session", :resume_session),
         {:ok, push} <- optional_push(spec) do
      rest =
        name ++
          max_iterations ++
          signal ++ idle ++ completion ++ hooks ++ exclude ++ copy ++ resume_session ++ push

      {:ok, %{strategy: strategy, rest: rest}}
    end
  end

  defp build_strategy(spec) do
    case Map.fetch(spec, "strategy") do
      :error ->
        {:ok, []}

      {:ok, "head"} ->
        {:ok, [strategy: :head]}

      {:ok, %{"type" => "head"} = m} when map_size(m) == 1 ->
        {:ok, [strategy: :head]}

      {:ok, %{"branch" => name} = m} when map_size(m) == 1 ->
        branch_strategy(name)

      {:ok, %{"type" => "branch", "name" => name} = m} when map_size(m) == 2 ->
        branch_strategy(name)

      {:ok, other} ->
        {:error,
         Error.new(
           :spec_strategy_invalid,
           ~s(strategy must be "head", {"branch": name} or {"type": "branch", "name": name}),
           %{strategy: other}
         )}
    end
  end

  defp branch_strategy(name) when is_binary(name) do
    if Regex.match?(@branch_pattern, name) and not String.contains?(name, "..") and
         not String.ends_with?(name, [".lock", "/", "."]) do
      {:ok, [strategy: {:branch, name}]}
    else
      {:error,
       Error.new(:spec_strategy_invalid, "invalid branch name #{inspect(name)}", %{branch: name})}
    end
  end

  defp branch_strategy(other),
    do:
      {:error,
       Error.new(:spec_strategy_invalid, "branch name must be a string", %{branch: other})}

  defp optional_name(spec) do
    case Map.fetch(spec, "name") do
      :error ->
        {:ok, []}

      {:ok, name} when is_binary(name) ->
        if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/, name) do
          {:ok, [name: name]}
        else
          {:error,
           Error.new(
             :spec_option_invalid,
             "name must be 1-128 chars of letters, digits, '.', '_' or '-'",
             %{key: "name"}
           )}
        end

      {:ok, _other} ->
        {:error, Error.new(:spec_option_invalid, "name must be a string", %{key: "name"})}
    end
  end

  defp optional_pos_int(spec, json_key, opt_key) do
    case Map.fetch(spec, json_key) do
      :error ->
        {:ok, []}

      {:ok, n} when is_integer(n) and n > 0 ->
        {:ok, [{opt_key, n}]}

      {:ok, other} ->
        {:error,
         Error.new(:spec_option_invalid, "#{json_key} must be a positive integer", %{
           key: json_key,
           value: other
         })}
    end
  end

  defp optional_signal(spec) do
    case Map.fetch(spec, "completion_signal") do
      :error ->
        {:ok, []}

      {:ok, s} when is_binary(s) and s != "" ->
        {:ok, [completion_signal: s]}

      {:ok, [_ | _] = list} ->
        if Enum.all?(list, &(is_binary(&1) and &1 != "")) do
          {:ok, [completion_signal: list]}
        else
          signal_error()
        end

      {:ok, _other} ->
        signal_error()
    end
  end

  defp signal_error do
    {:error,
     Error.new(
       :spec_option_invalid,
       "completion_signal must be a non-empty string or a non-empty list of them",
       %{key: "completion_signal"}
     )}
  end

  defp optional_string(spec, json_key, opt_key) do
    case Map.fetch(spec, json_key) do
      :error ->
        {:ok, []}

      {:ok, s} when is_binary(s) and s != "" ->
        {:ok, [{opt_key, s}]}

      {:ok, _other} ->
        {:error,
         Error.new(:spec_option_invalid, "#{json_key} must be a non-empty string", %{
           key: json_key
         })}
    end
  end

  defp optional_push(spec) do
    case Map.fetch(spec, "push") do
      :error ->
        {:ok, []}

      {:ok, false} ->
        {:ok, []}

      {:ok, true} ->
        {:ok, [push: true]}

      {:ok, _other} ->
        {:error, Error.new(:spec_option_invalid, "push must be a boolean", %{key: "push"})}
    end
  end

  # Paths are relative to the project checkout; absolute paths and `..`
  # segments would reach outside it.
  defp optional_relative_paths(spec, json_key, opt_key) do
    case Map.fetch(spec, json_key) do
      :error ->
        {:ok, []}

      {:ok, list} when is_list(list) ->
        if Enum.all?(list, &relative_path?/1) do
          {:ok, [{opt_key, list}]}
        else
          {:error,
           Error.new(
             :spec_option_invalid,
             "#{json_key} must be a list of relative paths inside the project",
             %{key: json_key}
           )}
        end

      {:ok, _other} ->
        {:error,
         Error.new(:spec_option_invalid, "#{json_key} must be a list of relative paths", %{
           key: json_key
         })}
    end
  end

  defp relative_path?(path) when is_binary(path) do
    path != "" and Path.type(path) == :relative and ".." not in Path.split(path) and
      not String.contains?(path, <<0>>)
  end

  defp relative_path?(_other), do: false

  # -- hooks ------------------------------------------------------------

  defp optional_hooks(spec) do
    case Map.fetch(spec, "hooks") do
      :error ->
        {:ok, []}

      {:ok, hooks} when is_map(hooks) ->
        with {:ok, built} <- build_hooks(hooks),
             :ok <- Hooks.validate(built) do
          {:ok, [hooks: built]}
        end

      {:ok, _other} ->
        {:error, Error.new(:spec_hooks_invalid, "hooks must be an object", %{})}
    end
  end

  defp build_hooks(hooks) do
    Enum.reduce_while(hooks, {:ok, %{}}, fn {target, phases}, {:ok, acc} ->
      with {:ok, target_key} <- hook_target(target),
           {:ok, built} <- build_phases(target, phases) do
        {:cont, {:ok, Map.put(acc, target_key, built)}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # `hooks.host.*` entries run `sh -c` on the server host (`Hooks.run_host/3`), so
  # accepting them from a remote caller would be remote code execution on the server.
  defp hook_target("host"),
    do:
      {:error,
       Error.new(
         :spec_hooks_forbidden,
         "hooks.host is not accepted: host hooks run on the server host",
         %{key: "host"}
       )}

  defp hook_target("sandbox"), do: {:ok, :sandbox}

  defp hook_target(other),
    do:
      {:error,
       Error.new(
         :spec_hooks_invalid,
         "unknown hooks target #{inspect(other)}; expected one of #{Enum.join(@hook_targets, ", ")}",
         %{key: other}
       )}

  defp build_phases(target, phases) when is_map(phases) do
    Enum.reduce_while(phases, {:ok, %{}}, fn {phase, entries}, {:ok, acc} ->
      with {:ok, phase_key} <- hook_phase(phase),
           {:ok, built} <- build_entries(target, phase, entries) do
        {:cont, {:ok, Map.put(acc, phase_key, built)}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp build_phases(target, _other),
    do:
      {:error,
       Error.new(:spec_hooks_invalid, "hooks.#{target} must be an object", %{key: target})}

  defp hook_phase("on_worktree_ready"), do: {:ok, :on_worktree_ready}
  defp hook_phase("on_sandbox_ready"), do: {:ok, :on_sandbox_ready}

  defp hook_phase(other),
    do:
      {:error,
       Error.new(
         :spec_hooks_invalid,
         "unknown hook phase #{inspect(other)}; expected one of #{Enum.join(@hook_phases, ", ")}",
         %{key: other}
       )}

  defp build_entries(target, phase, entries) when is_list(entries) do
    if Enum.all?(entries, &match?(%{"command" => c} when is_binary(c) and c != "", &1)) and
         Enum.all?(entries, &(map_size(&1) == 1)) do
      {:ok, Enum.map(entries, fn %{"command" => c} -> %{command: c} end)}
    else
      {:error,
       Error.new(
         :spec_hooks_invalid,
         ~s(hooks.#{target}.#{phase} must be a list of {"command": string}),
         %{key: phase}
       )}
    end
  end

  defp build_entries(target, phase, _other),
    do:
      {:error,
       Error.new(:spec_hooks_invalid, "hooks.#{target}.#{phase} must be a list", %{key: phase})}

  # -- config -----------------------------------------------------------

  defp config(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> :foreman_server |> Application.get_env(:jobsites, []) |> Keyword.get(key, default)
    end
  end
end
