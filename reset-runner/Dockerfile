# =============================================================================
# reset-runner -- the image the chart's reset Job runs
# =============================================================================
# Carries scripts/ (reset-scenario.sh, restart-exercise.sh and their libs) with
# the tools they call: bash, kubectl, curl, jq, timeout.
#
# WHY GNU TOOLS ON TOP OF THE BASE. The base image's date, awk, sed and grep
# are BusyBox. BusyBox `date -d` rejects an ISO-8601 timestamp ending in Z, and
# reset-scenario.sh reads its cadence that way: on BusyBox the read fails and
# the script silently falls back to the default cadence, which is a wrong
# answer that looks like a right one. So coreutils, gawk, grep and sed replace
# them.
#
# WHY python3. restart-exercise.sh parses JSON replies with it (json_get).
#
# The scripts are versioned WITH this image: a Job runs the scripts baked in
# here, not the ones in the checkout. Pin the image by digest together with the
# chart (exerciseControl.resetJob.image.digest).
#
# BUILD CONTEXT is the multi-repo root, as for bundle/Dockerfile, so the path
# below starts with openddil-helm/.
FROM docker.io/alpine/k8s:1.31.4
RUN apk add --no-cache coreutils gawk grep sed findutils python3
COPY openddil-helm/scripts /opt/openddil/scripts
RUN find /opt/openddil/scripts -name '*.sh' -exec chmod 755 {} \;
WORKDIR /opt/openddil
