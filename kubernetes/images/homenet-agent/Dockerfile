# Runtime for the household network scripts (../../apps/homenet/scripts).
#
# Just the tools, no scripts: those come from a ConfigMap, so changing one is
# a commit and a Flux rollout, not an image rebuild. The image only changes
# when the base does.
#
# Debian 13 with Python 3.13 -- the toolset the scripts were written against:
# mawk, util-linux logger and GNU coreutils. That matters for shell that
# parses router output with awk, where implementations differ.
FROM python:3.13.13-slim-trixie

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

USER 65534:65534
