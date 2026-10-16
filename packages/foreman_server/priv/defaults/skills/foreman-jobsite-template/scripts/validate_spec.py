#!/usr/bin/env python3
"""Validate a remote Jobsite spec against Jobsite.Spec.from_json's whitelist.

Mirror of packages/foreman_server/lib/foreman_server/jobsite/spec.ex. When this
script and that module disagree, that module wins -- re-read from_json/2 and the
check_* helpers rather than trusting this file.

Usage:
    validate_spec.py SPEC.json [--project-id ID] [--env-key K ...]

Exits 0 when the spec would be accepted, 1 with the server's error code and the
offending key on stderr. --project-id only affects the optional local warning
about a project id not in `foreman project list` (it never calls the server).
"""

import argparse
import json
import re
import sys

ALLOWED = {
    "project_id", "prompt", "agent", "strategy", "sandbox", "name",
    "max_iterations", "completion_signal", "idle_timeout_seconds",
    "completion_timeout_seconds", "hooks", "exclude_paths",
    "copy_to_worktree", "resume_session", "push",
}
FORBIDDEN = {
    "on_event", "reply_to", "logging", "resume?", "resume", "repo_path",
    "path", "base",
}
AGENT_KEYS = {"provider", "model", "effort", "approval_mode", "env"}
PROVIDERS = {"pi", "claude", "litellm"}
EFFORTS = {"minimal", "low", "medium", "high", "xhigh"}
APPROVAL_MODES = {"default", "prompt", "auto_edit", "auto_approve"}
SANDBOXES = {"docker", "host"}
HOOK_TARGETS = {"sandbox"}
HOOK_PHASES = {"on_worktree_ready", "on_sandbox_ready"}
BRANCH_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]*$")


class Fail(Exception):
    def __init__(self, code, msg):
        super().__init__(f"{code}: {msg}")
        self.code = code


def is_json_value(v):
    if v is None or isinstance(v, (bool, int, float, str)):
        return True
    if isinstance(v, list):
        return all(is_json_value(x) for x in v)
    if isinstance(v, dict):
        return all(isinstance(k, str) and is_json_value(x) for k, x in v.items())
    return False


def check_keys(spec):
    # `_comment*` is a validator-only escape hatch: the SERVER rejects an unknown
    # top-level key, so a commented template must be run through strip_comments()
    # before it is sent. See SKILL.md Step 3.
    for key in spec:
        if isinstance(key, str) and key.startswith("_comment"):
            continue
        if not isinstance(key, str):
            raise Fail("spec_unknown_key", f"non-string key {key!r}")
        if key in FORBIDDEN:
            raise Fail("spec_forbidden_key", f"{key!r} cannot be supplied in a remote spec")
        if key == "prompt_file":
            raise Fail("spec_prompt_file_forbidden", "send the prompt text as 'prompt'")
        if key not in ALLOWED:
            raise Fail("spec_unknown_key", f"unknown spec key {key!r}")


def check_values(spec):
    if not is_json_value(spec):
        raise Fail("spec_non_json_value", "spec contains a non-JSON value (tuple/atom/pid/struct)")


def need(spec, key, code, want):
    if key not in spec:
        raise Fail(code, f"{key} is required")
    return spec[key]


def check_project(spec):
    v = need(spec, "project_id", "spec_project_id_missing", "non-empty string")
    if not isinstance(v, str) or not v:
        raise Fail("spec_project_id_invalid", "project_id must be a non-empty string")


def check_prompt(spec):
    v = need(spec, "prompt", "spec_prompt_missing", "non-blank string")
    if not isinstance(v, str):
        raise Fail("spec_prompt_invalid", "prompt must be a string")
    if not v.strip():
        raise Fail("spec_prompt_invalid", "prompt must not be blank")


def check_agent(spec, env_keys):
    agent = need(spec, "agent", "spec_agent_missing", "object")
    if not isinstance(agent, dict) or isinstance(agent, bool):
        raise Fail("spec_agent_invalid", "agent must be an object")
    for key in agent:
        if isinstance(key, str) and key.startswith("_comment"):
            continue
        if key not in AGENT_KEYS:
            raise Fail("spec_agent_invalid", f"unknown agent key {key!r}")

    prov = agent.get("provider")
    if not isinstance(prov, str) or not prov:
        raise Fail("spec_provider_invalid", "agent.provider is required and must be a string")
    if prov not in PROVIDERS:
        raise Fail("spec_provider_invalid",
                   f"unsupported provider {prov!r}; supported: {sorted(PROVIDERS)} "
                   "(read JidoHarness.providers() for the live list)")

    model = agent.get("model")
    if not isinstance(model, str) or not model:
        raise Fail("spec_agent_invalid", "agent.model is required and must be a non-empty string")

    if "effort" in agent and agent["effort"] not in EFFORTS:
        raise Fail("spec_agent_invalid", f"agent.effort must be one of {sorted(EFFORTS)}")

    if "approval_mode" in agent and agent["approval_mode"] not in APPROVAL_MODES:
        raise Fail("spec_approval_mode_invalid",
                   f"agent.approval_mode must be one of {sorted(APPROVAL_MODES)}")

    if "env" in agent:
        env = agent["env"]
        if not isinstance(env, dict) or not all(isinstance(k, str) for k in env):
            raise Fail("spec_agent_invalid", "agent.env must be an object of string keys")
        for key in env:
            if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key):
                raise Fail("spec_env_not_allowed",
                           f"agent.env key {key!r} is not an env-var name; no server allowlist can contain it")
            if key not in env_keys:
                raise Fail("spec_env_not_allowed",
                           f"agent.env key {key!r} is not in the server's agent_env_allowlist")


def check_sandbox(spec, allow_host):
    if "sandbox" not in spec:
        return
    v = spec["sandbox"]
    if not isinstance(v, str) or v not in SANDBOXES:
        raise Fail("spec_sandbox_invalid", 'sandbox must be "docker" or "host"')
    if v == "host" and not allow_host:
        raise Fail("spec_sandbox_not_allowed",
                   'host sandbox needs FOREMAN_JOBSITES_ALLOW_HOST_SANDBOX=true on the server')


def check_strategy(spec):
    """Returns the branch name when a named-branch strategy is declared."""
    if "strategy" not in spec:
        return None
    v = spec["strategy"]
    if v == "head":
        return None
    if isinstance(v, dict):
        if set(v) == {"branch"}:
            return validate_branch(v["branch"])
        if set(v) == {"type", "name"} and v["type"] == "branch":
            return validate_branch(v["name"])
    raise Fail("spec_strategy_invalid",
               'strategy must be "head", {"branch": name} or {"type": "branch", "name": name}')


def validate_branch(name):
    if not isinstance(name, str) or not name:
        raise Fail("spec_strategy_invalid", "branch name must be a non-empty string")
    if not BRANCH_RE.match(name):
        raise Fail("spec_strategy_invalid", f"invalid branch name {name!r}")
    if name.endswith((".lock", "/", ".")):
        raise Fail("spec_strategy_invalid", f"invalid branch name {name!r}")
    return name


def check_numbers(spec):
    for key in ("max_iterations", "idle_timeout_seconds", "completion_timeout_seconds"):
        if key in spec:
            v = spec[key]
            if isinstance(v, bool) or not isinstance(v, int) or v < 0:
                raise Fail("spec_option_invalid", f"{key} must be a non-negative integer")
    cs = spec.get("completion_signal")
    if cs is not None:
        ok = (isinstance(cs, str) and cs) or (isinstance(cs, list) and cs
                                            and all(isinstance(x, str) and x for x in cs))
        if not ok:
            raise Fail("spec_option_invalid",
                       "completion_signal must be a non-empty string or non-empty list of them")


def check_relpaths(spec):
    for key in ("exclude_paths", "copy_to_worktree"):
        if key not in spec:
            continue
        v = spec[key]
        if not isinstance(v, list) or not all(isinstance(x, str) and x and not x.startswith("/")
                                             and ".." not in x.split("/") for x in v):
            raise Fail("spec_option_invalid", f"{key} must be a list of relative paths inside the project")


def check_hooks(spec):
    if "hooks" not in spec:
        return
    hooks = spec["hooks"]
    if not isinstance(hooks, dict):
        raise Fail("spec_hooks_invalid", "hooks must be an object")
    for target, phases in hooks.items():
        if target == "host":
            raise Fail("spec_hooks_forbidden", "hooks.host.* runs sh -c on the server and is never allowed")
        if target not in HOOK_TARGETS:
            raise Fail("spec_hooks_invalid", f"unknown hooks target {target!r}; only 'sandbox'")
        if not isinstance(phases, dict):
            raise Fail("spec_hooks_invalid", "hooks.sandbox must be an object")
        for phase in phases:
            if phase not in HOOK_PHASES:
                raise Fail("spec_hooks_invalid",
                           f"unknown hook phase {phase!r}; one of {sorted(HOOK_PHASES)}")


def check_cross_options(spec):
    """Jobsite.Options.validate/1, which runs AFTER from_json's own checks."""
    mi = spec.get("max_iterations", 1)
    mi = mi if isinstance(mi, int) and not isinstance(mi, bool) else 1
    if mi > 1:
        if spec.get("resume_session"):
            raise Fail("resume_with_iterations",
                       "resume_session cannot be combined with max_iterations > 1")


def check_push(spec, branch):
    if "push" not in spec:
        return
    v = spec["push"]
    if not isinstance(v, bool):
        raise Fail("spec_option_invalid", "push must be a boolean")
    if v and branch is None:
        raise Fail("spec_push_requires_branch",
                   'push requires a {"branch": name} strategy: only a named branch can be published')


def validate(spec, env_keys, allow_host):
    if not isinstance(spec, dict):
        raise Fail("spec_invalid", "spec must be a JSON object")
    check_keys(spec)
    check_values(spec)
    check_project(spec)
    check_prompt(spec)
    check_agent(spec, env_keys)
    check_sandbox(spec, allow_host)
    branch = check_strategy(spec)
    check_numbers(spec)
    check_relpaths(spec)
    check_hooks(spec)
    check_cross_options(spec)
    check_push(spec, branch)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("spec")
    ap.add_argument("--env-key", action="append", default=[],
                    help="an agent.env key the server allowlists (repeatable)")
    ap.add_argument("--allow-host-sandbox", action="store_true")
    ap.add_argument("--project-id", help="warn if the spec's project_id differs from this")
    args = ap.parse_args()

    try:
        with open(args.spec) as fh:
            spec = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"spec_invalid: cannot read {args.spec}: {exc}", file=sys.stderr)
        return 1

    try:
        validate(spec, set(args.env_key), args.allow_host_sandbox)
    except Fail as exc:
        print(str(exc), file=sys.stderr)
        return 1

    if args.project_id and spec.get("project_id") != args.project_id:
        print(f"warning: project_id {spec.get('project_id')!r} != {args.project_id!r}; "
              "confirm it is registered on the server (`foreman project list`)", file=sys.stderr)

    print("ok: spec passes the remote whitelist (server gates still apply)")
    return 0


if __name__ == "__main__":
    sys.exit(main())


def strip_comments(obj):
    """Remove `_comment*` keys so a template can be POSTed as-is."""
    if isinstance(obj, dict):
        return {k: strip_comments(v) for k, v in obj.items()
                if not (isinstance(k, str) and k.startswith("_comment"))}
    if isinstance(obj, list):
        return [strip_comments(x) for x in obj]
    return obj
