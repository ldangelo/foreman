# E4-SP2: docker sandbox network allowlist mechanism

Date: 2026-10-21. Result: **(a) `--network none` GO; (b) internal network + egress-proxy sidecar GO
(tinyproxy, domain allowlist, CONNECT-based); (c) per-container iptables NO-GO.**

## Evidence (docker 29.9.1, macOS Docker Desktop)
Setup: `docker network create --internal NET`; sidecar built locally from
`FROM alpine:3.20 / apk add tinyproxy`, config `Filter allow-file`, `FilterDefaultDeny Yes`, `ConnectPort 443`,
started on NET then also `docker network connect bridge <sidecar>` (egress leg). Agent container on NET only with
`HTTPS_PROXY=http://<sidecar>:3128`.
- allowed host (`^example\.com$`): `curl https://example.com` -> HTTP 200.
- denied host (`example.org`): `curl: (56) CONNECT tunnel failed, response 403`.
- no proxy env: `Could not resolve host` (internal network has no DNS egress).
- raw TCP to an IP, proxy bypassed (`--noproxy '*' https://1.1.1.1`): `Failed to connect` (network internal).
Non-proxy-aware tools therefore bypass nothing; they simply have no route. Plain HTTP also goes through the proxy
(`HTTP_PROXY`), HTTPS only to port 443.
- (c) iptables needs a privileged helper per container: rejected.

## Mechanism & contract
- `mode none`: `--network none`. Agent cannot reach its provider API -> only for offline/CLI-local tasks.
- `mode allowlist`: per jobsite: create `foreman-net-<id>` (`--internal`), run sidecar
  `foreman-egress-proxy:<tag>` (built locally by `docker build` from an embedded Dockerfile/tinyproxy conf into
  a temp dir on first use; no pull from a registry) attached to the internal net and to `bridge`; sandbox runs on
  the internal net with `HTTP_PROXY/HTTPS_PROXY/http_proxy/https_proxy=http://<sidecar>:3128`,
  `NO_PROXY=localhost,127.0.0.1`. Filter regexes are generated from escaped host names (`^host$`), after
  validation `^[a-z0-9.*-]+$`.
- Always-allowed provider hosts: `api.anthropic.com`, `api.openai.com`, `api.minimax.io`,
  `generativelanguage.googleapis.com`, `openrouter.ai`, `github.com`, `api.github.com`, `registry.npmjs.org`.
- Cleanup: sandbox destroy removes the sidecar (`docker rm -f`) then the network (`docker network rm`); a failure
  to clean is logged, never raised. Cost observed: ~1 s extra at create (image already built).
- Failure modes: docker missing / build failure / network create failure -> `{:error, :network_allowlist_failed}`
  at sandbox create (fail closed: never run un-restricted when a policy was requested).
- Caveat: allowlisting is by hostname through CONNECT; an allowed host that proxies arbitrary content defeats it.
