# .foreman/beads.exs — work every open bead labeled `foreman-exec`, in
# dependency order, one Jobsite per bead on a running foreman_server.
#
# Run with plain Elixir (OTP 27+) from a machine that has `br` and `bv` and
# this repo's `.beads/` database:
#
#   export FOREMAN_API_TOKEN=...            # the server's bearer token
#   export FOREMAN_PROJECT_ID=my-project    # a project registered on the server
#   export FOREMAN_MERGE_INTO=main          # the branch checked out in the server's copy
#   elixir .foreman/beads.exs
#
# Optional: FOREMAN_API_URL (default http://127.0.0.1:4766),
# FOREMAN_BEADS_LABEL (default foreman-exec), FOREMAN_BEADS_CONCURRENCY
# (default 3, at most the server's max_concurrent_jobsites), and
# FOREMAN_BEADS_DRY_RUN=1 to print what would be dispatched without calling the
# server.
#
# How it orders work: each round asks `bv --robot-plan --label <label>` for the
# actionable plan and takes the FIRST item of every track. Items later in a
# track depend on earlier ones, so they are not started until the earlier one
# is finished; the heads of different tracks are independent and run in
# parallel. After the round each completed jobsite is merged into
# FOREMAN_MERGE_INTO one at a time (a merge changes the server's checkout, so
# merging concurrently would race), and only then is its bead closed with
# `br close`, so the next round's agents start from code that includes it.
#
# A bead is closed only when the agent emitted the completion signal AND its
# branch merged. Anything else (failed, no signal, merge conflict) is reported,
# left open, and skipped for the rest of this run; the beads that depend on it
# stay blocked, so they are not started either.
#
# `br close` rewrites .beads/ in the checkout you run this from; commit that
# yourself. The sandbox image must exist on the SERVER's Docker (see README.md).

# Pin `ref: "<tag or sha>"` here to stop following the default branch.
Mix.install([{:foreman_client, github: "ldangelo/foreman", sparse: "packages/foreman_client"}])

defmodule Beads do
  # Bead ids become branch names and are passed to `br`; refuse anything that is
  # not a plain token rather than trying to quote it.
  @safe_id ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

  def run!(cmd, args, repo) do
    case System.cmd(cmd, args, cd: repo, stderr_to_stdout: true) do
      {out, 0} -> out
      {out, code} -> raise "#{cmd} #{Enum.join(args, " ")} exited #{code}: #{String.trim(out)}"
    end
  end

  # First item of every track, skipping beads already given up on.
  def heads(repo, label, skip) do
    plan = run!("bv", ["--robot-plan", "--label", label], repo) |> :json.decode()
    tracks = get_in(plan, ["plan", "tracks"]) || []

    tracks
    |> Enum.flat_map(fn track -> Enum.take(track["items"] || [], 1) end)
    |> Enum.filter(&(&1["status"] == "open" and not MapSet.member?(skip, &1["id"])))
  end

  def safe_id?(id), do: is_binary(id) and Regex.match?(@safe_id, id)

  def bead(repo, id) do
    case run!("br", ["show", id, "--json"], repo) |> :json.decode() do
      [bead | _] -> bead
      %{} = bead -> bead
    end
  end

  def prompt(template, bead) do
    template
    |> String.replace("{{BEAD_ID}}", bead["id"])
    |> String.replace("{{TITLE}}", bead["title"] || "")
    |> String.replace("{{DESCRIPTION}}", bead["description"] || "")
  end

  def signalled?(jobsite) do
    case List.last(jobsite["iterations"] || []) do
      %{"signalled?" => true} -> true
      _ -> false
    end
  end
end

repo = Path.expand("..", __DIR__)
label = System.get_env("FOREMAN_BEADS_LABEL") || "foreman-exec"
dry_run? = System.get_env("FOREMAN_BEADS_DRY_RUN") == "1"
concurrency = String.to_integer(System.get_env("FOREMAN_BEADS_CONCURRENCY") || "3")
template = File.read!(Path.join(__DIR__, "prompts/beads.md"))

{client, project_id, into} =
  if dry_run? do
    {nil, nil, nil}
  else
    {Foreman.Client.new(),
     System.get_env("FOREMAN_PROJECT_ID") || raise("FOREMAN_PROJECT_ID is not set"),
     System.get_env("FOREMAN_MERGE_INTO") || raise("FOREMAN_MERGE_INTO is not set")}
  end

dispatch = fn bead ->
  spec = %{
    "project_id" => project_id,
    "strategy" => %{"branch" => "agent/#{bead["id"]}"},
    "sandbox" => "docker",
    "agent" => %{"provider" => "claude", "model" => "claude-opus-4-8", "approval_mode" => "auto_approve"},
    "prompt" => Beads.prompt(template, bead),
    "max_iterations" => 5,
    "completion_signal" => "<promise>COMPLETE</promise>"
  }

  {bead["id"], Foreman.Client.run(client, spec)}
end

finish = fn
  {id, {:ok, jobsite}} ->
    cond do
      not Beads.signalled?(jobsite) ->
        IO.puts("NOT COMPLETE #{id}: no completion signal after #{length(jobsite["iterations"] || [])} iterations; left open")
        {:skip, id}

      true ->
        case Foreman.Client.merge(client, jobsite["jobsite_id"], into) do
          {:ok, _} ->
            Beads.run!("br", ["close", id, "--reason", "Implemented by jobsite #{jobsite["jobsite_id"]}"], repo)
            IO.puts("done #{id} (merged #{jobsite["branch"]} into #{into})")
            :ok

          {:error, {409, %{"error" => "merge_conflict"}}} ->
            IO.puts("CONFLICT #{id}: branch #{jobsite["branch"]} left for manual merge; bead left open")
            {:skip, id}

          {:error, reason} ->
            IO.puts("MERGE FAILED #{id}: #{inspect(reason)}; bead left open")
            {:skip, id}
        end
    end

  {id, {:error, reason}} ->
    IO.puts("FAILED #{id}: #{inspect(reason)}; bead left open")
    {:skip, id}
end

loop = fn loop, skip, round ->
  ready = Beads.heads(repo, label, skip)

  {ready, skip} =
    Enum.reduce(ready, {[], skip}, fn item, {ok, skip} ->
      if Beads.safe_id?(item["id"]) do
        {[item | ok], skip}
      else
        IO.puts("SKIP #{inspect(item["id"])}: not a plain bead id")
        {ok, MapSet.put(skip, item["id"])}
      end
    end)

  ready = Enum.reverse(ready)

  cond do
    ready == [] ->
      IO.puts("no more actionable `#{label}` beads (#{MapSet.size(skip)} skipped)")

    dry_run? ->
      IO.puts("round #{round}: would dispatch #{Enum.map_join(ready, ", ", & &1["id"])}")

    true ->
      IO.puts("round #{round}: #{Enum.map_join(ready, ", ", & &1["id"])}")
      beads = Enum.map(ready, &Beads.bead(repo, &1["id"]))

      outcomes =
        beads
        |> Task.async_stream(dispatch, max_concurrency: concurrency, timeout: :infinity)
        |> Enum.map(fn {:ok, pair} -> pair end)

      # Merges and closes are sequential: each changes the server's checkout.
      skip =
        Enum.reduce(outcomes, skip, fn outcome, skip ->
          case finish.(outcome) do
            {:skip, id} -> MapSet.put(skip, id)
            :ok -> skip
          end
        end)

      loop.(loop, skip, round + 1)
  end
end

loop.(loop, MapSet.new(), 1)
