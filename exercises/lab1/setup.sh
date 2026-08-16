#!/usr/bin/env bash
#
# LLWL lab 1 -- setup
#
# Plants a deliberately broken deployment of a small service called "llwl-api":
# real files, a real system user, a real systemd unit. Nothing about it is fake
# except the fact that its permissions are wrong on purpose.
#
#     sudo ./setup.sh
#
# Two promises this script keeps:
#   1. It only ever CREATES new paths. It never touches a file that was already
#      on your system, so nothing you rely on can break.
#   2. Everything it creates is recorded in /var/lib/llwl-labs/lab1.manifest and
#      removed completely by ./teardown.sh
#
# It is also idempotent: run it again at any time to reset the lab to its
# original broken state without duplicating the user, group, or unit.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=../lib/common.sh
source "$HERE/../lib/common.sh"

SVC=llwl-api
SVC_USER=llwlapi
SVC_GROUP=llwlapi
OPS_GROUP=llwlops

APP_DIR=/srv/llwl-api
CONF_DIR=/etc/llwl-api
LOG_DIR=/var/log/llwl-api
STATE_DIR=/var/lib/llwl-api
INCOMING=$APP_DIR/incoming
CACHE_DIR=$APP_DIR/.deploy-cache
UNIT=/etc/systemd/system/$SVC.service

LAB_STATE=/var/lib/llwl-labs
MANIFEST=$LAB_STATE/lab1.manifest

need_linux
need_root
need_cmd systemctl
need_cmd useradd
need_cmd groupadd

# ---------------------------------------------------------------------------
# 1. If the lab is already planted, stop the service before re-planting it.
# ---------------------------------------------------------------------------

if systemctl list-unit-files "$SVC.service" >/dev/null 2>&1 && systemctl is-active --quiet "$SVC"; then
	info "stopping the running $SVC service so the lab can be reset"
	systemctl stop "$SVC"
fi

# ---------------------------------------------------------------------------
# 2. Service identity.
#
# llwlapi is the unprivileged account the service runs as.
# llwlops  is the shared "people who operate this service" group -- the thing
#          you will eventually need to be a member of.
# ---------------------------------------------------------------------------

getent group "$OPS_GROUP" >/dev/null || groupadd --system "$OPS_GROUP"
getent group "$SVC_GROUP" >/dev/null || groupadd --system "$SVC_GROUP"
getent passwd "$SVC_USER" >/dev/null || useradd \
	--system \
	--gid "$SVC_GROUP" \
	--no-create-home \
	--home-dir /nonexistent \
	--shell /usr/sbin/nologin \
	--comment "LLWL lab service account" \
	"$SVC_USER"

# ---------------------------------------------------------------------------
# 3. The deployment itself.
# ---------------------------------------------------------------------------

mkdir -p "$APP_DIR" "$CONF_DIR" "$LOG_DIR" "$STATE_DIR" "$INCOMING" "$CACHE_DIR" "$LAB_STATE"

cat >"$CONF_DIR/api.conf" <<'CONF'
# /etc/llwl-api/api.conf -- runtime configuration for llwl-api.
# This file is sourced by /srv/llwl-api/run.sh, i.e. its contents are executed
# as the service account. Keep that in mind when you look at who can write it.
SERVICE_NAME="llwl-api"
POLL_SECONDS=2
INCOMING_DIR="/srv/llwl-api/incoming"
CONF

cat >"$CONF_DIR/secrets.env" <<'SECRETS'
# /etc/llwl-api/secrets.env -- credentials for llwl-api.
# Sourced by run.sh at runtime, as the service account. Not for general reading.
API_TOKEN="llwl-1f4c9a77d2e84b10-DEMO-NOT-A-REAL-SECRET"
SECRETS

cat >"$APP_DIR/run.sh" <<'RUNSH'
#!/usr/bin/env bash
#
# /srv/llwl-api/run.sh -- the llwl-api "daemon".
#
# It reads its config and its secrets, writes a startup line to its log, then
# watches a drop directory and logs every new file that appears there.
# Started by /etc/systemd/system/llwl-api.service as the llwlapi user.

set -euo pipefail

CONF=/etc/llwl-api/api.conf
SECRETS=/etc/llwl-api/secrets.env
LOG_DIR=/var/log/llwl-api
STATE_DIR=/var/lib/llwl-api
LOG_FILE=$LOG_DIR/app.log
SEEN_FILE=$STATE_DIR/processed.list

# This goes to the journal (systemd captures stdout), not to the log file.
echo "llwl-api: starting as $(id -un), groups: $(id -nG)"

# shellcheck source=/dev/null
. "$CONF"
# shellcheck source=/dev/null
. "$SECRETS"

log() { printf '%s %s\n' "$(date -Is)" "$*" >>"$LOG_FILE"; }

log "started ${SERVICE_NAME:-llwl-api}, token ...${API_TOKEN: -4}, watching ${INCOMING_DIR}"
: >>"$SEEN_FILE"

while :; do
	for f in "$INCOMING_DIR"/*; do
		[[ -f $f ]] || continue
		if ! grep -qxF -- "$f" "$SEEN_FILE"; then
			log "processed $(basename -- "$f") ($(wc -c <"$f" 2>/dev/null || echo '?') bytes, owner $(stat -c %U -- "$f"))"
			printf '%s\n' "$f" >>"$SEEN_FILE"
		fi
	done
	printf '%s\n' "$(date -Is)" >"$STATE_DIR/heartbeat"
	sleep "${POLL_SECONDS:-2}"
done
RUNSH

# A leftover from a previous deploy. It is junk, but it is also a liability.
cat >"$CACHE_DIR/decoy.tmp" <<'CACHE'
temp file left behind by a deploy in 2024
CACHE

cat >"$UNIT" <<'UNITFILE'
[Unit]
Description=LLWL practice service (lab 1)
Documentation=file:///srv/llwl-api/run.sh
After=network.target

[Service]
Type=simple
User=llwlapi
Group=llwlapi
ExecStart=/srv/llwl-api/run.sh
Restart=no
# New files the service creates are rw for the owner, r for the group, nothing
# for anybody else. World-readable logs would be sloppy -- which means group
# membership is the only way a human is going to read them.
UMask=0027

[Install]
WantedBy=multi-user.target
UNITFILE

# Clear anything left from a previous attempt so a reset is a true reset.
rm -f "$LOG_DIR"/*.log "$STATE_DIR"/processed.list "$STATE_DIR"/heartbeat
rm -f "$INCOMING"/probe-*

# ---------------------------------------------------------------------------
# 4. Break it.
#
# Every line below is the "wrong" state. This is the whole lab. Nothing else on
# your system is modified.
# ---------------------------------------------------------------------------

chown root:root "$APP_DIR" "$CONF_DIR" "$LOG_DIR" "$STATE_DIR" "$INCOMING" "$CACHE_DIR"
chown root:root "$APP_DIR/run.sh" "$CONF_DIR/api.conf" "$CONF_DIR/secrets.env" "$CACHE_DIR/decoy.tmp"

chmod 0755 "$APP_DIR"                # fine
chmod 0755 "$CONF_DIR"               # fine
chmod 0644 "$UNIT"                   # fine -- unit files belong to root
chown root:root "$UNIT"

chmod 0644 "$APP_DIR/run.sh"         # tier 1: not executable
chmod 0666 "$CONF_DIR/api.conf"      # tier 1: anyone can rewrite the config
chmod 0644 "$CONF_DIR/secrets.env"   # tier 2: anyone can read the token
chmod 0755 "$LOG_DIR"                # tier 2: the service cannot write its log
chmod 0700 "$STATE_DIR"              # tier 2: the service cannot write its state
chmod 0777 "$CACHE_DIR/decoy.tmp"    # tier 2: the needle in the haystack
chmod 0755 "$CACHE_DIR"
chmod 0755 "$INCOMING"               # tier 3: you cannot drop files in it

# ---------------------------------------------------------------------------
# 5. Manifest -- the record teardown.sh uses to undo all of this.
# ---------------------------------------------------------------------------

cat >"$MANIFEST" <<MANIFESTEOF
# LLWL lab 1 manifest -- every object setup.sh created, in creation order.
# teardown.sh removes these in reverse. Types: path, unit, user, group.
unit $SVC.service
path $UNIT
path $APP_DIR
path $CONF_DIR
path $LOG_DIR
path $STATE_DIR
user $SVC_USER
group $SVC_GROUP
group $OPS_GROUP
MANIFESTEOF
chmod 0644 "$MANIFEST"

systemctl daemon-reload

# ---------------------------------------------------------------------------
# 6. Briefing.
# ---------------------------------------------------------------------------

cat <<BRIEF

${C_BOLD}Lab 1 is planted.${C_OFF}

  A service called ${SVC} was deployed on this machine by an admin who has
  since left. It does not work. Nothing is wrong with the code or the unit
  file -- every problem is a permission or an ownership.

  Your job: make it run, keep it secure, and be able to read its logs without
  using sudo.

  Start here:
      systemctl status ${SVC}
      sudo systemctl start ${SVC}
      systemctl status ${SVC}
      ./check.sh 1

  Read ./README.md for the tiers and the ground rules.
  Undo everything at any time with:  sudo ./teardown.sh

BRIEF
