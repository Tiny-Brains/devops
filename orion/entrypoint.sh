#!/usr/bin/env sh
# Normalise what the mounted config reads, migrate, and exec orion-server.
#
# ONE IMAGE, TWO ROLES. Since layer 07 there are two instance configs -- soma.toml.tmpl and
# kalam.toml.tmpl -- and this script serves both. It does not take a role argument: it asks the
# config what it needs by looking for the substitutions the config actually contains. A config that
# stops referencing a value stops paying for it, and neither can drift from the other.
#
# Nothing is loaded here. Orion holds channels, workflows and plugins in its state database and
# only takes them over the admin API, so installing a package is the `loader` service's job --
# which is also why this can exec rather than run the server in the background: PID 1 is
# orion-server, and SIGTERM reaches it directly. That matters more than it looks: layer 03 §5
# measured `trap 'kill -TERM $PID'; wait $PID` returning in ZERO seconds with two rows still
# `running`, because the trap interrupts `wait`, `wait` returns, and the container exits while
# Orion is still draining. exec has no such hole.
set -eu

# Instance config, mounted from the deployment repo. orion-server substitutes its ${NAME:-default}
# references from this environment as it reads the file, so nothing is rendered to disk.
CFG="${ORION_CONFIG_TEMPLATE:-/etc/orion/orion.toml.tmpl}"
if [ ! -r "$CFG" ]; then
  echo "instance config not readable at $CFG -- mount it, or set ORION_CONFIG_TEMPLATE" >&2
  exit 1
fi

# What does this config actually ask for? Checked by name so a missing value is reported here,
# against the config that wants it, rather than as an Orion parse error further down.
needs() { grep -q "$1" "$CFG"; }

# ---------------------------------------------------------------- the state database
# Postgres (soma.toml.tmpl, env:// so the server resolves it after parsing) or a SQLite file
# (kalam.toml.tmpl, a path this must be able to create).
if needs 'ORION_STATE_DB_URL'; then
  : "${ORION_STATE_DB_URL:?ORION_STATE_DB_URL is required by $CFG}"
fi
if needs 'ORION_STATE_PATH\|sqlite:'; then
  # A replica's Orion state is DISPOSABLE -- it holds the loaded package and nothing else, and
  # everything that matters is in Postgres. So this may be a container-local path with no volume
  # behind it: losing it on a restart costs one package load, which the loader does anyway.
  state_dir=$(dirname "${ORION_STATE_PATH:-/var/lib/orion/state.db}")
  mkdir -p "$state_dir" 2>/dev/null || true
  if [ ! -w "$state_dir" ]; then
    echo "state directory $state_dir is not writable by $(id -un)" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------- soma: the cookie flag
# [vars] cookie_secure must substitute to a bare TOML boolean, so normalise what the environment
# hands over: 0/false/no -> false, anything else -- including unset -- true. Browsers refuse to
# store a Secure cookie from an http:// origin, so a plain-http stack sets 0.
if needs 'SOMA_COOKIE_SECURE'; then
  case "${SOMA_COOKIE_SECURE:-1}" in
    0|false|no) SOMA_COOKIE_SECURE=false ;;
    *)          SOMA_COOKIE_SECURE=true ;;
  esac
  export SOMA_COOKIE_SECURE
fi

# ---------------------------------------------------------------- kalam: the engine digest
# [vars] engine_digest: the engine this replica plays, and the only rows its wave may claim. Orion
# keys the plugin by sha256 over the component, the claim filters on this, and the loader writes
# the same value into games.active_engine_digest -- so it is DERIVED from the vendored component
# rather than typed, and the three agree by construction. The environment may still pin one, for a
# rolling-deploy rehearsal; the loader refuses a pin that disagrees with the file.
#
# A digest that agrees with nothing is the one failure that is silent everywhere: the wave claims
# nothing, for ever, and the replica looks healthy doing it.
if needs 'KALAM_ENGINE_DIGEST'; then
  if [ -z "${KALAM_ENGINE_DIGEST:-}" ]; then
    wasm="${KALAM_ENGINE_WASM:-/pkg/kalam/plugins/tb-ants/tb-ants.wasm}"
    if [ ! -r "$wasm" ]; then
      echo "engine component not readable at $wasm -- mount ../kalam at /pkg/kalam, or set KALAM_ENGINE_DIGEST" >&2
      exit 1
    fi
    KALAM_ENGINE_DIGEST="sha256:$(sha256sum "$wasm" | cut -d' ' -f1)"
  fi
  export KALAM_ENGINE_DIGEST
  echo "==> engine $KALAM_ENGINE_DIGEST"
fi

# ---------------------------------------------------------------- migrate, then serve
# `migrate` connects to the state database and applies Orion's own schema, so it doubles as the
# readiness probe for Postgres. On SQLite it is instant and local. A CLUSTER MAY NOT MIGRATE AT
# BOOT -- soma.toml.tmpl sets auto_migrate = false and this is the deploy step that satisfies it.
echo "==> migrating state"
i=0
until orion-server -c "$CFG" migrate > /dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -ge 30 ]; then
    echo "state database did not become reachable in time" >&2
    orion-server -c "$CFG" migrate    # once more, unsilenced, to show why
    exit 1
  fi
  sleep 2
done

echo "==> starting orion-server with $CFG"
exec orion-server -c "$CFG"
