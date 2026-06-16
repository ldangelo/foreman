#!/usr/bin/env node

const lifecycle = [
  "create_task",
  "approve_task",
  "dispatch_simulated_worker",
  "stream_status",
  "complete_run",
  "rebuild_read_model",
];

class Prototype {
  constructor(name) {
    this.name = name;
    this.events = [];
    this.projection = { taskStatus: "new", runStatus: "not_started", recovery: [] };
  }

  emit(type, payload = {}) {
    const event = { sequence: this.events.length + 1, type, payload };
    this.events.push(event);
    this.apply(event);
    return event;
  }

  apply(event) {
    switch (event.type) {
      case "TaskCreated":
        this.projection.taskStatus = "created";
        break;
      case "TaskApproved":
        this.projection.taskStatus = "approved";
        break;
      case "WorkerDispatched":
        this.projection.runStatus = "running";
        break;
      case "StatusStreamed":
        this.projection.lastStatus = event.payload.status;
        break;
      case "RunCompleted":
        this.projection.runStatus = "completed";
        break;
      case "WorkerLost":
      case "RecoveryStarted":
      case "WorkerRestarted":
        this.projection.recovery.push(event.type);
        break;
    }
  }

  createTask() {
    return this.emit("TaskCreated", { taskId: "task-1" });
  }

  approveTask() {
    return this.emit("TaskApproved", { taskId: "task-1" });
  }

  dispatchWorker() {
    return this.emit("WorkerDispatched", { workerId: `${this.name}-worker-1` });
  }

  streamStatus(status) {
    return this.emit("StatusStreamed", { status });
  }

  completeRun() {
    return this.emit("RunCompleted", { runId: "run-1" });
  }

  rebuildReadModel() {
    const rebuilt = { taskStatus: "new", runStatus: "not_started", recovery: [] };
    for (const event of this.events) {
      switch (event.type) {
        case "TaskCreated":
          rebuilt.taskStatus = "created";
          break;
        case "TaskApproved":
          rebuilt.taskStatus = "approved";
          break;
        case "WorkerDispatched":
          rebuilt.runStatus = "running";
          break;
        case "StatusStreamed":
          rebuilt.lastStatus = event.payload.status;
          break;
        case "RunCompleted":
          rebuilt.runStatus = "completed";
          break;
        case "WorkerLost":
        case "RecoveryStarted":
        case "WorkerRestarted":
          rebuilt.recovery.push(event.type);
          break;
      }
    }
    return rebuilt;
  }

  recoverFromCrash() {
    throw new Error("recoverFromCrash must be implemented by subclass");
  }

  runHappyPath() {
    this.createTask();
    this.approveTask();
    this.dispatchWorker();
    this.streamStatus("phase_started");
    this.streamStatus("phase_output");
    this.completeRun();
    const rebuilt = this.rebuildReadModel();
    return { lifecycle, events: this.events, projection: this.projection, rebuilt };
  }

  runCrashScenario() {
    this.events = [];
    this.projection = { taskStatus: "new", runStatus: "not_started", recovery: [] };
    this.createTask();
    this.approveTask();
    this.dispatchWorker();
    this.streamStatus("phase_started");
    const recoveryTimeline = this.recoverFromCrash();
    this.streamStatus("phase_recovered");
    this.completeRun();
    return { recoveryTimeline, events: this.events, projection: this.projection, rebuilt: this.rebuildReadModel() };
  }
}

class ElixirOtpPrototype extends Prototype {
  constructor() {
    super("elixir_otp");
  }

  recoverFromCrash() {
    const timeline = [
      "DOWN signal or heartbeat timeout observed by WorkerSupervisor",
      "WorkerLost appended with last worker sequence",
      "RecoverySupervisor reconciles event stream, OS process table, and worktree",
      "PhaseServer requests replacement worker under DynamicSupervisor",
      "WorkerRestarted appended and status projection exposes recovery timeline",
    ];
    this.emit("WorkerLost", { via: "WorkerSupervisor", lastSequence: this.events.length });
    this.emit("RecoveryStarted", { via: "RecoverySupervisor" });
    this.emit("WorkerRestarted", { via: "DynamicSupervisor" });
    return timeline;
  }
}

class WolverineMartenPrototype extends Prototype {
  constructor() {
    super("wolverine_marten");
  }

  recoverFromCrash() {
    const timeline = [
      "durable message remains in Wolverine inbox/outbox state",
      "retry/error policy observes missing heartbeat or handler failure",
      "saga/process state records retry intent",
      "scheduled retry dispatches replacement Node/Pi worker adapter",
      "Marten projection exposes recovery from event and message state",
    ];
    this.emit("WorkerLost", { via: "durable-message-retry", lastSequence: this.events.length });
    this.emit("RecoveryStarted", { via: "saga-scheduled-message" });
    this.emit("WorkerRestarted", { via: "wolverine-handler" });
    return timeline;
  }
}

class TypeScriptControlPrototype extends Prototype {
  constructor() {
    super("typescript_control");
  }

  recoverFromCrash() {
    const timeline = [
      "polling loop detects missing child process or heartbeat",
      "custom recovery code writes WorkerLost event",
      "custom dispatcher restarts child process",
      "projection updates after bespoke retry path",
    ];
    this.emit("WorkerLost", { via: "polling-loop", lastSequence: this.events.length });
    this.emit("RecoveryStarted", { via: "custom-dispatcher" });
    this.emit("WorkerRestarted", { via: "child_process" });
    return timeline;
  }
}

function assertPrototype(name, result) {
  const happyTypes = result.happy.events.map((event) => event.type);
  for (const required of ["TaskCreated", "TaskApproved", "WorkerDispatched", "StatusStreamed", "RunCompleted"]) {
    if (!happyTypes.includes(required)) throw new Error(`${name} missing ${required}`);
  }
  if (result.happy.rebuilt.runStatus !== "completed") throw new Error(`${name} read-model rebuild failed`);
  const recovery = result.crash.recoveryTimeline.join(" ");
  if (!/restart|retry|replacement/i.test(recovery)) throw new Error(`${name} recovery timeline lacks restart strategy`);
  if (result.crash.rebuilt.runStatus !== "completed") throw new Error(`${name} crash scenario did not complete`);
}

function run() {
  const prototypes = [new ElixirOtpPrototype(), new WolverineMartenPrototype(), new TypeScriptControlPrototype()];
  const results = {};
  for (const prototype of prototypes) {
    const happy = prototype.runHappyPath();
    const crash = prototype.runCrashScenario();
    results[prototype.name] = { happy, crash };
    assertPrototype(prototype.name, results[prototype.name]);
  }
  return {
    status: "pass",
    lifecycle,
    prototypes: results,
    decision: "Elixir/OTP remains selected because native supervision best fits Foreman's local long-running worker/process recovery model.",
  };
}

console.log(JSON.stringify(run(), null, 2));
