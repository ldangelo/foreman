# Real `br` output fixtures

Every file here is **verbatim stdout of a real `br` 0.6.0** (`br --version` → `br 0.6.0`),
captured by `scripts/refresh_br_fixtures.sh` from a throwaway `git init` + `br init`
repository. Never hand-edit them. Tests read them through
`ForemanServer.TestSupport.BrFixtures`; any test that stubs `BrRunner` stdout for a
command listed below must return the fixture, not invented JSON.

Argv mirrors what `TaskProviders.SystemBrRunner` builds (`--db <path>` omitted below).

| File | Command |
|---|---|
| `create_plain.json` | `br create --title … --type task --priority 2 --description … --agent-context … --json` |
| `create_labels.json` | same, plus `--labels foreman-exec,foreman-gap` |
| `show_plain.json` | `br show <id> --json` (issue with no labels/relations; note the one-element array and the omitted `dependencies`/`dependents`/`labels`) |
| `show_labels_with_dependency.json` | `br show <id> --json` (labels + one dependency; no `dependents` key) |
| `show_with_dependent.json` | `br show <id> --json` (one dependent; no `dependencies` key) |
| `show_with_comments.json` | `br show <id> --json` (two comments) |
| `comments_add.json` | `br comments add <id> --message … --json` |
| `dep_add.json` | `br dep add <dependent> <dependency> --json` |
| `list_labels.json` | `br list --label foreman-exec --json` (`br list` has `--label`, not `--labels`) |
| `ready.json` | `br ready --json` (what `BeadsAdapter.list_ready/2` parses) |
| `update_claim.json` | `br update <id> --claim --json` |
| `update_blocked.json` | `br update <id> --status blocked --transition-comment … --json` (`fail/3`) |
| `update_reopen.json` | `br update <id> --status open --transition-comment … --json` (`reopen/3`) |
| `close.json` | `br close <id> --reason … --json` (`complete/3`) |
| `schema_{ready_issue,issue_details,error,commands}.json` | `br schema <ready-issue\|issue-details\|error\|commands> --json` (loaded by `JsonSchemaCache`) |

Fixtures contain generated ids, timestamps, the capturing user name and a local path.
Tests must therefore derive expected ids from the fixture (`BrFixtures.issue!/1`), never
hard-code them.

## Regenerate

```
scripts/refresh_br_fixtures.sh [scratch_dir]   # requires br + jq on PATH
```

The scratch dir defaults to `../brfix-scratch/fixtures-run` next to the checkout, never `/tmp`
and never this repository's own `.beads`. After regenerating, run
`mix test test/foreman_server/task_providers test/foreman_server/review`; a failure means the
adapter no longer matches what `br` emits. Update the `br` version in this README when it changes.

## Not captured

`br sync`, `br where`, `br coordination status` and `br --version`/`capabilities` outputs are not
fixtures; tests for those still use hand-written stubs.
