# syntax=docker/dockerfile:1
#
# Multi-stage build for ArrJanitor.
#
# The private dependencies (mjblack/sonarr, mjblack/qbittorrent.cr) are fetched
# from GitHub over HTTPS by `shards install`, so the builder needs a GitHub token
# with *read* access to those repos. That token is passed in as a BuildKit
# *secret* (never an ARG/ENV) so it is not baked into any image layer.
#
# Build (BuildKit required):
#   DOCKER_BUILDKIT=1 docker build \
#     --secret id=ghtoken,env=GH_TOKEN \
#     -t arr_janitor .
#
# (GH_TOKEN must be exported in the environment running the build.)

# ---------------------------------------------------------------------------
# Builder stage: compile a release binary with the multi-threaded runtime.
# ---------------------------------------------------------------------------
FROM crystallang/crystal:1.20.2 AS build

# crystal-sqlite3 links against libsqlite3 and needs its dev headers to build.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy only the dependency manifests first so `shards install` is cached and
# only re-runs when the manifests change. shard.lock IS committed for this app.
COPY shard.yml shard.lock ./

# Fetch dependencies. The GitHub token is mounted as a BuildKit secret at
# /run/secrets/ghtoken and used only to route HTTPS clones through the token;
# it never lands in a layer. If the secret is absent (e.g. all deps public),
# the install still runs without it.
RUN --mount=type=secret,id=ghtoken \
    sh -c 'if [ -f /run/secrets/ghtoken ]; then git config --global url."https://$(cat /run/secrets/ghtoken)@github.com/".insteadOf "https://github.com/"; fi' \
    && shards install --production

# Copy the rest of the source and build the release binary. -Dpreview_mt enables
# Crystal's multi-threaded runtime (backend fibers run across threads).
COPY . .
# `bin/` is excluded by .dockerignore, so create the output dir before linking
# (the linker will not create a missing parent directory for -o).
RUN mkdir -p /app/bin \
    && crystal build -Dpreview_mt src/main.cr -o /app/bin/arr_janitor --release

# ---------------------------------------------------------------------------
# Runtime stage: a slim image with only the shared libs the binary links.
# ---------------------------------------------------------------------------
FROM debian:12-slim

# libsqlite3-0 is the runtime SQLite lib; libyaml-0-2 backs YAML config parsing
# (the binary links libyaml); ca-certificates for HTTPS to the *arr / download
# client; tzdata for correct local-time handling.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       libsqlite3-0 libyaml-0-2 ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/*

# Run as a dedicated non-root user. /config holds the mounted config, /data the
# SQLite database — both owned by the runtime user so it can read/write them.
RUN useradd --system --uid 10001 --create-home --home-dir /home/arrjanitor arrjanitor \
    && mkdir -p /config /data \
    && chown arrjanitor:arrjanitor /config /data

COPY --from=build /app/bin/arr_janitor /usr/local/bin/arr_janitor

# Persist config and the database across container restarts.
VOLUME ["/config", "/data"]

# Number of Crystal runtime worker threads (-Dpreview_mt). Documented and
# overridable at run time (e.g. -e CRYSTAL_WORKERS=8).
ENV CRYSTAL_WORKERS=4

USER arrjanitor

# Default working directory is the writable data volume, so the config's
# default `database: arr_janitor.db` (relative) lands in /data even if the user
# doesn't set an absolute path.
WORKDIR /data

# Run as a daemon by default (continuous scheduler). Override CMD without
# --daemon for a single-pass run:
#   docker run ... arr_janitor --config /config/config.yml
ENTRYPOINT ["arr_janitor"]
CMD ["--config", "/config/config.yml", "--daemon"]
