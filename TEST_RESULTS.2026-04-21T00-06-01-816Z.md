
> @oftheangels/foreman@0.1.0 test:unit
> vitest run -c vitest.unit.config.ts


[1m[46m RUN [49m[22m [36mv4.1.1 [39m[90m/Users/ldangelo/Development/Fortium/.foreman-worktrees/foreman/foreman-56b46[39m

 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/doctor-br-backend.test.ts [2m([22m[2m22 tests[22m[2m)[22m[33m 654[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/detached-spawn.test.ts [2m([22m[2m2 tests[22m[2m)[22m[33m 911[2mms[22m[39m
     [33m[2m✓[22m[39m detached child process writes a file after parent exits [33m 305[2mms[22m[39m
     [33m[2m✓[22m[39m detached child continues after SIGINT to process group [33m 605[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/doctor.test.ts [2m([22m[2m81 tests[22m[2m)[22m[33m 753[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/pipeline-epic-resume.test.ts [2m([22m[2m9 tests[22m[2m)[22m[33m 694[2mms[22m[39m
[90mstdout[2m | src/cli/__tests__/attach.test.ts[2m > [22m[2mforeman attach[2m > [22m[2mdefault attachment[2m > [22m[2mreturns error exit code when claude fails to launch
[22m[39mAttaching to abc-err [claude-sonnet-4-6] session=err-id
  Status: running
  Worktree: /tmp/wt


 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/version.test.ts [2m([22m[2m25 tests[22m[2m)[22m[33m 1271[2mms[22m[39m
     [33m[2m✓[22m[39m reports a non-empty version string [33m 1265[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/bin-shim.test.ts [2m([22m[2m9 tests[22m[2m)[22m[33m 647[2mms[22m[39m
     [33m[2m✓[22m[39m runs --help via node bin/foreman and outputs usage [33m 644[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/store.test.ts [2m([22m[2m46 tests[22m[2m)[22m[33m 372[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/pipeline-task-store-phase.test.ts [2m([22m[2m13 tests[22m[2m)[22m[33m 492[2mms[22m[39m
     [33m[2m✓[22m[39m WorkerConfig interface has optional taskId field [33m 382[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/attach.test.ts [2m([22m[2m25 tests[22m[2m)[22m[33m 612[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/doctor-native-mode.test.ts [2m([22m[2m1 test[22m[2m)[22m[33m 326[2mms[22m[39m
     [33m[2m✓[22m[39m native task mode downgrades missing br/bv binaries from hard failure [33m 325[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/import-sling-native-transition.test.ts [2m([22m[2m1 test[22m[2m)[22m[33m 1909[2mms[22m[39m
     [33m[2m✓[22m[39m dry-run reports native preview messaging instead of legacy tracker targeting [33m 1908[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/task-store.test.ts [2m([22m[2m71 tests[22m[2m)[22m[33m 564[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/pipeline-epic-loop.test.ts [2m([22m[2m8 tests[22m[2m)[22m[33m 409[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/task.test.ts [2m([22m[2m51 tests[22m[2m)[22m[33m 508[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/pipeline-verdict-retry.test.ts [2m([22m[2m13 tests[22m[2m)[22m[32m 299[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/stop.test.ts [2m([22m[2m25 tests[22m[2m)[22m[32m 166[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/merge-validator.test.ts [2m([22m[2m36 tests[22m[2m)[22m[32m 223[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/doctor-merge-queue.test.ts [2m([22m[2m22 tests[22m[2m)[22m[32m 155[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/retry.test.ts [2m([22m[2m29 tests[22m[2m)[22m[32m 218[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/doctor-vcs.test.ts [2m([22m[2m16 tests[22m[2m)[22m[32m 216[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/purge-logs.test.ts [2m([22m[2m17 tests[22m[2m)[22m[32m 166[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/tasks-schema.test.ts [2m([22m[2m22 tests[22m[2m)[22m[32m 99[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/phase-runner.test.ts [2m([22m[2m1 test[22m[2m)[22m[32m 194[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/attach-follow.test.ts [2m([22m[2m4 tests[22m[2m)[22m[32m 132[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/dashboard-performance.test.ts [2m([22m[2m4 tests[22m[2m)[22m[32m 94[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/sentinel.test.ts [2m([22m[2m5 tests[22m[2m)[22m[33m 2828[2mms[22m[39m
     [33m[2m✓[22m[39m sentinel status without init shows error [33m 2111[2mms[22m[39m
     [33m[2m✓[22m[39m --help includes sentinel command [33m 558[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/mail.test.ts [2m([22m[2m18 tests[22m[2m)[22m[32m 84[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/doctor-native-task-store.test.ts [2m([22m[2m3 tests[22m[2m)[22m[32m 61[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/purge-zombie-runs.test.ts [2m([22m[2m15 tests[22m[2m)[22m[32m 158[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/refinery.test.ts [2m([22m[2m44 tests[22m[2m)[22m[32m 167[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/finalize-pre-push-validation.test.ts [2m([22m[2m18 tests[22m[2m)[22m[32m 139[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/bead-writer-drain.test.ts [2m([22m[2m17 tests[22m[2m)[22m[32m 160[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/troubleshooter.test.ts [2m([22m[2m47 tests[22m[2m)[22m[32m 147[2mms[22m[39m
[90mstdout[2m | src/orchestrator/__tests__/refinery-agent.test.ts[2m > [22m[2mRefineryAgent[2m > [22m[2mprocessOnce()[2m > [22m[2mreturns empty array when no pending entries
[22m[39m[refinery-agent] Found 0 pending entries

 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/bead-write-queue.test.ts [2m([22m[2m14 tests[22m[2m)[22m[32m 80[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/notification-server.test.ts [2m([22m[2m10 tests[22m[2m)[22m[32m 30[2mms[22m[39m
[90mstdout[2m | src/orchestrator/__tests__/refinery-agent.test.ts[2m > [22m[2mRefineryAgent[2m > [22m[2mprocessOnce()[2m > [22m[2mskips entry if dequeue returns null (locked)
[22m[39m[refinery-agent] Found 1 pending entries

 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/pipeline-reviewer-retry.test.ts [2m([22m[2m7 tests[22m[2m)[22m[32m 50[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/task-backend-ops-enqueue.test.ts [2m([22m[2m12 tests[22m[2m)[22m[32m 66[2mms[22m[39m
[90mstdout[2m | src/orchestrator/__tests__/refinery-agent.test.ts[2m > [22m[2mRefineryAgent[2m > [22m[2mprocessOnce()[2m > [22m[2mupdates queue status when PR state cannot be read
[22m[39m[refinery-agent] Found 1 pending entries

 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/nfr-007-esm-imports.test.ts [2m([22m[2m1 test[22m[2m)[22m[32m 12[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/session-log.test.ts [2m([22m[2m39 tests[22m[2m)[22m[32m 46[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/refinery-agent.test.ts [2m([22m[2m11 tests[22m[2m)[22m[32m 206[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/agent-worker-finalize.test.ts [2m([22m[2m70 tests[22m[2m)[22m[32m 81[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/inbox.test.ts [2m([22m[2m29 tests[22m[2m)[22m[32m 104[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/store-metrics.test.ts [2m([22m[2m10 tests[22m[2m)[22m[32m 95[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/commands/__tests__/board-render.test.ts [2m([22m[2m34 tests[22m[2m)[22m[32m 129[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/doctor-bead-status-sync.test.ts [2m([22m[2m16 tests[22m[2m)[22m[32m 57[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/sqlite-mail-client.test.ts [2m([22m[2m10 tests[22m[2m)[22m[32m 55[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/worker-spawn.test.ts [2m([22m[2m6 tests[22m[2m)[22m[32m 30[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/task-project-resolution.test.ts [2m([22m[2m9 tests[22m[2m)[22m[32m 46[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/merge-strategy-store.test.ts [2m([22m[2m6 tests[22m[2m)[22m[32m 46[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/project-registry.test.ts [2m([22m[2m27 tests[22m[2m)[22m[32m 33[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/agent-worker.test.ts [2m([22m[2m9 tests[22m[2m)[22m[33m 3811[2mms[22m[39m
     [33m[2m✓[22m[39m exits with error when no config file argument given [33m 1125[2mms[22m[39m
     [33m[2m✓[22m[39m reads and deletes the config file on startup [33m 1497[2mms[22m[39m
     [33m[2m✓[22m[39m creates log directory and log file [33m 1187[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/task-import.test.ts [2m([22m[2m3 tests[22m[2m)[22m[32m 28[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/nfr-006-typescript.test.ts [2m([22m[2m1 test[22m[2m)[22m[33m 3847[2mms[22m[39m
     [33m[2m✓[22m[39m npx tsc --noEmit exits with code 0 [33m 3847[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/project-config.test.ts [2m([22m[2m34 tests[22m[2m)[22m[32m 17[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/dispatcher-native.test.ts [2m([22m[2m33 tests[22m[2m)[22m[32m 21[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/pipeline-smoke.test.ts [2m([22m[2m22 tests[22m[2m)[22m[32m 29[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/workflow-loader.test.ts [2m([22m[2m77 tests[22m[2m)[22m[32m 28[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/merge-events.test.ts [2m([22m[2m14 tests[22m[2m)[22m[32m 20[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/project.test.ts [2m([22m[2m8 tests[22m[2m)[22m[32m 10[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/dispatcher-tmux.test.ts [2m([22m[2m4 tests[22m[2m)[22m[32m 12[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/run-watch-loop.test.ts [2m([22m[2m10 tests[22m[2m)[22m[32m 24[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/doctor-workflows.test.ts [2m([22m[2m8 tests[22m[2m)[22m[32m 38[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/dashboard.test.ts [2m([22m[2m71 tests[22m[2m)[22m[32m 30[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/merge-queue.test.ts [2m([22m[2m42 tests[22m[2m)[22m[32m 24[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/run-auto-merge.test.ts [2m([22m[2m28 tests[22m[2m)[22m[32m 23[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/worktree.test.ts [2m([22m[2m15 tests[22m[2m)[22m[32m 10[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/dispatcher.test.ts [2m([22m[2m41 tests[22m[2m)[22m[32m 27[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/sling.test.ts [2m([22m[2m6 tests[22m[2m)[22m[32m 16[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/archive-reports.test.ts [2m([22m[2m10 tests[22m[2m)[22m[32m 20[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/reset-br-backend.test.ts [2m([22m[2m40 tests[22m[2m)[22m[32m 13[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/dispatcher-branch-label.test.ts [2m([22m[2m9 tests[22m[2m)[22m[32m 10[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/rebase-stacked-branches.test.ts [2m([22m[2m6 tests[22m[2m)[22m[32m 31[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/commands/__tests__/plan-project-resolution.test.ts [2m([22m[2m2 tests[22m[2m)[22m[33m 4550[2mms[22m[39m
     [33m[2m✓[22m[39m runs dry-run lifecycle against a registered target project from another cwd [33m 2190[2mms[22m[39m
     [33m[2m✓[22m[39m resolves --from-prd relative to the target project root [33m 2359[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/merge-queue-flow.test.ts [2m([22m[2m22 tests[22m[2m)[22m[32m 19[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/conflict-cluster.test.ts [2m([22m[2m26 tests[22m[2m)[22m[32m 18[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/live-status.test.ts [2m([22m[2m24 tests[22m[2m)[22m[32m 15[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/refinery-vcs.test.ts [2m([22m[2m15 tests[22m[2m)[22m[32m 15[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/init.test.ts [2m([22m[2m6 tests[22m[2m)[22m[32m 24[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/json-output.test.ts [2m([22m[2m25 tests[22m[2m)[22m[32m 13[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/auto-merge.test.ts [2m([22m[2m40 tests[22m[2m)[22m[32m 15[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/pipeline-phase-skip.test.ts [2m([22m[2m14 tests[22m[2m)[22m[32m 16[2mms[22m[39m
[90mstdout[2m | src/orchestrator/__tests__/sentinel.test.ts[2m > [22m[2mSentinelAgent[2m > [22m[2mduplicate bead prevention[2m > [22m[2mskips bead creation when an open bead with the same title already exists
[22m[39m[sentinel] Skipping duplicate bead creation — open bead bd-existing already exists for "[Sentinel] Test failures on main @ abc12345"

[90mstdout[2m | src/orchestrator/__tests__/sentinel.test.ts[2m > [22m[2mSentinelAgent[2m > [22m[2mduplicate bead prevention[2m > [22m[2mhandles null commit hash — skips duplicate when unknown-hash bead exists
[22m[39m[sentinel] Skipping duplicate bead creation — open bead bd-unknown already exists for "[Sentinel] Test failures on main @ unknown"

 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/sentinel.test.ts [2m([22m[2m14 tests[22m[2m)[22m[32m 11[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/watch-ui.test.ts [2m([22m[2m95 tests[22m[2m)[22m[32m 10[2mms[22m[39m
[90mstdout[2m | src/lib/__tests__/beads-rust-deprecation.test.ts[2m > [22m[2mTRD-014 / REQ-015: BeadsRustClient Deprecation Compliance[2m > [22m[2mknown violations inventory (informational — does not fail)
[22m[39m
[TRD-014] All BeadsRustClient violations have been migrated. BeadsRustClient is now only used in lib/beads-rust.ts and orchestrator/dispatcher.ts.


 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/beads-rust-deprecation.test.ts [2m([22m[2m3 tests[22m[2m)[22m[32m 11[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/auto-merge-mail.test.ts [2m([22m[2m17 tests[22m[2m)[22m[32m 8[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/conflict-patterns.test.ts [2m([22m[2m20 tests[22m[2m)[22m[32m 9[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/roles.test.ts [2m([22m[2m90 tests[22m[2m)[22m[32m 12[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/dispatcher-stuck-backoff.test.ts [2m([22m[2m12 tests[22m[2m)[22m[32m 23[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/heartbeat-manager.test.ts [2m([22m[2m19 tests[22m[2m)[22m[32m 10[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/refinery-git-town.test.ts [2m([22m[2m7 tests[22m[2m)[22m[32m 10[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/doctor-worktrees.test.ts [2m([22m[2m20 tests[22m[2m)[22m[32m 10[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/task-backend-ops.test.ts [2m([22m[2m48 tests[22m[2m)[22m[32m 11[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/agent-worker-enqueue.test.ts [2m([22m[2m6 tests[22m[2m)[22m[32m 7[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/merge-costs.test.ts [2m([22m[2m12 tests[22m[2m)[22m[32m 11[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/refinery-branch-label.test.ts [2m([22m[2m6 tests[22m[2m)[22m[32m 14[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/sprint-parallel.test.ts [2m([22m[2m16 tests[22m[2m)[22m[32m 10[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/ci-workflow-validation.test.ts [2m([22m[2m21 tests[22m[2m)[22m[33m 5217[2mms[22m[39m
     [33m[2m✓[22m[39m tsc --noEmit exits 0 on clean codebase [33m 3851[2mms[22m[39m
     [33m[2m✓[22m[39m tsc --noEmit exits non-zero when a type error is introduced [33m 559[2mms[22m[39m
     [33m[2m✓[22m[39m act can list the CI workflow job without errors [33m 558[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/dispatcher-epic.test.ts [2m([22m[2m6 tests[22m[2m)[22m[32m 9[2mms[22m[39m
[90mstdout[2m | src/orchestrator/__tests__/stale-worktree-check.test.ts[2m > [22m[2mcheckAndRebaseStaleWorktree[2m > [22m[2mshould auto-rebase when worktree is stale
[22m[39m[StaleWorktreeCheck] Worktree for seed-abc is stale — auto-rebasing onto origin/dev

[90mstdout[2m | src/orchestrator/__tests__/stale-worktree-check.test.ts[2m > [22m[2mcheckAndRebaseStaleWorktree[2m > [22m[2mshould log worktree-rebased event on successful rebase
[22m[39m[StaleWorktreeCheck] Worktree for seed-abc is stale — auto-rebasing onto origin/dev

[90mstdout[2m | src/orchestrator/__tests__/stale-worktree-check.test.ts[2m > [22m[2mcheckAndRebaseStaleWorktree[2m > [22m[2mshould return rebased=false when rebase fails with conflicts
[22m[39m[StaleWorktreeCheck] Worktree for seed-abc is stale — auto-rebasing onto origin/dev

[90mstdout[2m | src/orchestrator/__tests__/stale-worktree-check.test.ts[2m > [22m[2mcheckAndRebaseStaleWorktree[2m > [22m[2mshould log worktree-rebase-failed event on conflict
[22m[39m[StaleWorktreeCheck] Worktree for seed-abc is stale — auto-rebasing onto origin/dev

[90mstdout[2m | src/orchestrator/__tests__/stale-worktree-check.test.ts[2m > [22m[2mcheckAndRebaseStaleWorktree[2m > [22m[2mshould throw when failOnConflict=true and rebase conflicts
[22m[39m[StaleWorktreeCheck] Worktree for seed-abc is stale — auto-rebasing onto origin/dev

[90mstdout[2m | src/orchestrator/__tests__/stale-worktree-check.test.ts[2m > [22m[2mcheckAndRebaseStaleWorktree[2m > [22m[2mshould not throw when failOnConflict=false and rebase conflicts
[22m[39m[StaleWorktreeCheck] Worktree for seed-abc is stale — auto-rebasing onto origin/dev

 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/stale-worktree-check.test.ts [2m([22m[2m18 tests[22m[2m)[22m[32m 7[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/monitor-beads-rust.test.ts [2m([22m[2m10 tests[22m[2m)[22m[32m 7[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/trd-parser.test.ts [2m([22m[2m38 tests[22m[2m)[22m[32m 10[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/startup-sync.test.ts [2m([22m[2m22 tests[22m[2m)[22m[32m 7[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/dispatcher-vcs.test.ts [2m([22m[2m10 tests[22m[2m)[22m[32m 13[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/reset-mismatch.test.ts [2m([22m[2m26 tests[22m[2m)[22m[32m 7[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/run-auto-dispatch.test.ts [2m([22m[2m6 tests[22m[2m)[22m[32m 11[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/run-sentinel-autostart.test.ts [2m([22m[2m9 tests[22m[2m)[22m[32m 11[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/resolve-workflow-name.test.ts [2m([22m[2m17 tests[22m[2m)[22m[32m 4[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/beads-rust.test.ts [2m([22m[2m42 tests[22m[2m)[22m[32m 7[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/bv.test.ts [2m([22m[2m19 tests[22m[2m)[22m[32m 8[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/merge-config.test.ts [2m([22m[2m6 tests[22m[2m)[22m[32m 10[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/guardrails.test.ts [2m([22m[2m22 tests[22m[2m)[22m[32m 8[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/prompt-loader.test.ts [2m([22m[2m4 tests[22m[2m)[22m[32m 6[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/bead-br-backend.test.ts [2m([22m[2m8 tests[22m[2m)[22m[32m 3[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/testing-framework-contract.test.ts [2m([22m[2m7 tests[22m[2m)[22m[32m 5[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/sling-executor.test.ts [2m([22m[2m17 tests[22m[2m)[22m[32m 7[2mms[22m[39m
[90mstdout[2m | src/orchestrator/__tests__/run-branch-mismatch.test.ts[2m > [22m[2mcheckBranchMismatch[2m > [22m[2mprompts when branch: label differs from current branch
[22m[39mSwitched to branch installer.

[90mstdout[2m | src/orchestrator/__tests__/run-branch-mismatch.test.ts[2m > [22m[2mcheckBranchMismatch[2m > [22m[2mchecks out the target branch when user says yes
[22m[39mSwitched to branch installer.

[90mstdout[2m | src/orchestrator/__tests__/run-branch-mismatch.test.ts[2m > [22m[2mcheckBranchMismatch[2m > [22m[2mchecks out the target branch when user presses enter (default yes)
[22m[39mSwitched to branch installer.

[90mstdout[2m | src/orchestrator/__tests__/run-branch-mismatch.test.ts[2m > [22m[2mcheckBranchMismatch[2m > [22m[2mreturns true (abort) when user says no
[22m[39mSkipping beads seed-001 — they target installer. Run 'git checkout installer' and re-run foreman to continue those beads.

[90mstdout[2m | src/orchestrator/__tests__/run-branch-mismatch.test.ts[2m > [22m[2mcheckBranchMismatch[2m > [22m[2mgroups multiple beads by target branch
[22m[39mSwitched to branch installer.

 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/run-branch-mismatch.test.ts [2m([22m[2m11 tests[22m[2m)[22m[32m 6[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/run-pi-extensions-check.test.ts [2m([22m[2m4 tests[22m[2m)[22m[32m 6[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/task-meta-propagation.test.ts [2m([22m[2m5 tests[22m[2m)[22m[32m 2[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/beads-preservation.test.ts [2m([22m[2m5 tests[22m[2m)[22m[32m 3[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/monitor.test.ts [2m([22m[2m6 tests[22m[2m)[22m[32m 5[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/refinery-jj-rebase.test.ts [2m([22m[2m1 test[22m[2m)[22m[32m 5[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/commands/__tests__/board-navigation.test.ts [2m([22m[2m24 tests[22m[2m)[22m[32m 4[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/pipeline-model-resolution.test.ts [2m([22m[2m20 tests[22m[2m)[22m[32m 5[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/status-display.test.ts [2m([22m[2m26 tests[22m[2m)[22m[32m 7[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/commands/__tests__/board-mutations.test.ts [2m([22m[2m30 tests[22m[2m)[22m[32m 6[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/status-dashboard-native-first.test.ts [2m([22m[2m3 tests[22m[2m)[22m[32m 3[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/init-br-backend.test.ts [2m([22m[2m6 tests[22m[2m)[22m[32m 4[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/template-loader.test.ts [2m([22m[2m26 tests[22m[2m)[22m[32m 4[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/interpolate.test.ts [2m([22m[2m19 tests[22m[2m)[22m[32m 4[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/finalize-prompt-vcs.test.ts [2m([22m[2m30 tests[22m[2m)[22m[32m 6[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/commands/__tests__/board-perf.test.ts [2m([22m[2m6 tests[22m[2m)[22m[32m 3[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/run-backend.test.ts [2m([22m[2m6 tests[22m[2m)[22m[32m 4[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/agent-worker-team.test.ts [2m([22m[2m13 tests[22m[2m)[22m[32m 3[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/notification-bus.test.ts [2m([22m[2m7 tests[22m[2m)[22m[32m 5[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/run-owned-branch.test.ts [2m([22m[2m4 tests[22m[2m)[22m[32m 6[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/refinery-conflict-scan.test.ts [2m([22m[2m9 tests[22m[2m)[22m[32m 6[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/branch-label.test.ts [2m([22m[2m29 tests[22m[2m)[22m[32m 4[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/refinery-state-files.test.ts [2m([22m[2m6 tests[22m[2m)[22m[32m 7[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/pi-rpc-spawn-strategy.test.ts [2m([22m[2m20 tests[22m[2m)[22m[32m 7[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/merge-br-backend.test.ts [2m([22m[2m3 tests[22m[2m)[22m[32m 4[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/config.test.ts [2m([22m[2m31 tests[22m[2m)[22m[32m 4[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/run-status.test.ts [2m([22m[2m12 tests[22m[2m)[22m[32m 3[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/status-br-backend.test.ts [2m([22m[2m9 tests[22m[2m)[22m[32m 4[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/task-ordering.test.ts [2m([22m[2m7 tests[22m[2m)[22m[32m 3[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/bash-phase.test.ts [2m([22m[2m12 tests[22m[2m)[22m[32m 7[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/reset-detect-stuck.test.ts [2m([22m[2m7 tests[22m[2m)[22m[32m 6[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/resolve-base-branch.test.ts [2m([22m[2m9 tests[22m[2m)[22m[32m 4[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/lead-prompt.test.ts [2m([22m[2m14 tests[22m[2m)[22m[32m 3[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/pi-sdk-tools.test.ts [2m([22m[2m9 tests[22m[2m)[22m[32m 3[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/bundle-script.test.ts [2m([22m[2m8 tests[22m[2m)[22m[32m 3[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/agent-worker-finalize-vcs.test.ts [2m([22m[2m37 tests[22m[2m)[22m[32m 3[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/project-targeting.test.ts [2m([22m[2m9 tests[22m[2m)[22m[32m 4[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/workflow-loader-vcs.test.ts [2m([22m[2m15 tests[22m[2m)[22m[32m 3[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/beads-client.test.ts [2m([22m[2m6 tests[22m[2m)[22m[32m 7[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/nfr-004-backwards-compat.test.ts [2m([22m[2m8 tests[22m[2m)[22m[32m 2[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/workflow-type-validation.test.ts [2m([22m[2m15 tests[22m[2m)[22m[32m 3[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/agent-worker-sessionlog.test.ts [2m([22m[2m24 tests[22m[2m)[22m[32m 3[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/templates.test.ts [2m([22m[2m11 tests[22m[2m)[22m[32m 3[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/beads.test.ts [2m([22m[2m9 tests[22m[2m)[22m[32m 3[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/build-atomic.test.ts [2m([22m[2m8 tests[22m[2m)[22m[32m 5[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/agent-worker-auto-merge.test.ts [2m([22m[2m21 tests[22m[2m)[22m[32m 9[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/agent-worker-nothing-to-commit.test.ts [2m([22m[2m19 tests[22m[2m)[22m[32m 3[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/priority.test.ts [2m([22m[2m29 tests[22m[2m)[22m[32m 3[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/reviewer-prompt-vcs.test.ts [2m([22m[2m12 tests[22m[2m)[22m[32m 6[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/nfr-001-binary-check.test.ts [2m([22m[2m3 tests[22m[2m)[22m[32m 3[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/merge-strategy-routing.test.ts [2m([22m[2m11 tests[22m[2m)[22m[32m 4[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/sling-sd-only-deprecation.test.ts [2m([22m[2m8 tests[22m[2m)[22m[32m 4[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/plan-br-backend.test.ts [2m([22m[2m5 tests[22m[2m)[22m[32m 6[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/nfr-003-bv-timeout.test.ts [2m([22m[2m4 tests[22m[2m)[22m[32m 6[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/run-runtime-mode.test.ts [2m([22m[2m3 tests[22m[2m)[22m[32m 3[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/feature-flags.test.ts [2m([22m[2m6 tests[22m[2m)[22m[32m 5[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/merge-dry-run.test.ts [2m([22m[2m7 tests[22m[2m)[22m[32m 4[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/sentinel-backend.test.ts [2m([22m[2m1 test[22m[2m)[22m[32m 2[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/lib/__tests__/nfr-005-coverage.test.ts [2m([22m[2m9 tests[22m[2m)[22m[32m 4[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/agent-worker-finalize-mail-status.test.ts [2m([22m[2m8 tests[22m[2m)[22m[32m 3[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/sling-br-default.test.ts [2m([22m[2m6 tests[22m[2m)[22m[32m 2[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/prompt-guards.test.ts [2m([22m[2m8 tests[22m[2m)[22m[32m 2[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/claude-md-sessionlog.test.ts [2m([22m[2m8 tests[22m[2m)[22m[32m 2[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/command-phase.test.ts [2m([22m[2m7 tests[22m[2m)[22m[32m 2[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/dispatcher-prompts.test.ts [2m([22m[2m15 tests[22m[2m)[22m[32m 2[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/orchestrator/__tests__/nfr-002-worker-path.test.ts [2m([22m[2m5 tests[22m[2m)[22m[32m 3[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/bead.test.ts [2m([22m[2m30 tests[22m[2m)[22m[33m 8506[2mms[22m[39m
     [33m[2m✓[22m[39m bead fails without foreman init (no .beads directory) [33m 2204[2mms[22m[39m
     [33m[2m✓[22m[39m bead --dry-run --no-llm shows planned beads without creating them [33m 2246[2mms[22m[39m
     [33m[2m✓[22m[39m bead --dry-run --no-llm reads description from a file [33m 2142[2mms[22m[39m
     [33m[2m✓[22m[39m sets description to slice(200) when input exceeds 200 chars [33m 897[2mms[22m[39m
     [33m[2m✓[22m[39m sets description to undefined when input is exactly 200 chars [33m 933[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/commands/__tests__/sling-project-resolution.test.ts [2m([22m[2m5 tests[22m[2m)[22m[33m 8554[2mms[22m[39m
     [33m[2m✓[22m[39m resolves a registered project and reads the TRD from that project [33m 2111[2mms[22m[39m
     [33m[2m✓[22m[39m reads the TRD from an explicit --project-path target [33m 2364[2mms[22m[39m
     [33m[2m✓[22m[39m rejects relative --project-path values [33m 2145[2mms[22m[39m
     [33m[2m✓[22m[39m warns but still accepts legacy absolute paths under --project [33m 969[2mms[22m[39m
     [33m[2m✓[22m[39m rejects combining --project with --project-path [33m 963[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/__tests__/doctor.test.ts [2m([22m[2m13 tests[22m[2m)[22m[33m 9267[2mms[22m[39m
     [33m[2m✓[22m[39m doctor --help shows description and options [33m 1817[2mms[22m[39m
     [33m[2m✓[22m[39m doctor shows in top-level --help [33m 774[2mms[22m[39m
     [33m[2m✓[22m[39m doctor inside git repo without project init warns [33m 2530[2mms[22m[39m
     [33m[2m✓[22m[39m doctor --json outputs valid JSON [33m 2048[2mms[22m[39m
     [33m[2m✓[22m[39m doctor with registered project shows pass for project check [33m 1215[2mms[22m[39m
     [33m[2m✓[22m[39m doctor --fix runs without crashing [33m 865[2mms[22m[39m
 [32m✓[39m [30m[42m unit [49m[39m src/cli/commands/__tests__/task-project-resolution.test.ts [2m([22m[2m7 tests[22m[2m)[22m[33m 9442[2mms[22m[39m
     [33m[2m✓[22m[39m task list --project <registered-name> resolves to correct path [33m 2118[2mms[22m[39m
     [33m[2m✓[22m[39m task list --project <unknown-name> exits with error [33m 2244[2mms[22m[39m
     [33m[2m✓[22m[39m task list --project <absolute-path> warns and proceeds during the compatibility window [33m 2404[2mms[22m[39m
     [33m[2m✓[22m[39m task list (no --project) uses current directory [33m 923[2mms[22m[39m
     [33m[2m✓[22m[39m task list --project '' (empty string) falls back to current directory [33m 897[2mms[22m[39m
     [33m[2m✓[22m[39m task list --project <relative-path> exits with error (not a registered name) [33m 795[2mms[22m[39m

[2m Test Files [22m [1m[32m185 passed[39m[22m[90m (185)[39m
[2m      Tests [22m [1m[32m3218 passed[39m[22m[90m (3218)[39m
[2m   Start at [22m 08:44:32
[2m   Duration [22m 9.74s[2m (transform 4.37s, setup 0ms, import 22.09s, tests 71.34s, environment 10ms)[22m

