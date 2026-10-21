defmodule ForemanServer.Review.ArchiveTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.Review.Archive
  alias ForemanServer.Review.Error

  setup do
    original = Application.get_env(:foreman_server, :review, [])
    on_exit(fn -> Application.put_env(:foreman_server, :review, original) end)
    {:ok, original: original}
  end

  defp put_review(original, overrides),
    do: Application.put_env(:foreman_server, :review, Keyword.merge(original, overrides))

  defp event(type, text) do
    Jido.Harness.Event.new!(%{
      type: type,
      provider: :claude,
      timestamp: "2026-01-01T00:00:00Z",
      payload: if(text, do: %{"text" => text}, else: %{})
    })
  end

  describe "dir/3" do
    test "defaults under <repo>/.foreman/sessions", %{original: original} do
      put_review(original, archive_root: nil)

      assert Archive.dir(:run, "run-1", "/repo") == "/repo/.foreman/sessions/run/run-1"
      assert Archive.dir(:jobsite, "j-1", "/repo") == "/repo/.foreman/sessions/jobsite/j-1"
    end

    test "configured root is used verbatim with kind/subject appended", %{original: original} do
      put_review(original, archive_root: "/elsewhere")
      assert Archive.dir(:run, "run-1", "/repo") == "/elsewhere/run/run-1"
    end
  end

  describe "manifest" do
    test "init fills every key with explicit nulls and round-trips", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "a")
      assert :ok = Archive.init(dir, %{"kind" => "run", subject_id: "run-1"})

      assert {:ok, manifest} = Archive.read_manifest(dir)
      assert manifest["schema"] == "foreman.review.manifest.v1"
      assert manifest["kind"] == "run"
      assert manifest["subject_id"] == "run-1"
      assert Map.has_key?(manifest, "bead_id") and manifest["bead_id"] == nil
      assert manifest["capture_errors"] == []
      assert manifest["transcript_truncated"] == false
      assert manifest["diff_status"] == "unavailable"

      assert manifest["request"] == %{
               "source" => nil,
               "title" => nil,
               "prompt" => nil,
               "workflow_name" => nil
             }
    end

    test "merge_manifest overlays keys and keeps the rest", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "b")
      :ok = Archive.init(dir, %{"kind" => "run"})
      assert :ok = Archive.merge_manifest(dir, %{status: "completed"})

      {:ok, manifest} = Archive.read_manifest(dir)
      assert manifest["status"] == "completed"
      assert manifest["kind"] == "run"
    end

    test "read_manifest distinguishes missing from malformed", %{tmp_dir: tmp} do
      assert {:error, %Error{code: :archive_missing}} =
               Archive.read_manifest(Path.join(tmp, "none"))

      dir = Path.join(tmp, "c")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "manifest.json"), "{not json")
      assert {:error, %Error{code: :archive_malformed}} = Archive.read_manifest(dir)

      File.write!(Path.join(dir, "manifest.json"), "[1]")
      assert {:error, %Error{code: :archive_malformed}} = Archive.read_manifest(dir)
    end

    test "put_manifest leaves no temp files behind", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "d")
      :ok = Archive.init(dir, %{})
      assert File.ls!(dir) == ["manifest.json"]
    end
  end

  describe "append_events/2" do
    test "serialises type/timestamp/text and nil text when payload has none", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "e")
      :ok = Archive.init(dir, %{})

      assert :ok =
               Archive.append_events(dir, [event(:output_text_final, "hello"), event(:usage, nil)])

      lines =
        dir |> Path.join("transcript.jsonl") |> File.read!() |> String.split("\n", trim: true)

      assert Enum.map(lines, &Jason.decode!/1) == [
               %{
                 "type" => "output_text_final",
                 "timestamp" => "2026-01-01T00:00:00Z",
                 "text" => "hello",
                 "stream" => nil
               },
               %{
                 "type" => "usage",
                 "timestamp" => "2026-01-01T00:00:00Z",
                 "text" => nil,
                 "stream" => nil
               }
             ]

      assert {:ok, %{"transcript_truncated" => false}} = Archive.read_manifest(dir)
    end

    test "stops at max_transcript_bytes and flags the manifest", %{
      tmp_dir: tmp,
      original: original
    } do
      put_review(original, max_transcript_bytes: 200)
      dir = Path.join(tmp, "f")
      :ok = Archive.init(dir, %{})

      events = for i <- 1..20, do: event(:output_text_delta, "chunk #{i}")
      assert :ok = Archive.append_events(dir, events)

      path = Path.join(dir, "transcript.jsonl")
      assert File.stat!(path).size <= 200
      kept = path |> File.read!() |> String.split("\n", trim: true) |> length()
      assert kept > 0 and kept < 20
      assert {:ok, %{"transcript_truncated" => true}} = Archive.read_manifest(dir)

      # a later append against a full file writes nothing more
      size = File.stat!(path).size
      assert :ok = Archive.append_events(dir, [event(:output_text_delta, "late")])
      assert File.stat!(path).size == size
    end
  end

  describe "write failures" do
    test "write_file failure is an error and is recorded in capture_errors", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "g")
      :ok = Archive.init(dir, %{})
      # a directory occupying the target name makes the rename fail
      File.mkdir_p!(Path.join(dir, "diff.patch"))

      assert {:error, %Error{code: :archive_write_failed}} =
               Archive.write_file(dir, "diff.patch", "x")

      {:ok, manifest} = Archive.read_manifest(dir)

      assert [%{"stage" => "write_file:diff.patch", "code" => "archive_write_failed"}] =
               manifest["capture_errors"]
    end

    test "init under a path whose parent is a regular file fails", %{tmp_dir: tmp} do
      blocker = Path.join(tmp, "blocker")
      File.write!(blocker, "file")

      assert {:error, %Error{code: :archive_write_failed}} =
               Archive.init(Path.join(blocker, "sub"), %{})
    end

    test "write_file rejects non-bare names", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "h")
      :ok = Archive.init(dir, %{})

      assert {:error, %Error{code: :archive_write_failed}} =
               Archive.write_file(dir, "../escape.txt", "x")

      refute File.exists?(Path.join(tmp, "escape.txt"))
    end
  end

  test "capture_enabled?/0 follows config", %{original: original} do
    put_review(original, capture: true)
    assert Archive.capture_enabled?()
    put_review(original, capture: false)
    refute Archive.capture_enabled?()
  end

  describe "encode_event/1 with payloads real providers emit" do
    defp decode(type, payload) do
      %{type: type, timestamp: "t", payload: payload} |> Archive.encode_event() |> Jason.decode!()
    end

    test "text events keep their text" do
      assert %{"type" => "output_text_delta", "text" => "hi", "stream" => nil} =
               decode(:output_text_delta, %{"text" => "hi"})
    end

    test "a provider_event carrying a process stream line is kept with its stream" do
      assert %{"type" => "provider_event", "text" => "boom\n", "stream" => "stderr"} =
               decode(:provider_event, %{"data" => "boom\n", "stream" => "stderr"})
    end

    test "events with no text at all have null text and stream" do
      assert %{"text" => nil, "stream" => nil} =
               decode(:provider_event, %{"mapped" => false, "type" => "message_end"})
    end
  end
end
