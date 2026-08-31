# beads.db corruption under ordinary `br` writes — evidence log

Tracking bead: `foreman-wp9m` (P1). This file exists because the findings do not
fit in a bead description: **writing a large description is itself one of the
triggers**, so recording the detail in the bead would corrupt the database the
bead is about.

`br 0.5.3`, macOS/APFS, `.beads/beads.db` (SQLite + the `fsqlite` layer).

## What is established

A byte-clean `beads.db` (`pragma integrity_check` = `ok`, freshly built by
`br sync --import-only --rebuild`) corrupts under ordinary `br` write traffic.
Observed **six times on 2026-08-31**, four of them on databases that had just
been verified clean.

Damage is always structural and always at the write frontier:

|#|Trigger|Damage reported by `integrity_check`|
|---|---|---|
|1|`br close` traffic|pages 3383-3385 "referenced multiple times"; wrong entry counts in 3 `idx_events_*` indexes|
|2|~10 `br close` writes on a `.recover`'d DB|`failed to parse B-tree page 876 at header offset`|
|3|`br update -d` (6.4 KB description)|`Tree 3 page 3 cell 0: 2nd reference to page 2261`; wrong counts in 3 `idx_issues_*` indexes|
|4|`br sync --import-only`|`freelist leaf count too big` on pages 4528-4529; ~100 pages "never used"|
|5|`br update -d` (6.4 KB description)|`Tree 2 page 3646 cell 0: 2nd reference to page 15`|
|6|`br update -d` (800-6411 B), sandbox|`*** in database main ***`, 4 of 5 sizes|
|7|`br update -d` (**677 B** description)|`Tree 4121 page 4121 cell 6: 2nd reference to page 15`|

Every `br` command **exited 0**. Corruption is only visible to
`pragma integrity_check`, and `br` keeps working afterwards because aggregate
and index-only queries (`count(*)`, `select id`) still answer while full scans
raise `database disk image is malformed`. That is why `br list` and `br doctor`
disagreed, and why the DB emitted the impossible
`could hydrate only 756 of 752 database issues`.

## What is NOT established

**There is no size threshold and no deterministic repro.** A size bisect on a
fresh clean DB per trial:

```
500 B    ok        1024 B   ok         2000 B   ok (4/4 trials)
800 B    CORRUPT   1100 B   CORRUPT    3000 B   CORRUPT
1500 B   CORRUPT                       4500 B   CORRUPT   6411 B   CORRUPT
```

800 corrupts while 1024 and 2000 do not, so this is page/freelist **layout**
dependent. Occurrence #7 then settled it: a **677-byte** description write —
smaller than the 800 B that corrupted and smaller than two sizes that did
not — corrupted a database verified `ok` seconds earlier. Size is not the
variable. Do not report this as "descriptions over N bytes".

The sharper statement the evidence supports: **an `UPDATE` to a row whose
content spills to overflow pages can double-reference a page**, and three of
the four b-tree failures name a `2nd reference to page N` (twice page 15).
The write that triggers it need not be large; it needs to relocate row
content. `br sync --import-only` (occurrence #4) is not a description write at
all, so the defect is not specific to `br update -d` either.

`compaction_level` and `original_size` were `0` in every corrupting case, so
`br`'s description-compaction path is **not** the trigger.

Three hypotheses were tested and **retracted**; they are recorded so nobody
re-derives them as fact:

1. **The 88 `.br_recovery` artifacts are the tracked `-fsqlite-ns-gate` file
   repeatedly failing to rebuild.** No. They are whole-family snapshots
   (`beads.db` plus all six sidecars, ~12 events across 2026-08-08 and the
   2026-08-31 recovery); the gate file is one member of each set. Untracking it
   (PR #430) is hygiene and carries no evidence about corruption.
2. **A concurrent `bv`/`br` writer violates SQLite's single-writer rule.** A
   bare `bv` TUI *was* running for 3 days 19 hours (PID 3138) — but `lsof` put
   its cwd and open handles in a **different repository**
   (`Sunstone/stova/aventri-core/.beads`), and `lsof .beads/beads.db` in this
   repo returned no holder at the moment of corruption #3.
3. **`.beads/.gitignore` is missing the fsqlite sidecar patterns**, as
   `foreman-wp9m` originally claimed. It is not: `*-fsqlite-ns-gate`,
   `*-fsqlite-ns-use`, `*.vacuum-wal-cert*` and `*.fsqlite-migration-state` are
   all present. The real defect was that `.beads/beads.db-fsqlite-ns-gate` was
   **committed** (in #418, predating those patterns) and so sat in the index,
   where gitignore does not apply.

## Recovery that works

`sqlite3 .recover` saves all but the write-frontier rows — in occurrence #5 it
saved **753 of 754**, and the single casualty was the exact row being written.
The reliable path is `br`'s own rebuild, which produced a clean native DB where
installing a `.recover` artifact did not (occurrence #4 corrupted immediately
after importing into a `.recover`'d file):

```bash
cp -R .beads /tmp/beads-backup-$(date +%s)      # ALWAYS first
# confirm the JSONL is a superset before trusting it — see below
rm -f .beads/beads.db .beads/beads.db-shm .beads/beads.db-wal \
      .beads/beads.db-wal-cert .beads/beads.db-wal-cert-head
br sync --import-only --rebuild
sqlite3 .beads/beads.db "pragma integrity_check;"   # expect: ok
br sync --status --json | jq -e '.coverage_drift == false'
```

**That rebuild reads `issues.jsonl` and is destructive if the JSONL is
incomplete** — which it silently was here (174 of 752 issues across 8 commits;
see the Session Protocol section of `AGENTS.md` and
`skill://beads-corrupt-db-recovery-safe`). Verify the JSONL is a strict
superset first:

```bash
python3 - <<'EOF'
import json,sqlite3
ids={json.loads(l)["id"] for l in open(".beads/issues.jsonl") if l.strip()}
db={r[0] for r in sqlite3.connect("file:.beads/beads.db?mode=ro",uri=True).execute("select id from issues")}
print("jsonl",len(ids),"db",len(db),"db-only",sorted(db-ids))   # db-only MUST be []
EOF
```

`br doctor --repair/--fix` also "rebuilds DB from JSONL" per its own help, so it
is destructive under the same condition — and it is the most dangerous of the
three paths because it reads as routine maintenance.

## Assessment

This is very likely an upstream `br` 0.5.3 / `fsqlite` write-path defect, not
workspace drift: clean databases corrupt under single, ordinary, exit-0 writes,
with no concurrent writer present. It is not fixable in this repository. What
this repository can do — and PR #430 does — is ensure the JSONL export is
always complete, so that recovery is never destructive.

Preserved evidence (local, not committed): `/tmp/beads-corrupt-3-*` and
`/tmp/beads-corrupt-4-*` hold the corrupt `.beads/` trees for occurrences 3
and 4.

## Next step when it recurs

Capture `.beads/` intact **before** any repair, then check for a second writer
(`lsof .beads/beads.db`, and `ps` for `br`/`bv` — verifying cwd, since a `bv`
in another repo is irrelevant). Foreman's `BeadsDbLease` governs only
Foreman-dispatched runs, never an operator shell, so it cannot be assumed to
have serialized anything.
