# Multi-stage build for ArrJanitor.
#
# Both dependencies (mjblack/sonarr, mjblack/qbittorrent.cr) are public GitHub
# repos, so `shards install` fetches them over HTTPS with no token or secret.
#
# Build:
#   docker build -t arr_janitor .

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

# Fetch dependencies. Both deps are public GitHub repos, so no token is needed.
RUN shards install --production

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

# Working directory is the writable data volume. The database location no longer
# depends on the CWD — it is set explicitly by the `--database` param below — but
# a writable WORKDIR is kept as a harmless sane default.
WORKDIR /data

# Run as a daemon by default (continuous scheduler), reading the config from
# /config and writing the database to /data — both passed explicitly so they land
# on the mounted volumes regardless of the CWD. Override CMD without --daemon for
# a single-pass run:
#   docker run ... arr_janitor --config /config/config.yml --database /data/arr_janitor.db
ENTRYPOINT ["arr_janitor"]
CMD ["--config", "/config/config.yml", "--database", "/data/arr_janitor.db", "--daemon"]
