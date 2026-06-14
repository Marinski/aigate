# syntax=docker/dockerfile:1.7
#
# Pre-baked piston image — installs the language set declared in
# PISTON_LANGUAGES at BUILD time so the runtime container can live on
# aigate-internal with no outbound network. The trade-off is intentional:
# adding a new language = bump PISTON_LANGUAGES, `make build`, redeploy.
# In return, a popped neighbour container in aigate-public can no longer
# reach piston directly (it's no longer multi-homed).
#
# How the install happens: we spawn the upstream piston API server in the
# background DURING the docker build, wait for it to come up, POST to
# /api/v2/packages once per (language, version) pair, then stop the
# background process. piston downloads the tarballs from
# https://github.com/engineer-man/piston/releases/download/pkgs/* — the
# docker build context has internet access, so this works at build time
# even though the runtime container won't.

# Pinned by digest. Tag at build time: ghcr.io/engineer-man/piston:latest
# (upstream publishes only :latest — no semver). Bump via:
#   docker pull ghcr.io/engineer-man/piston:latest
#   docker image inspect ghcr.io/engineer-man/piston:latest --format '{{.RepoDigests}}'
FROM ghcr.io/engineer-man/piston@sha256:2f66b7456189c4d713aa986d98eccd0b6ee16d26c7ec5f21b30e942756fd127a AS prebake

# Minimum-useful default: python + node only. Operators add more by
# setting PISTON_LANGUAGES in .env (comma-separated language=version
# specs) — see piston pkgs index for the available list:
# https://github.com/engineer-man/piston/releases/tag/pkgs
# Override per build via `--build-arg PISTON_LANGUAGES=python=3.12.0,...`.
ARG PISTON_LANGUAGES="python=3.12.0,node=20.11.1"
ENV PISTON_LANGUAGES_BAKED=$PISTON_LANGUAGES

USER root
RUN mkdir -p /piston && chown -R piston:piston /piston
COPY --chown=piston:piston prebake-install.sh /usr/local/bin/prebake-install.sh
RUN chmod +x /usr/local/bin/prebake-install.sh

# Skip the upstream docker-entrypoint.sh during build — it sets up cgroups
# for runtime sandboxing (mkdir /sys/fs/cgroup/isolate/, requires
# privileged). At install time we just need the API server running long
# enough to download packages; the cgroup-sensitive sandbox path is unused.
USER piston
RUN /usr/local/bin/prebake-install.sh

# Restore the upstream entrypoint chain — at RUNTIME we go through the
# normal cgroup-init path (which needs privileged: true in compose). The
# only difference vs the stock image is that /piston/packages/ is now
# pre-populated.
USER root
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["/piston_api/src/docker-entrypoint.sh"]
