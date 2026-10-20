# Don't Starve Together dedicated server image for Flux.
#
# Written from scratch. The game's native 64-bit Linux server (Steam app 343050), installed and
# updated with SteamCMD on every start, the surface and the caves run side by side in one
# container under a supervisor that writes the cluster from the environment (token, name,
# password, play style, players, mods), saves on stop, follows game and mod updates, keeps
# backups, and gives the hub a console and JSON status. See README.md.
# The base. CI builds it pinned to the digest it resolved and records that digest in the
# org.opencontainers.image.base.digest label, which the scheduled check compares against
# (.github/ci/needs-rebuild.sh).
ARG BASE_IMAGE=steamcmd/steamcmd:ubuntu-24
FROM ${BASE_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive
ARG FLUX_IMAGE_VERSION=dev

# libcurl3t64-gnutls: the one library the server binary needs that the base lacks (ldd, build
# 756039). lua5.1: the game's Lua version, to read modinfo.lua / modoverrides.lua as data.
# python3, NOT python3-minimal: fluxdst.py needs json and urllib.
RUN apt-get update -y && \
    apt-get upgrade -y --no-install-recommends && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl procps tzdata python3 lua5.1 libcurl3t64-gnutls && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY scripts/flux-lib.sh scripts/flux-entrypoint.sh scripts/flux-console.sh scripts/fluxdst.py scripts/flux-lua.lua /opt/flux/
RUN chmod 0755 /opt/flux/*.sh /opt/flux/fluxdst.py && \
    ln -s /opt/flux/flux-console.sh /usr/local/bin/flux-console && \
    ln -s /opt/flux/fluxdst.py /usr/local/bin/flux-dst

# SteamCMD's self-update, done once here instead of on every container start; the weekly
# rebuild keeps it current.
RUN steamcmd +quit >/dev/null 2>&1; test -d /root/.local/share/Steam

ENV FLUX_IMAGE_VERSION=${FLUX_IMAGE_VERSION}

VOLUME ["/mnt/dst/server", "/mnt/dst/data"]

# The surface's game port and the caves' (players are moved to it when they go down a
# sinkhole), and the surface's Steam query port.
EXPOSE 11000/udp 10999/udp 27016/udp

# The first start downloads about 4.3 GB. FluxOS does not act on health; this is for anyone
# running the image by hand.
HEALTHCHECK --interval=60s --timeout=10s --start-period=30m --retries=3 \
    CMD pgrep -f "^\./dontstarve_dedicated_server_nullrenderer_x64 .*-shard Master" >/dev/null || exit 1

ENTRYPOINT []
CMD ["/opt/flux/flux-entrypoint.sh"]
