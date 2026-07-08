---
name: mulch
description: Use when working in this repo to load and maintain project expertise with the `mulch` CLI: session priming, recording learnings, searching conventions, and validating `.mulch/` records.
---

# Mulch Project Memory

Mulch stores durable project expertise in `.mulch/` so agents can reuse learned conventions, failures, decisions, patterns, guides, and references across sessions.

## Session Start

Run project priming before substantial repo work:

```bash
mulch prime
```

For work focused on specific domains or files, prefer narrower context:

```bash
mulch prime orchestrator cli
mulch prime --files src/orchestrator/pipeline-executor.ts
```

## Search Existing Knowledge

Use focused searches when investigating conventions or known failures:

```bash
mulch search "workflow yaml"
mulch query orchestrator
mulch query --all
mulch status
```

## Record New Learnings

Before finishing meaningful work, decide whether anything should be preserved. Good candidates include repeated failures, non-obvious conventions, architecture decisions, reusable patterns, and troubleshooting guides.

```bash
mulch learn
mulch record <domain> --type <failure|convention|pattern|decision|reference|guide> --description "..."
```

Prefer existing Foreman domains when applicable, such as `orchestrator`, `cli`, `dispatcher`, `planning`, `pipeline-executor`, and `epic-execution`.

## Validation

After changing `.mulch/`, verify the store:

```bash
mulch validate
mulch doctor
```

Use `mulch sync` only when explicitly preparing a commit that should include `.mulch/` changes.
