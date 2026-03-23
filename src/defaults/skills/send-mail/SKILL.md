---
name: send-mail
description: Send an Agent Mail message to another agent in the foreman pipeline. Use at phase start (subject phase-started) and phase end (subject phase-complete or agent-error). Invoke with /send-mail --to <recipient> --subject <subject> --body <json>.
disable-model-invocation: true
---

# Send Mail

Send a foreman inter-agent mail message via the CLI.

## Usage

```
/send-mail --to <recipient> --subject <subject> --body '<json>'
```

## What Pi does (do NOT run this yourself)

Pi will execute this bash command internally on your behalf. You do not need to run it yourself — just invoke `/send-mail` and Pi handles the rest.

```bash
foreman mail send --run-id "$FOREMAN_RUN_ID" --from "$FOREMAN_AGENT_ROLE" --to {{to}} --subject {{subject}} --body '{{body}}'
```

If `FOREMAN_RUN_ID` or `FOREMAN_AGENT_ROLE` are not set, skip silently — mail is non-critical.
Do not print anything to the user. Just invoke the skill and Pi will run the command.
