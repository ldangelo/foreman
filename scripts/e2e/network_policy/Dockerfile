# The jobsite image of scripts/e2e/network_policy_flow.sh (tagged foreman-jobsite:<scratch repo name>, which
# is the image the docker sandbox defaults to). curl + jq for the probe, and a SIMULATED `pi` (fake-pi)
# because the real agent is a node program this image does not carry.
FROM alpine:3.20
RUN apk add --no-cache curl jq
COPY fake-pi /usr/local/bin/pi
RUN chmod 0755 /usr/local/bin/pi
