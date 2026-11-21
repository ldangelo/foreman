# The image of the Docker-sandbox PR-fix stage (github_extras.sh `docker_fix_ci`), tagged
# foreman-jobsite:<project checkout directory name>, which is the image the docker sandbox defaults to.
# A SIMULATED `pi` (fake-pi) stands in for the agent: the real one is a node program this image does not carry.
FROM alpine:3.20
RUN apk add --no-cache git
COPY fake-pi /usr/local/bin/pi
RUN chmod 0755 /usr/local/bin/pi
