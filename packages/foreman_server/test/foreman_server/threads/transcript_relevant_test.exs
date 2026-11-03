defmodule ForemanServer.Threads.TranscriptRelevantTest do
  # `Transcript.relevant?/2`: which broadcast `ProjectionStore` events can change a thread's turns.
  # The SSE tail (`ThreadTranscriptController`) and the workspace's thread pane both ask it.
  use ExUnit.Case, async: true

  alias EventStore.{EventData, RecordedEvent}
  alias ForemanServer.Events.WorkerStdout
  alias ForemanServer.Threads.Transcript

  @run "run:run-mine-1"
  @jobsite "jobsite:job-mine-1"

  defp worker_stdout(run_id), do: %WorkerStdout{run_id: run_id, worker_id: "w1"}

  describe "an event of this thread" do
    test "that names its run in the payload, the data, a typed event or its stream" do
      for event <- [
            %{event_type: "WorkerStdout", payload: %{run_id: "run-mine-1"}},
            %{event_type: "WorkerStdout", data: %{run_id: "run-mine-1"}},
            %EventData{event_type: "WorkerStdout", data: worker_stdout("run-mine-1")},
            %RecordedEvent{
              event_type: "WorkerStdout",
              data: %{},
              stream_uuid: "worker:run-mine-1:w1"
            },
            %{event_type: "RunPaused", data: %{}, stream_id: "run:run-mine-1"}
          ] do
        assert Transcript.relevant?(event, @run), inspect(event)
      end
    end

    test "that names its jobsite or the subject of its review" do
      for event <- [
            %{event_type: "JobsiteIterationCompleted", payload: %{jobsite_id: "job-mine-1"}},
            %{event_type: "ReviewRecorded", payload: %{subject_id: "job-mine-1"}}
          ] do
        assert Transcript.relevant?(event, @jobsite), inspect(event)
      end
    end
  end

  describe "an event of another thread" do
    test "is not relevant, whatever field names the other run, jobsite or stream" do
      for event <- [
            %{event_type: "WorkerStdout", payload: %{run_id: "run-other-2"}},
            %{event_type: "WorkerStdout", data: %{run_id: "run-other-2"}},
            %EventData{event_type: "WorkerStdout", data: worker_stdout("run-other-2")},
            %RecordedEvent{
              event_type: "WorkerStdout",
              data: %{},
              stream_uuid: "worker:run-other-2:w1"
            },
            %{event_type: "RunPaused", data: %{}, stream_id: "run:run-other-2"},
            %{event_type: "JobsiteIterationCompleted", payload: %{jobsite_id: "job-other-2"}},
            %{event_type: "ReviewRecorded", payload: %{subject_id: "run-other-2"}}
          ] do
        refute Transcript.relevant?(event, @run), inspect(event)
        refute Transcript.relevant?(event, @jobsite), inspect(event)
      end
    end
  end

  test "an event that names nothing readable is relevant: a re-read costs less than a missed turn" do
    for event <- [
          %{event_type: "Heartbeat", payload: %{}},
          %{event_type: "Heartbeat", data: %{n: 1}},
          %{event_type: "Heartbeat"},
          :not_even_a_map
        ] do
      assert Transcript.relevant?(event, @run), inspect(event)
    end
  end
end
