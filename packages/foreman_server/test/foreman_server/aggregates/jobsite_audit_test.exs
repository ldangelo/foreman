defmodule ForemanServer.Aggregates.JobsiteAuditTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.JobsiteAudit
  alias ForemanServer.Aggregates.JobsiteAudit.State
  alias ForemanServer.{CommandGateway, EventCodec, EventStore}
  alias ForemanServer.Events.JobsiteRequestAudited

  defp uuid, do: Elixir.EventStore.UUID.uuid4()

  defp field(%{data: data}, key), do: Map.get(data, key, Map.get(data, Atom.to_string(key)))

  defp payload(overrides \\ %{}) do
    Map.merge(
      %{
        route: "/api/jobsites",
        method: "POST",
        outcome: "accepted",
        jobsite_id: "js-1",
        remote_address: "10.0.0.7",
        at: "2026-10-08T00:00:00Z"
      },
      overrides
    )
  end

  defp cmd(p), do: %{type: "jobsite.audit.record", payload: p}
  defp handle(p), do: JobsiteAudit.handle_command(JobsiteAudit.initial_state(), cmd(p))

  test "emits JobsiteRequestAudited on the fixed stream with all fields" do
    assert {:ok, spec} = handle(payload())
    assert spec.stream_id == "jobsite_audit:global"
    assert spec.stream_id == JobsiteAudit.stream_id()
    assert spec.event_type == "JobsiteRequestAudited"

    assert spec.payload == %{
             route: "/api/jobsites",
             method: "POST",
             outcome: "accepted",
             error_code: nil,
             jobsite_id: "js-1",
             remote_address: "10.0.0.7",
             at: "2026-10-08T00:00:00Z"
           }
  end

  test "defaults `at` to an ISO8601 timestamp when absent" do
    assert {:ok, spec} = handle(Map.delete(payload(), :at))
    assert {:ok, _, 0} = DateTime.from_iso8601(spec.payload.at)
  end

  test "accepts string-keyed payloads" do
    p = Map.new(payload(), fn {k, v} -> {Atom.to_string(k), v} end)
    assert {:ok, %{payload: %{route: "/api/jobsites"}}} = handle(p)
  end

  test "rejected request with error_code and no jobsite_id" do
    assert {:ok, spec} =
             handle(payload(%{outcome: "rejected", error_code: "unauthorized", jobsite_id: nil}))

    assert spec.payload.outcome == "rejected"
    assert spec.payload.error_code == "unauthorized"
    assert spec.payload.jobsite_id == nil
  end

  test "accepted request carries jobsite_id" do
    assert {:ok, %{payload: %{jobsite_id: "js-1", error_code: nil}}} = handle(payload())
  end

  for key <- [:route, :method, :remote_address] do
    test "rejects missing or blank #{key}" do
      assert {:error, {:missing_or_invalid, unquote(key)}} =
               handle(Map.delete(payload(), unquote(key)))

      assert {:error, {:missing_or_invalid, unquote(key)}} =
               handle(payload(%{unquote(key) => ""}))

      assert {:error, {:missing_or_invalid, unquote(key)}} =
               handle(payload(%{unquote(key) => 5}))
    end
  end

  test "rejects missing outcome and out-of-enum outcome distinctly" do
    assert {:error, {:missing_or_invalid, :outcome}} = handle(Map.delete(payload(), :outcome))
    assert {:error, {:missing_or_invalid, :outcome}} = handle(payload(%{outcome: :accepted}))
    assert {:error, {:invalid_outcome, "maybe"}} = handle(payload(%{outcome: "maybe"}))
  end

  test "rejected outcome requires error_code" do
    assert {:error, {:error_code_required, "rejected"}} = handle(payload(%{outcome: "rejected"}))

    assert {:error, {:error_code_required, "rejected"}} =
             handle(payload(%{outcome: "rejected", error_code: ""}))

    assert {:error, {:error_code_required, "rejected"}} =
             handle(payload(%{outcome: "rejected", error_code: 401}))
  end

  test "rejects malformed error_code on accepted and malformed jobsite_id" do
    assert {:error, {:missing_or_invalid, :error_code}} = handle(payload(%{error_code: 7}))
    assert {:error, {:missing_or_invalid, :jobsite_id}} = handle(payload(%{jobsite_id: ""}))
    assert {:error, {:missing_or_invalid, :jobsite_id}} = handle(payload(%{jobsite_id: 3}))
  end

  test "unknown commands are unhandled" do
    assert :unhandled =
             JobsiteAudit.handle_command(JobsiteAudit.initial_state(), %{
               type: "nope",
               payload: %{}
             })
  end

  test "replay via apply_event counts typed structs and decoded maps" do
    s0 = JobsiteAudit.initial_state()
    assert %State{total: 0, accepted: 0, rejected: 0} = s0

    {:ok, a} = handle(payload())
    {:ok, r} = handle(payload(%{outcome: "rejected", error_code: "bad_request"}))

    s1 = JobsiteAudit.apply_event(s0, struct!(JobsiteRequestAudited, a.payload))
    s2 = JobsiteAudit.apply_event(s1, %{event_type: r.event_type, payload: r.payload})

    assert %State{total: 2, accepted: 1, rejected: 1} = s2
    assert s2 == JobsiteAudit.apply_event(s1, struct!(JobsiteRequestAudited, r.payload))
    assert s2 == JobsiteAudit.apply_event(s2, %{event_type: "SomethingElse", payload: %{}})
  end

  test "EventCodec registers the event by file placement" do
    assert "JobsiteRequestAudited" in EventCodec.registered()
  end

  test "CommandRouter routes the audit stream to this aggregate" do
    assert ForemanServer.CommandRouter.aggregate_module_for("jobsite_audit:global") ==
             JobsiteAudit

    assert ForemanServer.CommandRouter.aggregate_module_for("jobsite:x") ==
             ForemanServer.Aggregates.Jobsite
  end

  describe "dispatch through CommandGateway.dispatch_system/2" do
    test "appends JobsiteRequestAudited to the fixed stream" do
      marker = "10.9.#{System.unique_integer([:positive])}.1"

      command = %{
        aggregate_id: JobsiteAudit.stream_id(),
        type: "jobsite.audit.record",
        command_id: "audit-#{uuid()}",
        payload:
          payload(%{
            outcome: "rejected",
            error_code: "unauthorized",
            jobsite_id: nil,
            remote_address: marker
          })
      }

      assert {:ok, _} = CommandGateway.dispatch_system(command)
      # Same command_id again is idempotent: no second event.
      assert {:ok, _} = CommandGateway.dispatch_system(command)

      {:ok, events} = EventStore.read_stream_forward(JobsiteAudit.stream_id(), 0, 99_999_999)

      mine =
        Enum.filter(
          events,
          &(&1.event_type == "JobsiteRequestAudited" and field(&1, :remote_address) == marker)
        )

      assert [event] = mine
      assert field(event, :outcome) == "rejected"
      assert field(event, :error_code) == "unauthorized"
      assert field(event, :route) == "/api/jobsites"
    end

    test "malformed audit command is rejected and appends nothing" do
      marker = "10.8.#{System.unique_integer([:positive])}.1"

      command = %{
        aggregate_id: JobsiteAudit.stream_id(),
        type: "jobsite.audit.record",
        command_id: "audit-#{uuid()}",
        payload: payload(%{outcome: "rejected", remote_address: marker})
      }

      assert {:error, _} = CommandGateway.dispatch_system(command)

      # The audit stream is only created by the first accepted append, so when this
      # test runs first it does not exist yet; absent and empty both mean "nothing appended".
      events =
        case EventStore.read_stream_forward(JobsiteAudit.stream_id(), 0, 99_999_999) do
          {:ok, events} -> events
          {:error, :stream_not_found} -> []
        end

      refute Enum.any?(events, &(field(&1, :remote_address) == marker))
    end

    test "is not on the operator allowlist" do
      assert {:error, {:command_not_allowed, "jobsite.audit.record"}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "op-#{uuid()}",
                 aggregate_id: JobsiteAudit.stream_id(),
                 type: "jobsite.audit.record",
                 payload: payload()
               })
    end
  end
end
