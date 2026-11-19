defmodule ForemanServer.TaskProviders.KataArchitectureTest do
  @moduledoc """
  TRD-KATA-T020-TEST: the structural rules that keep the Kata provider inside its boundary.

  Three assertion classes, each an AST scan (never a text grep) with fixture tests that prove the
  scanner fails on a planted violation:

    1. One execution site (AC-004-1, AC-001-3). `SystemKataRunner` is the only module that
       starts `kata`. The runner spawns through a `Port` on `/bin/sh`, so a scan for a
       `System.cmd("kata", ...)` literal alone would miss it: the scan forbids every spawn form
       (`System.cmd`, `System.shell`, `Port.open`, `:os.cmd`, `:erlang.open_port`) that references
       `kata` anywhere in `lib/` outside the runner, and the adapter may start nothing at all.
    2. Alias boundary (AC-004-2). Nothing outside `task_providers/` mentions `KataAdapter`;
       consumers go through the registry.
    3. No claim-state sweep (AC-004-3, AC-014-3). Foreman never enumerates Kata's claim state:
       no `--all`, no owner-filtered listing, no `audit`, `status` only as the single-reference
       lookup inside `fail/3`, and `ready --unowned` only inside `list_ready/2`. The verb
       allow-list is per provider and must be extended in the same PR when a callback needs a
       new verb. The doctor's `kata list --limit 1 --json` sample read lives outside the scanned
       tree, in `cli/doctor_task_provider.ex`.
  """
  use ExUnit.Case, async: true

  @lib_root Path.expand("../../../lib", __DIR__)
  @providers_root Path.join(@lib_root, "foreman_server/task_providers")
  @runner_file Path.join(@providers_root, "system_kata_runner.ex")
  @adapter_file Path.join(@providers_root, "kata_adapter.ex")
  @run_executor_file Path.join(@lib_root, "foreman_server/workflow/run_executor.ex")

  # Verified on kata v0.23.0. `status` is allowed only as the single-reference lookup inside
  # `fail/3`, `ready` only as `ready --unowned --json` inside `list_ready/2`.
  @allowed_verbs ~w(ready show claim close reopen comment unassign create edit status)

  # Every top-level kata command (`kata --help`): a list literal that starts with one of these and
  # has at least one more element is an argv, and must then be on the allow-list.
  @kata_verbs ~w(
    cli inbox labels list next ready search show status whoami assign claim close comment create
    deadline docbank edit label meta move notify reopen schedule unassign agent-contract-hook
    agent-hook audit digest events quickstart wait completion daemon doctor health init mcp tui
  )

  # Never passed by Foreman: `--all` spans projects, `--owner` filters by claim state, `--force`
  # takes a claim another actor holds.
  @forbidden_flags ~w(--all --owner --force)

  @def_kinds [:def, :defp, :defmacro, :defmacrop]
  @network_modules [:Req, :Finch, :Mint, :HTTPoison, :Tesla, :Postgrex, :Exqlite]
  @network_erlang [:gen_tcp, :gen_udp, :httpc, :ssl, :socket, :inet]
  @file_functions [:read, :read!, :open, :open!, :stream!, :write, :write!]

  ## 1. One execution site

  describe "one kata execution site (AC-004-1, AC-001-3)" do
    test "the runner declares exactly one Port.open execution site" do
      sites = for %{call: "Port.open"} = site <- spawn_calls(File.read!(@runner_file)), do: site

      assert length(sites) == 1,
             "system_kata_runner.ex must declare exactly one Port.open site, found: #{inspect(sites)}"
    end

    test "no file in lib/ but the runner spawns kata" do
      offenders =
        for file <- lib_files(),
            file != @runner_file,
            source = File.read!(file),
            source =~ ~r/kata/i,
            site <- kata_spawn_sites(source) do
          {relative(file), site.line, site.call}
        end

      assert offenders == [],
             "kata must be started only by SystemKataRunner:\n" <> format_sites(offenders)
    end

    test "the scanner flags every spawn form that references kata" do
      forbidden = [
        ~S|System.cmd("kata", ["ready"])|,
        ~S|System.cmd("/usr/local/bin/kata", ["ready"])|,
        ~S|System.shell("kata ready --json")|,
        ~S|Port.open({:spawn, "kata ready"}, [:binary])|,
        ~S|Port.open({:spawn_executable, "/opt/homebrew/bin/kata"}, [:binary])|,
        ~S|Port.open({:spawn_executable, "/bin/sh"}, args: ["-c", "exec 'kata' ready"])|,
        ~S|:os.cmd(~c"kata ready")|,
        ~S|:os.cmd(~c'kata ready')|,
        ~S|:erlang.open_port({:spawn, "kata ready"}, [])|,
        ~S|Kernel.apply(System, :cmd, ["kata", ["ready"]])|,
        ~S|apply(Port, :open, [{:spawn, "kata"}, []])|
      ]

      for expression <- forbidden do
        source = "defmodule Fixture do\n  def run, do: #{expression}\nend\n"

        assert [%{line: 2}] = kata_spawn_sites(source), "scanner missed: #{expression}"
      end
    end

    test "the scanner follows a module attribute and a variable in the same function" do
      via_attribute = """
      defmodule Fixture do
        @binary "kata"
        def run(argv), do: System.cmd(@binary, argv)
      end
      """

      via_variable = """
      defmodule Fixture do
        def run(argv) do
          bin = "kata"
          System.cmd(bin, argv)
        end
      end
      """

      assert [%{line: 3, call: "System.cmd"}] = kata_spawn_sites(via_attribute)
      assert [%{line: 4, call: "System.cmd"}] = kata_spawn_sites(via_variable)
    end

    test "the scanner ignores spawns that do not run kata" do
      allowed = """
      defmodule Fixture do
        def git, do: System.cmd("git", ["status"])
        def config, do: System.cmd("git", ["config", "kata.remote"])
        def shell, do: Port.open({:spawn_executable, "/bin/sh"}, args: ["-c", "exec git log"])
        def kill(pid), do: System.cmd("kill", ["-TERM", pid])
        def prose, do: "Kata CLI failures are mapped by the adapter"
      end
      """

      assert kata_spawn_sites(allowed) == []
    end
  end

  describe "the adapter touches nothing but the runner (AC-001-3)" do
    test "the adapter starts no process, opens no file and uses no network client" do
      offenders =
        for file <- adapter_files(),
            site <- adapter_violations(File.read!(file)) do
          {relative(file), site.line, site.what}
        end

      assert offenders == [],
             "the adapter must reach kata only through the runner:\n" <> format_sites(offenders)
    end

    test "the scanner flags a process, a file and a network client in the adapter" do
      source = """
      defmodule Fixture do
        def a, do: System.cmd("true", [])
        def b, do: File.read!("kata.db")
        def c, do: :gen_tcp.connect(~c"localhost", 1, [])
        def d, do: Req.get!("http://localhost")
        def e, do: System.find_executable("git")
        def ok, do: System.find_executable("kata")
      end
      """

      assert Enum.map(adapter_violations(source), & &1.line) == [2, 3, 4, 5, 6]
    end
  end

  ## 2. Alias boundary

  describe "consumers go through the registry (AC-004-2)" do
    test "no module outside task_providers/ references KataAdapter" do
      offenders =
        for file <- lib_files(),
            not String.starts_with?(file, @providers_root <> "/"),
            source = File.read!(file),
            source =~ "KataAdapter",
            line <- kata_adapter_references(source) do
          {relative(file), line, "KataAdapter"}
        end

      assert offenders == [],
             "KataAdapter may be referenced only under task_providers/:\n" <>
               format_sites(offenders)
    end

    test "the scanner flags an alias, a grouped alias and a direct call, not strings or others" do
      violating = [
        "alias ForemanServer.TaskProviders.KataAdapter",
        "alias ForemanServer.TaskProviders.{BeadsAdapter, KataAdapter}",
        "def run, do: ForemanServer.TaskProviders.KataAdapter.claim(\"a\", nil, %{})",
        "@provider ForemanServer.TaskProviders.KataAdapter.BuildProviderError"
      ]

      for expression <- violating do
        source = "defmodule Fixture do\n  #{expression}\nend\n"

        assert kata_adapter_references(source) == [2], "scanner missed: #{expression}"
      end

      clean = """
      defmodule Fixture do
        alias ForemanServer.TaskProviders.BeadsAdapter
        @doc "KataAdapter is resolved by the registry"
        def run, do: ForemanServer.TaskProvider.Registry.route(:claim, nil)
      end
      """

      assert kata_adapter_references(clean) == []
    end

    test "the scanner finds the real references inside task_providers/" do
      assert kata_adapter_references(File.read!(@runner_file)) != []
    end
  end

  ## 3. No claim-state sweep

  describe "no claim-state sweep (AC-004-3, AC-014-3)" do
    test "no --all under task_providers/ or in run_executor.ex" do
      offenders =
        for file <- sweep_scope_files(),
            source = File.read!(file),
            source =~ "--all",
            site <- string_sites(source, "--all") do
          {relative(file), site.line, "--all"}
        end

      assert offenders == [], "claim-state sweep found:\n" <> format_sites(offenders)
    end

    test "run_executor.ex and the other providers never name the kata binary" do
      offenders =
        for file <- sweep_scope_files(),
            not kata_file?(file),
            source = File.read!(file),
            source =~ "kata",
            site <- string_sites(source, "kata") do
          {relative(file), site.line, ~s("kata")}
        end

      assert offenders == [], "claim-state sweep found:\n" <> format_sites(offenders)
    end

    test "the adapter builds only allow-listed kata argv" do
      offenders =
        for site <- adapter_sweep_violations(File.read!(@adapter_file)),
            do: {relative(@adapter_file), site.line, site.what}

      assert offenders == [],
             "the adapter builds a kata command that is not on the allow-list:\n" <>
               format_sites(offenders)
    end

    test "the argv scan sees the real commands: ready in list_ready, status in fail" do
      found = argv_lists(File.read!(@adapter_file))

      assert found |> Enum.map(& &1.verb) |> Enum.uniq() |> Enum.sort() ==
               Enum.sort(@allowed_verbs)

      assert [%{enclosing: :list_ready, args: ["ready", "--unowned", "--json"]}] =
               for(%{verb: "ready"} = argv <- found, do: argv)

      assert [%{enclosing: :fail}] = for(%{verb: "status"} = argv <- found, do: argv)
    end

    test "the kata files emit no [:reconcile, ...] telemetry" do
      offenders =
        for file <- kata_files(),
            site <- reconcile_atoms(File.read!(file)) do
          {relative(file), site.line, ":reconcile"}
        end

      assert offenders == [],
             "Kata must not emit reconcile telemetry:\n" <> format_sites(offenders)
    end

    test "the scanner flags every planted claim-state sweep" do
      planted = [
        ~S|["list", "--owner", "alice"]|,
        ~S|["list", "--status", "claimed"]|,
        ~S|["ready", "--owner", "alice", "--json"]|,
        ~S|["ready", "--all", "--json"]|,
        ~S|["ready", "--json"]|,
        ~S|["audit", "closes"]|,
        ~S|["status", ref, "--json"]|,
        ~S|["claim", ref, "--json"]|,
        ~S|["claim", ref, "--if-unowned", "--force", "--json"]|,
        ~S|["search", "claimed"]|,
        ~S|["events", "--all"]|
      ]

      for expression <- planted do
        source = "defmodule Fixture do\n  def sweep(ref), do: #{expression}\nend\n"

        assert [_ | _] = adapter_sweep_violations(source), "scanner missed: #{expression}"
      end

      assert [_] = string_sites("defmodule Fixture do\n  def a, do: \"--all\"\nend\n", "--all")
      assert [_] = string_sites("defmodule Fixture do\n  def a, do: [\"kata\"]\nend\n", "kata")

      reconcile = "defmodule Fixture do\n  def a, do: [:task_provider, :reconcile, :start]\nend\n"
      assert [_] = reconcile_atoms(reconcile)
    end

    test "the scanner accepts the single permitted enumeration and the single-reference lookup" do
      permitted = """
      defmodule Fixture do
        def list_ready(_config, _opts), do: ["ready", "--unowned", "--json"]
        def fail(ref), do: ["status", ref, "--json"]
        def get(ref), do: ["show", ref, "--json"]
        def schema(fields) when is_list(fields), do: ["labels"]
      end
      """

      assert adapter_sweep_violations(permitted) == []
    end
  end

  ## Scanner plumbing

  defp lib_files, do: Enum.sort(Path.wildcard(Path.join(@lib_root, "**/*.ex")))

  defp sweep_scope_files do
    [@run_executor_file | Path.wildcard(Path.join(@providers_root, "**/*.ex"))]
  end

  defp kata_files, do: Enum.filter(sweep_scope_files(), &kata_file?/1)

  # A Kata provider file: `kata_*.ex`, `system_kata_runner.ex` or anything under `kata_adapter/`.
  # Judged by the path below task_providers/ (the checkout itself may have kata in its name).
  defp kata_file?(file) do
    String.starts_with?(file, @providers_root <> "/") and
      file |> Path.relative_to(@providers_root) |> String.contains?("kata")
  end

  defp adapter_files do
    [@adapter_file | Path.wildcard(Path.join(@providers_root, "kata_adapter/**/*.ex"))]
  end

  defp relative(file), do: Path.relative_to(file, @lib_root)

  defp format_sites(sites) do
    Enum.map_join(sites, "\n", fn {file, line, what} -> "  - lib/#{file}:#{line} (#{what})" end)
  end

  defp parse(source), do: Code.string_to_quoted!(source, columns: true)

  # Depth-first walk that hands `fun.(node, enclosing_definition, acc)` every node, literals
  # included. `enclosing_definition` is the nearest `def`/`defp` node, or nil at module level.
  defp reduce(ast, acc, fun), do: walk(ast, nil, acc, fun)

  defp walk({kind, _meta, [_head, _body]} = definition, _enclosing, acc, fun)
       when kind in @def_kinds do
    definition |> fun.(definition, acc) |> then(&descend(definition, definition, &1, fun))
  end

  defp walk(node, enclosing, acc, fun) do
    node |> fun.(enclosing, acc) |> then(&descend(node, enclosing, &1, fun))
  end

  defp descend({form, _meta, args}, enclosing, acc, fun) when is_list(args) do
    Enum.reduce(args, walk(form, enclosing, acc, fun), &walk(&1, enclosing, &2, fun))
  end

  defp descend({left, right}, enclosing, acc, fun) do
    walk(right, enclosing, walk(left, enclosing, acc, fun), fun)
  end

  defp descend(list, enclosing, acc, fun) when is_list(list) do
    Enum.reduce(list, acc, &walk(&1, enclosing, &2, fun))
  end

  defp descend(_leaf, _enclosing, acc, _fun), do: acc

  defp node_line({_form, meta, _args}) when is_list(meta), do: meta[:line] || 0
  defp node_line(_literal), do: 0

  defp definition_name({_kind, _meta, [head, _body]}) do
    case head do
      {:when, _, [{name, _, _args} | _guards]} -> name
      {name, _, _args} -> name
    end
  end

  defp definition_name(nil), do: nil

  # Strings the subtree spells out: binaries, charlists, and the value of every module attribute
  # it reads.
  defp literals(ast, attributes) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        binary, acc when is_binary(binary) ->
          {binary, [binary | acc]}

        {:@, _, [{name, _, context}]} = node, acc when is_atom(name) and is_atom(context) ->
          {node, Map.get(attributes, name, []) ++ acc}

        list, acc when is_list(list) ->
          {list, if(printable_charlist?(list), do: [List.to_string(list) | acc], else: acc)}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp printable_charlist?(list) do
    list != [] and Enum.all?(list, &(is_integer(&1) and &1 in 32..126))
  end

  # `@name "value"` and `@name ["a", "b"]` definitions anywhere in the file.
  defp attribute_values(ast) do
    {_ast, attributes} =
      Macro.prewalk(ast, %{}, fn
        {:@, _, [{name, _, [value]}]} = node, acc when is_atom(name) ->
          {node, Map.update(acc, name, literals(value, %{}), &(literals(value, %{}) ++ &1))}

        node, acc ->
          {node, acc}
      end)

    attributes
  end

  # `kata` as a word: a path segment or a command word, never `kata.remote`, `kata-agent` or
  # `Kata` in prose.
  defp kata_word?(string) do
    string =~ ~r/(?:\A|[^[:alnum:]_.\-])kata(?:\z|[^[:alnum:]_.\-])/
  end

  ## 1. spawn scan

  # The calls that start an OS process: `{label, args}` when `node` is one.
  defp spawn_call({{:., _, [{:__aliases__, _, [:Kernel]}, :apply]}, _, [target, function, args]}),
    do: spawn_form(target, function, [args])

  defp spawn_call({:apply, _, [target, function, args]}), do: spawn_form(target, function, [args])

  defp spawn_call({{:., _, [target, function]}, _, args}) when is_list(args),
    do: spawn_form(target, function, args)

  defp spawn_call(_node), do: nil

  defp spawn_form({:__aliases__, _, [:System]}, :cmd, args), do: {"System.cmd", args}
  defp spawn_form({:__aliases__, _, [:System]}, :shell, args), do: {"System.shell", args}
  defp spawn_form({:__aliases__, _, [:Port]}, :open, args), do: {"Port.open", args}
  defp spawn_form(:os, :cmd, args), do: {":os.cmd", args}
  defp spawn_form(:erlang, :open_port, args), do: {":erlang.open_port", args}
  defp spawn_form(_target, _function, _args), do: nil

  # `%{line:, call:, args:}` for every call that starts an OS process.
  defp spawn_calls(source) do
    source
    |> parse()
    |> reduce([], fn node, _enclosing, acc ->
      case spawn_call(node) do
        nil -> acc
        {call, args} -> [%{line: node_line(node), call: call, args: args} | acc]
      end
    end)
    |> Enum.reverse()
  end

  # A spawn that spells `kata` in its arguments (module attributes followed), or in the function
  # around it, which catches `bin = "kata"; System.cmd(bin, ...)`.
  defp kata_spawn_sites(source) do
    ast = parse(source)
    attributes = attribute_values(ast)

    ast
    |> reduce([], fn node, enclosing, acc ->
      with {call, args} <- spawn_call(node),
           true <- references_kata?([args, enclosing], attributes) do
        [%{line: node_line(node), call: call} | acc]
      else
        _not_a_kata_spawn -> acc
      end
    end)
    |> Enum.reverse()
  end

  defp references_kata?(scopes, attributes) do
    Enum.any?(scopes, fn scope -> scope |> literals(attributes) |> Enum.any?(&kata_word?/1) end)
  end

  ## 1b. adapter scan: what the adapter must never do

  defp adapter_violations(source) do
    source
    |> parse()
    |> reduce([], fn node, _enclosing, acc ->
      case adapter_violation(node) do
        nil -> acc
        what -> [%{line: node_line(node), what: what} | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp adapter_violation(node) do
    case spawn_call(node) do
      {call, _args} -> "starts a process with #{call}"
      nil -> non_spawn_violation(node)
    end
  end

  defp non_spawn_violation({{:., _, [{:__aliases__, _, [:File]}, function]}, _, _args})
       when function in @file_functions,
       do: "touches a file with File.#{function}"

  defp non_spawn_violation({{:., _, [{:__aliases__, _, [module | _]}, _function]}, _, _args})
       when module in @network_modules,
       do: "uses the #{module} client"

  defp non_spawn_violation({{:., _, [module, _function]}, _, _args})
       when module in @network_erlang,
       do: "uses :#{module}"

  defp non_spawn_violation({{:., _, [{:__aliases__, _, [:System]}, :find_executable]}, _, [name]})
       when name != "kata",
       do: "looks for a binary other than kata"

  defp non_spawn_violation(_node), do: nil

  ## 2. alias scan

  # Lines of every reference to a `KataAdapter` module (an alias, a grouped alias or a call).
  defp kata_adapter_references(source) do
    source
    |> parse()
    |> reduce([], fn
      {:__aliases__, _meta, parts} = node, _enclosing, acc when is_list(parts) ->
        if :KataAdapter in parts, do: [node_line(node) | acc], else: acc

      _node, _enclosing, acc ->
        acc
    end)
    |> Enum.reverse()
  end

  ## 3. sweep scan

  # `%{line:}` for every binary literal equal to `value` (the line is its definition's).
  defp string_sites(source, value) do
    source
    |> parse()
    |> reduce([], fn
      ^value, enclosing, acc -> [%{line: node_line(enclosing)} | acc]
      _node, _enclosing, acc -> acc
    end)
    |> Enum.reverse()
  end

  defp reconcile_atoms(source) do
    source
    |> parse()
    |> reduce([], fn
      :reconcile, enclosing, acc -> [%{line: node_line(enclosing)} | acc]
      _node, _enclosing, acc -> acc
    end)
    |> Enum.reverse()
  end

  # `%{verb:, args:, line:, enclosing:}` for every list literal that starts with a kata verb and has
  # more elements: an argv. `args` holds the literal strings, with nil for a computed element.
  defp argv_lists(source) do
    source
    |> parse()
    |> reduce([], fn
      [verb, _second | _rest] = list, enclosing, acc when is_binary(verb) ->
        if verb in @kata_verbs do
          argv = %{
            verb: verb,
            args: Enum.map(list, &if(is_binary(&1), do: &1)),
            line: node_line(enclosing),
            enclosing: definition_name(enclosing)
          }

          [argv | acc]
        else
          acc
        end

      _node, _enclosing, acc ->
        acc
    end)
    |> Enum.reverse()
  end

  # The forbidden flags anywhere in the adapter, and every argv that is off the allow-list.
  defp adapter_sweep_violations(source) do
    flags =
      for flag <- @forbidden_flags,
          site <- string_sites(source, flag),
          do: Map.put(site, :what, flag)

    argv_problems =
      for %{verb: verb, args: args, line: line, enclosing: enclosing} <- argv_lists(source),
          what = argv_problem(verb, args, enclosing),
          do: %{line: line, what: what}

    flags ++ argv_problems
  end

  defp argv_problem(verb, _args, _enclosing) when verb not in @allowed_verbs,
    do: "kata #{verb} is not on the allow-list"

  defp argv_problem("ready", args, enclosing) do
    unless args == ["ready", "--unowned", "--json"] and enclosing == :list_ready,
      do: "kata ready is allowed only as `ready --unowned --json` in list_ready/2"
  end

  defp argv_problem("status", args, enclosing) do
    unless enclosing == :fail and match?(["status", _ref, "--json"], args),
      do: "kata status is allowed only as the single-reference lookup in fail/3"
  end

  defp argv_problem("claim", args, _enclosing) do
    if "--if-unowned" not in args, do: "kata claim must pass --if-unowned"
  end

  defp argv_problem(_verb, _args, _enclosing), do: nil
end
