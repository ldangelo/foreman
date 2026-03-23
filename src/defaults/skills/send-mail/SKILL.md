---
name: send-mail
description: Send an Agent Mail message to another agent in the foreman pipeline. Use at phase start (subject phase-started) and phase end (subject phase-complete or agent-error). Invoke with /send-mail --run-id <id> --from <agent> --to <recipient> --subject <subject> --body <json>.
disable-model-invocation: true
model: claude-haiku-4-5-20251001
---

# Send Mail

Send a foreman inter-agent mail message via the CLI.

## Usage

```
/send-mail --run-id "<id>" --from "<sender>" --to "<recipient>" --subject "<subject>" --body '<json>'
```

## What to do

Run this bash command, replacing each argument with the value provided:

```bash
npx foreman mail send --run-id "{{run-id}}" --from "{{from}}" --to "{{to}}" --subject "{{subject}}" --body '{{body}}'
```

If the command fails or run-id is empty, skip silently — mail is non-critical.
Do not print anything to the user. Just run the command.
