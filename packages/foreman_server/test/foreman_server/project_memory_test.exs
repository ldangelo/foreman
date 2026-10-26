defmodule ForemanServer.ProjectMemoryTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.{CommandRouter, EventStore, ProjectionStore, ProjectMemory}
  alias ForemanServer.ProjectMemory.{Drift, Error, SyncReport}

  @agent %{kind: :agent, ref: "run-1"}
  @operator %{kind: :operator, ref: "op-1"}

  setup %{tmp_dir: dir} do
    project_id = "pm-#{System.unique_integer([:positive])}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.register",
        aggregate_id: "project:#{project_id}",
        payload: %{
          project_id: project_id,
          path: dir,
          config: %{env: %{"DEPLOY_TOKEN" => "s3cr3t-value-xyz"}}
        }
      })

    {:ok, project_id: project_id, dir: dir}
  end

  defp mem(dir, file), do: Path.join([dir, ".foreman", "memory", file])

  defp stream_events(project_id) do
    case EventStore.read_stream_forward("project_memory:#{project_id}", 0, 1000) do
      {:ok, events} -> events
      {:error, :stream_not_found} -> []
    end
  end

  defp attrs(name, content, description \\ "d"),
    do: %{name: name, description: description, content: content}

  describe "write" do
    test "lands the file, one event and the projection entry with agent attribution",
         %{project_id: p, dir: dir} do
      assert {:ok, topic} =
               ProjectMemory.write(p, attrs("conventions", "Use mix format."), @agent)

      assert File.read!(mem(dir, "conventions.md")) =~ "Use mix format."

      assert [%{name: "conventions", author_kind: "agent", author_ref: "run-1", sha256: sha}] =
               ProjectionStore.project_memory(p)

      assert sha == topic.sha256

      assert %{version: 1, author_kind: "agent", author_ref: "run-1", updated_at: updated_at} =
               topic

      assert is_binary(updated_at)
      assert length(stream_events(p)) == 1
    end

    test "an identical write twice appends exactly one event", %{project_id: p} do
      {:ok, _} = ProjectMemory.write(p, attrs("a", "same"), @agent)
      {:ok, _} = ProjectMemory.write(p, attrs("a", "same"), @agent)
      assert length(stream_events(p)) == 1
    end

    test "the project's configured secret values are redacted from disk", %{
      project_id: p,
      dir: dir
    } do
      {:ok, _} =
        ProjectMemory.write(
          p,
          attrs("deploy", "Deploy uses s3cr3t-value-xyz as its key."),
          @agent
        )

      refute File.read!(mem(dir, "deploy.md")) =~ "s3cr3t-value-xyz"
    end

    test "unknown and archived projects are rejected with typed errors and write nothing", %{
      project_id: p,
      dir: dir
    } do
      assert {:error, %Error{code: :project_not_found}} =
               ProjectMemory.write("nope-#{p}", attrs("a", "x"), @agent)

      {:ok, _} =
        CommandRouter.dispatch(%{
          type: "project.archive",
          aggregate_id: "project:#{p}",
          payload: %{project_id: p}
        })

      assert {:error, %Error{code: :project_archived}} =
               ProjectMemory.write(p, attrs("a", "x"), @agent)

      assert {:error, %Error{code: :project_archived}} = ProjectMemory.forget(p, "a", @agent)
      refute File.exists?(mem(dir, "a.md"))
      assert stream_events(p) == []
      # reads stay available on an archived project
      assert {:ok, []} = ProjectMemory.list(p)
    end

    test "when the audit command is rejected the previous file and index are restored",
         %{project_id: p, dir: dir} do
      {:ok, _} = ProjectMemory.write(p, attrs("a", "original", "orig"), @agent)
      before_file = File.read!(mem(dir, "a.md"))
      before_index = File.read!(mem(dir, "MEMORY.md"))

      # An author ref the aggregate rejects makes the dispatch fail after the file landed.
      bad = %{kind: :agent, ref: 123}

      assert {:error, %Error{code: :audit_failed}} =
               ProjectMemory.write(p, attrs("a", "changed", "new"), bad)

      assert File.read!(mem(dir, "a.md")) == before_file
      assert File.read!(mem(dir, "MEMORY.md")) == before_index

      # a brand-new topic whose audit fails leaves no file behind
      assert {:error, %Error{code: :audit_failed}} =
               ProjectMemory.write(p, attrs("fresh", "x"), bad)

      refute File.exists?(mem(dir, "fresh.md"))
      assert File.read!(mem(dir, "MEMORY.md")) == before_index
    end

    test "20 concurrent writes of distinct topics all land and the index has 20 lines",
         %{project_id: p} do
      results =
        1..20
        |> Task.async_stream(
          &ProjectMemory.write(p, attrs("topic-#{&1}", "fact #{&1}", "d#{&1}"), @agent),
          max_concurrency: 20,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert {:ok, index} = ProjectMemory.index(p)
      assert index |> String.split("\n", trim: true) |> length() == 20
      assert length(ProjectionStore.project_memory(p)) == 20
    end
  end

  describe "forget" do
    test "removes file, index line and projection entry", %{project_id: p, dir: dir} do
      {:ok, _} = ProjectMemory.write(p, attrs("a", "x"), @agent)
      {:ok, _} = ProjectMemory.write(p, attrs("b", "y"), @agent)
      assert {:ok, _} = ProjectMemory.forget(p, "a", @operator)

      refute File.exists?(mem(dir, "a.md"))
      assert {:ok, "- [b](b.md) - d\n"} = ProjectMemory.index(p)
      assert [%{name: "b"}] = ProjectionStore.project_memory(p)
      assert {:error, %Error{code: :not_found}} = ProjectMemory.forget(p, "a", @operator)
    end

    test "a failed audit restores the file", %{project_id: p, dir: dir} do
      {:ok, _} = ProjectMemory.write(p, attrs("a", "keep me"), @agent)

      assert {:error, %Error{code: :audit_failed}} =
               ProjectMemory.forget(p, "a", %{kind: :operator, ref: 5})

      assert File.read!(mem(dir, "a.md")) =~ "keep me"
      assert {:ok, "- [a](a.md) - d\n"} = ProjectMemory.index(p)
    end

    test "an unreadable sibling topic fails the forget with the topic still on disk and no event",
         %{project_id: p, dir: dir} do
      {:ok, _} = ProjectMemory.write(p, attrs("a", "keep me"), @agent)
      events_before = length(stream_events(p))
      # A directory named like a topic file cannot be read as a topic.
      File.mkdir_p!(mem(dir, "bad.md"))

      assert {:error, %Error{code: :write_failed}} = ProjectMemory.forget(p, "a", @operator)

      assert File.read!(mem(dir, "a.md")) =~ "keep me"
      assert length(stream_events(p)) == events_before
      assert [%{name: "a"}] = ProjectionStore.project_memory(p)
    end

    test "write A, change to B, write A again records all three audit events", %{project_id: p} do
      {:ok, _} = ProjectMemory.write(p, attrs("a", "A"), @agent)
      {:ok, _} = ProjectMemory.write(p, attrs("a", "B"), @agent)
      {:ok, _} = ProjectMemory.write(p, attrs("a", "A"), @agent)
      assert length(stream_events(p)) == 3
      assert [%{version: 3}] = ProjectionStore.project_memory(p)
    end
  end

  describe "list/read" do
    test "read returns the redacted content and audit metadata", %{project_id: p} do
      {:ok, _} = ProjectMemory.write(p, attrs("a", "hello"), @agent)

      assert {:ok, %{name: "a", author_kind: "agent", version: 1}, "hello"} =
               ProjectMemory.read(p, "a")

      assert {:error, %Error{code: :not_found}} = ProjectMemory.read(p, "zzz")
      assert {:error, %Error{code: :name_invalid}} = ProjectMemory.read(p, "../etc")
    end
  end

  describe "verify / sync" do
    test "exact drift triple, convergence, redaction of hand edits and idempotence",
         %{project_id: p, dir: dir} do
      {:ok, _} = ProjectMemory.write(p, attrs("a", "original"), @agent)
      {:ok, _} = ProjectMemory.write(p, attrs("c", "to be deleted"), @agent)
      assert {:ok, %Drift{} = clean} = ProjectMemory.verify(p)
      assert Drift.empty?(clean)

      File.write!(mem(dir, "a.md"), "edited by hand\n")
      File.write!(mem(dir, "b.md"), "hand added; DEPLOY_TOKEN=live-token-123 end\n")
      File.rm!(mem(dir, "c.md"))

      assert {:ok, %Drift{missing_on_disk: ["c"], untracked_on_disk: ["b"], sha_mismatch: ["a"]}} =
               ProjectMemory.verify(p)

      assert {:ok, %SyncReport{recorded: ["a", "b"], forgotten: ["c"], failed: []}} =
               ProjectMemory.sync(p, @operator)

      assert {:ok, drift} = ProjectMemory.verify(p)
      assert Drift.empty?(drift)
      refute File.read!(mem(dir, "b.md")) =~ "live-token-123"
      assert {:ok, "- [a](a.md)\n- [b](b.md)\n"} = ProjectMemory.index(p)

      projected = Map.new(ProjectionStore.project_memory(p), &{&1.name, &1})

      assert %{
               "a" => %{author_kind: "operator", author_ref: "op-1"},
               "b" => %{author_kind: "operator"}
             } = projected

      refute Map.has_key?(projected, "c")

      count = length(stream_events(p))

      assert {:ok, %SyncReport{recorded: [], forgotten: [], failed: []}} =
               ProjectMemory.sync(p, @operator)

      assert length(stream_events(p)) == count
    end

    test "a hand edit that is not durable is reported as failed, not silently skipped",
         %{project_id: p, dir: dir} do
      File.mkdir_p!(Path.dirname(mem(dir, "x.md")))
      File.write!(mem(dir, "dump.md"), String.duplicate("same log line here\n", 50))

      assert {:ok,
              %SyncReport{recorded: [], failed: [{"dump", %Error{code: :content_not_durable}}]}} =
               ProjectMemory.sync(p, @operator)
    end
  end
end
