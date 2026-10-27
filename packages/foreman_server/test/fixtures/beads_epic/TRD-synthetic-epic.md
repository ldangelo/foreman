# TRD: Synthetic epic (fixture)

Fixture TRD for the Foreman beads-build end-to-end test
(`test/integration/beads_epic_tree_e2e_test.exs`). It is deliberately tiny: its
Beads tree is one epic with two tasks, task B depending on task A. Nothing here
describes a real feature.

## Master Task List

- [ ] TASK-A: first synthetic task
- [ ] TASK-B: second synthetic task [Depends: TASK-A]
