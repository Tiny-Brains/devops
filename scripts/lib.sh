# WHERE A SETUP SCRIPT'S FILES ARE, given which environment it is acting on.
#
# Sourced by scripts/setup/*.sh, each of which has already `cd`-ed to devops/. The environment is
# TB_ENV (`dev`, `qa` or `prod`), from the environment or a script's own `--env`; `tb` exports it.
#
# THE POINT OF THIS FILE is that a path appears once. Before the move each script carried its own
# `.env` and `keys/` relative to a repo root, which worked only because there was one environment
# per checkout. There are now three per machine, and a script that guesses picks production.
set -u

TB_ENV="${TB_ENV:-dev}"

tb_env_check() {
  case "$TB_ENV" in
    dev|qa|prod) ;;
    *) echo "unknown environment '$TB_ENV' -- one of dev, qa, prod" >&2; return 1 ;;
  esac
  [ -d "$TB_ENV" ] || { echo "no devops/$TB_ENV/ -- nothing is set up for that environment here" >&2; return 1; }
}

# Call after TB_ENV is settled. Every name below is a path relative to devops/.
tb_paths() {
  tb_env_check || exit 1
  TB_WEB_ENV="$TB_ENV/web/.env"          # the Soma/site stack's environment
  TB_KALAM_ENV="$TB_ENV/kalam/.env"      # a runner's, on this machine
  TB_KEYS="$TB_ENV/web/keys"             # this environment's trust key and signatures
  TB_SIGS="$TB_KEYS/signatures"          # what `[packages] signatures_dir` reads
  TB_TRUST_KEY="$TB_KEYS/tinybrains-dev.pem"
  TB_KALAM_KEYS="$TB_ENV/kalam/keys"
}

# The compose file an environment's stack is brought up with. Two per environment: the site and a
# runner. QA REUSES PRODUCTION'S FILES, BOTH OF THEM -- one file, two projects.
#
# It did not always. QA ran beside production on one machine, and a file of its own carried what
# that cost: no ports (production's caddy owned 80/443), a service on production's network for
# caddy to reach, and a forwarder in front of it because a container on two networks resolves
# `soma` to whichever Docker answers with -- which was production's, so QA's site served its own
# build over the LIVE API. QA has its own VM now, so none of that is true: it is the same topology
# production runs, which is the only thing a QA stack is for. Everything that differs -- the
# hostname, the images, the pools, the heap -- is in qa/web/.env.
tb_compose() {   # $1 web|runner
  case "$TB_ENV:$1" in
    dev:web)     echo compose/web.yml ;;
    dev:runner)  echo compose/runner.yml ;;
    qa:web)      echo compose/web.prod.yml ;;
    qa:runner)   echo compose/runner.prod.yml ;;
    prod:web)    echo compose/web.prod.yml ;;
    prod:runner) echo compose/runner.prod.yml ;;
    *) echo "no compose file for $TB_ENV/$1" >&2; return 1 ;;
  esac
}

# The compose PROJECT name. One machine runs several, and two projects sharing a name is one
# replacing the other -- which is how a QA runner would silently take production's place.
tb_project() {   # $1 web|runner
  case "$TB_ENV:$1" in
    dev:web)     echo tinybrains ;;
    dev:runner)  echo tinybrains-runner ;;
    qa:web)      echo tinybrains-qa ;;
    qa:runner)   echo tinybrains-runner-qa ;;
    prod:web)    echo tinybrains-prod ;;
    prod:runner) echo tinybrains-runner-prod ;;
  esac
}
