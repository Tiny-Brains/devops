#!/usr/bin/env sh
# Normalise two values the config reads, wait for Postgres, and exec orion-server.
#
# Nothing is loaded here. Orion holds channels, workflows and plugins in its state database and
# only takes them over the admin API, so installing the three packages is the `loader` service's
# job -- which is also why this can exec rather than run the server in the background: PID 1 is
# orion-server, and SIGTERM reaches it directly.
set -eu

# Read by the config as [storage] url = "env://ORION_STATE_DB_URL". Checked by name so a missing
# one is reported before orion-server is asked to migrate against it.
: "${ORION_STATE_DB_URL:?ORION_STATE_DB_URL is required}"

# [vars] cookie_secure = ${SOMA_COOKIE_SECURE:-true} must substitute to a bare TOML boolean, so
# normalise what the environment hands over: 0/false/no -> false, anything else -- including
# unset -- true. Browsers refuse to store a Secure cookie from an http:// origin, so a plain-http
# stack sets 0.
case "${SOMA_COOKIE_SECURE:-1}" in
  0|false|no) SOMA_COOKIE_SECURE=false ;;
  *)          SOMA_COOKIE_SECURE=true ;;
esac
export SOMA_COOKIE_SECURE

# [vars] engine_digest: the engine this server plays, and the only rows the wave may claim. Orion
# keys the plugin by sha256 over the component, the claim filters on this, and the loader writes
# the same value into games.active_engine_digest -- so it is DERIVED from the vendored component
# rather than typed, and the three agree by construction. The environment may still pin one, for a
# rolling-deploy rehearsal; the loader refuses a pin that disagrees with the file.
if [ -z "${KALAM_ENGINE_DIGEST:-}" ]; then
  wasm="${KALAM_ENGINE_WASM:-/pkg/kalam/plugins/tb-ants/tb-ants.wasm}"
  if [ ! -r "$wasm" ]; then
    echo "engine component not readable at $wasm -- mount ../kalam at /pkg/kalam, or set KALAM_ENGINE_DIGEST" >&2
    exit 1
  fi
  KALAM_ENGINE_DIGEST="sha256:$(sha256sum "$wasm" | cut -d' ' -f1)"
fi
export KALAM_ENGINE_DIGEST

# Instance config, mounted from the deployment repo. orion-server substitutes its ${NAME:-default}
# references from this environment as it reads the file, so nothing is rendered to disk.
CFG="${ORION_CONFIG_TEMPLATE:-/etc/orion/orion.toml.tmpl}"
if [ ! -r "$CFG" ]; then
  echo "instance config not readable at $CFG -- mount it, or set ORION_CONFIG_TEMPLATE" >&2
  exit 1
fi

echo "==> waiting for postgres"
# `migrate` connects to the state database and applies Orion's own schema, so it doubles as the
# readiness probe. Compose gates on the db healthcheck already; this covers a plain `docker run`
# and a database that restarts.
i=0
until orion-server -c "$CFG" migrate > /dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -ge 30 ]; then
    echo "postgres did not become reachable in time" >&2
    orion-server -c "$CFG" migrate    # once more, unsilenced, to show why
    exit 1
  fi
  sleep 2
done

echo "==> starting orion-server, engine $KALAM_ENGINE_DIGEST"
exec orion-server -c "$CFG"
