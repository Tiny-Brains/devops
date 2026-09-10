# syntax=docker/dockerfile:1

# Upstream orion-server, fetched and verified, with nothing baked in: no package, no config. The
# image is the same in every environment, so rebuilding it means an Orion upgrade and nothing else
# -- a package edit is `docker compose run --rm loader`, not a build.

# ---- fetch and verify the orion-server binary --------------------------------
FROM debian:bookworm-slim AS orion

# 1.7.0: the first release that takes a var:// in oauth2_login.redirect_uri, has
# principal_rate_limit, and runs the plugins the three packages ship.
ARG ORION_VERSION=1.7.0
ARG TARGETARCH

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/orion
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) triple=x86_64-unknown-linux-gnu ;; \
      arm64) triple=aarch64-unknown-linux-gnu ;; \
      *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    base="https://github.com/GoPlasmatic/Orion/releases/download/v${ORION_VERSION}"; \
    curl -fsSL -o orion.tar.xz "${base}/orion-server-${triple}.tar.xz"; \
    curl -fsSL -o orion.sha256 "${base}/orion-server-${triple}.tar.xz.sha256"; \
    echo "$(cut -d' ' -f1 orion.sha256)  orion.tar.xz" | sha256sum -c -; \
    tar -xJf orion.tar.xz; \
    install -m 0755 "orion-server-${triple}/orion-server" /usr/local/bin/orion-server; \
    orion-server --version

# ---- runtime -----------------------------------------------------------------
FROM debian:bookworm-slim

# curl answers the healthcheck; sha256sum (coreutils, already here) derives the engine digest.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --create-home --shell /usr/sbin/nologin orion \
 # A Kalam replica's SQLite state. No volume is mounted over it on purpose: it holds the loaded
 # package and nothing else. Unused by the soma role, which is on Postgres.
 && install -d -o orion -g orion /var/lib/orion

COPY --from=orion /usr/local/bin/orion-server /usr/local/bin/orion-server
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER orion
EXPOSE 8080

# 200 once startup has finished, the state database answers and no required background task has
# died. A channel that failed to load does NOT fail this -- the loader checks /health for those.
HEALTHCHECK --interval=10s --timeout=3s --start-period=20s --retries=5 \
  CMD curl -fsS http://127.0.0.1:8080/readyz > /dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
