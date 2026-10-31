#!/usr/bin/env bash
# The CPU budget every container but Soma's shares, ON THE HOST that runs web.prod.yml.
#
#   sudo scripts/setup/cpu-slice.sh [quota]      default 50% (half a vCPU), e.g. 75%
#
# web.prod.yml and monitoring.yml put every non-Soma container under `cgroup_parent:
# ${AUX_SLICE:-tinybrains-aux.slice}`. This writes that slice's unit with CPUQuota, so the containers
# in it share the quota between them. It applies live -- running containers are capped at once, no
# recreate -- and persists across reboots. Re-run it to change the quota. Linux with systemd only.
set -euo pipefail
QUOTA="${1:-50%}"
SLICE="${AUX_SLICE:-tinybrains-aux.slice}"
case "$QUOTA" in *%) ;; *) echo "quota is a percentage of one CPU, e.g. 50%" >&2; exit 2 ;; esac
[ "$(id -u)" = 0 ] || { echo "run as root (sudo)" >&2; exit 1; }

cat > "/etc/systemd/system/$SLICE" <<UNIT
[Unit]
Description=TinyBrains containers other than Soma, sharing one CPU quota
Before=slices.target

[Slice]
CPUAccounting=yes
CPUQuota=$QUOTA
UNIT
systemctl daemon-reload
systemctl start "$SLICE"
systemctl show "$SLICE" -p CPUQuotaPerSecUSec
