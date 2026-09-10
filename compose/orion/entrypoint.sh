#!/usr/bin/env sh
# Normalise what the mounted config reads, migrate, and exec orion-server.
#
# ONE IMAGE, TWO ROLES. It takes no role argument: it asks the config what it needs by looking for
# the substitutions the config actually contains, so a config that stops referencing a value stops
# paying for it and neither can drift from the other.
#
# Nothing is loaded here -- installing a package is the `loader` service's job, which is why this
# can exec. PID 1 is orion-server and SIGTERM reaches it directly; `trap ... ; wait $PID` returns in
# ZERO seconds with rows still `running`, because the trap interrupts `wait`, `wait` returns, and
# the container exits while Orion is still draining.
set -eu

# orion-server substitutes ${NAME:-default} from this environment as it reads the file, so nothing
# is rendered to disk.
CFG="${ORION_CONFIG_TEMPLATE:-/etc/orion/orion.toml.tmpl}"
if [ ! -r "$CFG" ]; then
  echo "instance config not readable at $CFG -- mount it, or set ORION_CONFIG_TEMPLATE" >&2
  exit 1
fi

# Checked by name, so a missing value is reported against the config that wants it rather than as
# an Orion parse error further down.
needs() { grep -q "$1" "$CFG"; }

# ---------------------------------------------------------------- the state database
# Postgres (soma) or a SQLite file (kalam, a path this must be able to create).
if needs 'ORION_STATE_DB_URL'; then
  : "${ORION_STATE_DB_URL:?ORION_STATE_DB_URL is required by $CFG}"
fi
if needs 'ORION_STATE_PATH\|sqlite:'; then
  # Disposable: it holds the loaded package and nothing else, so this may be a container-local path
  # with no volume behind it.
  state_dir=$(dirname "${ORION_STATE_PATH:-/var/lib/orion/state.db}")
  mkdir -p "$state_dir" 2>/dev/null || true
  if [ ! -w "$state_dir" ]; then
    echo "state directory $state_dir is not writable by $(id -un)" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------- soma: the cookie flag
# [vars] cookie_secure must substitute to a bare TOML boolean. Browsers refuse to store a Secure
# cookie from an http:// origin, so a plain-http stack sets 0.
if needs 'SOMA_COOKIE_SECURE'; then
  case "${SOMA_COOKIE_SECURE:-1}" in
    0|false|no) SOMA_COOKIE_SECURE=false ;;
    *)          SOMA_COOKIE_SECURE=true ;;
  esac
  export SOMA_COOKIE_SECURE
fi

# ---------------------------------------------------------------- kalam: the engine digest
# The engine this replica plays, and the only rows its wave may claim. DERIVED from the vendored
# component rather than typed, so the plugin key, the claim filter and games.active_engine_digest
# agree by construction. A digest that agrees with nothing is silent everywhere: the wave claims
# nothing, for ever, and the replica looks healthy doing it. The environment may still pin one for a
# rolling-deploy rehearsal; the loader refuses a pin that disagrees with the file.
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
# Doubles as the readiness probe for Postgres. A cluster may not migrate at boot -- soma sets
# auto_migrate = false, and this is the deploy step that satisfies it.
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
