# An Elixir 1.18 / OTP 27+ base is required for the built-in :json module used
# by foreman_client. The agent runs in the SERVER's Docker, from the image named
# by the spec's sandbox settings; build it on the machine running foreman_server.
#
#   docker build --build-arg AGENT_UID=$(id -u) --build-arg AGENT_GID=$(id -g) \
#     --build-context ensemble=<your ensemble checkout> \
#     -t foreman-jobsite:<name> .foreman
#
# See packages/foreman_cli/cmd/foreman/templates/shared/Dockerfile in the Foreman
# repo for the reference image (installs ensemble into pi / Claude Code, plus br
# and bv). This file is a starting point, not a copy of it.
FROM elixir:1.18-otp-27-slim

ARG AGENT_UID=1000
ARG AGENT_GID=1000

RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates build-essential \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid ${AGENT_GID} agent 2>/dev/null || true \
    && useradd --uid ${AGENT_UID} --gid ${AGENT_GID} -m agent 2>/dev/null || true

# The sandbox bind-mounts the worktree and, for a linked worktree, the repo's git dir, both
# read-write at the same host paths. Foreman injects `safe.directory` for exactly those paths
# into `docker run` itself (`safe_directory_args/1` and `git_mount_args/2` in
# lib/foreman_server/jobsite/sandboxes/docker.ex), and `agent_cli_path/3` re-injects them on
# every `docker exec` through an `--env-file` under the system tmp dir. Neither path reads the
# image's own environment, so an `ENV GIT_CONFIG_*` here is silently overridden -- and a
# `safe.directory=*` here would widen trust beyond the two mounted paths, which is deliberate:
# "Trust only the mounted paths, not every path (`*`)" at docker.ex:112. Do not add
# safe.directory entries to this image. If git refuses a directory, the gap is in the server's
# mount list, not here.
USER agent
WORKDIR /workspace
