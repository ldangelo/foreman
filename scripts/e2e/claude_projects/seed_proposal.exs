# Seeds one coordinator PROPOSAL for the project workspace's "Proposed threads" card without a model turn (bead
# foreman-l2ab7): an open coordinator-sourced task and a `propose_threads` action
# whose result_ref names it -- the same facts a real propose turn writes. Evaluated ON THE SERVER NODE by `rpc`; the
# caller binds `project_id` and `task_id` first. Prints `SEEDED <task_id>`.
alias ForemanServer.CommandGateway

d = fn attrs -> {:ok, _} = CommandGateway.dispatch_system(attrs) end
coord = "coordinator:" <> project_id

d.(%{command_id: "seed-task-" <> task_id, aggregate_id: "task:" <> task_id, type: "task.create",
     payload: %{task_id: task_id, project_id: project_id, title: "Proposed: seeded thread", status: "open",
                source: "coordinator", provider_tracked: false}})

turn = "turn-" <> task_id
d.(%{command_id: "seed-turn-" <> task_id, aggregate_id: coord, type: "coordinator.turn.start",
     payload: %{project_id: project_id, turn_id: turn, attempt: 1, trigger_message_ids: []}})
d.(%{command_id: "seed-act-" <> task_id, aggregate_id: coord, type: "coordinator.action.record",
     payload: %{project_id: project_id, turn_id: turn, action_id: "a-" <> task_id, kind: "propose_threads",
                status: "proposed", params: %{}, result_ref: %{"task_ids" => [task_id]}}})
d.(%{command_id: "seed-done-" <> task_id, aggregate_id: coord, type: "coordinator.turn.complete",
     payload: %{project_id: project_id, turn_id: turn, cursor_message_id: "seed-" <> task_id}})

IO.puts("SEEDED " <> task_id)
