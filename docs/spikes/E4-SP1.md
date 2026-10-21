# E4-SP1: secret store backend (file vs OS keychain)

Date: 2026-10-21. Result: **file backend GO (default); macOS keychain NO-GO; Linux secret-tool NO-GO (not shipped).**

## Question
Which backend(s) should `ForemanServer.SecretStore` ship with, given secret values must never reach event
payloads, logs, `ps` output or the repo.

## Evidence
- macOS `security add-generic-password -a A -s S -w VALUE`: the only way to store a value non-interactively is
  `-w VALUE`, i.e. the value is in argv, visible to every local user via `ps` for the call's lifetime
  (`security add-generic-password -h` itself says "Use of the -p or -w options is insecure"). Observed: the value
  is accepted as an argv element and read back by `find-generic-password -w`.
- The "prompt" route (`-w` as the LAST option with no value) reads from the tty. Piping the value
  (`echo v | security add-generic-password -a t -s s -U -w <keychain>`) stored **nothing** (subsequent
  `find-generic-password` returned "item could not be found"). So there is no stdin route: NO-GO. A tty-less
  server process cannot use it without leaking via argv.
- Linux `secret-tool` / libsecret: not installed on a headless host (`which secret-tool` empty); needs a D-Bus
  session and unlocked keyring, absent on servers. NO-GO as a shipped backend.
- File backend: no argv exposure, atomic temp-file + rename, dir 0700, file 0600, outside any repo.

## Decision / contract
Default and only shipped backend: file, under `config :foreman_server, :secret_store, dir:` (default
`~/.foreman/secrets`), one `<project_id>.json` per project (`{name => value}`), file mode 0600, dir 0700.
Writes are atomic (write `*.tmp` mode 0600 then `File.rename/2`). Backend is a module config
(`:backend`) so a keychain/Vault backend can be added later without touching callers.

`ForemanServer.SecretStore` behaviour (all return `{:ok, _} | {:error, %SecretStore.Error{code, message}}`):
`put(project_id, name, value)`, `get(project_id, name)`, `delete(project_id, name)`, `names(project_id)`.
Error codes: `:invalid_secret_name`, `:invalid_secret_value`, `:secret_not_found` (get/delete), `:store_unavailable`
(dir not writable/readable), `:store_malformed`.
Unavailable at launch: **fail open for the run** (resolve returns the project's vars without secrets and logs a
warning with the project id and error code only) because refusing every run on a broken file is worse than a
missing optional credential; writes fail closed (`put` returns the error, nothing is dispatched).
Rotation: `put` with the same name overwrites and bumps the event version; old values are not retained.
