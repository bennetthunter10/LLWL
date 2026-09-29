#!/usr/bin/env bash
#
# LLWL lab 2 -- setup
#
# Plants the state of a team that just grew: two services, two accounts that
# were created carelessly, a project directory nobody has organised, and a sudo
# rule the previous admin left behind.
#
#     sudo ./setup.sh
#
# Same two promises as lab 1:
#   1. It only ever CREATES new paths and accounts. It never modifies anything
#      that was already on your system -- in particular it never touches
#      /etc/sudoers or any drop-in it did not write.
#   2. Everything is recorded in /var/lib/llwl-labs/lab2.manifest and removed
#      completely by ./teardown.sh
#
# Idempotent: re-run it at any time, including from a fully solved lab, to put
# the machine back in its original broken state.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=../lib/common.sh
source "$HERE/../lib/common.sh"

REPORT_SVC=llwl-report
AUDIT_SVC=llwl-audit
REPORT_USER=llwlreport
OPS_GROUP=llwlops

APP_DIR=/srv/llwl-report
CONF_DIR=/etc/llwl-report
LOG_DIR=/var/log/llwl-report
PROJ_DIR=/srv/llwl-projects
REPORT_UNIT=/etc/systemd/system/$REPORT_SVC.service
AUDIT_UNIT=/etc/systemd/system/$AUDIT_SVC.service
SUDOERS_DROPIN=/etc/sudoers.d/llwl-oncall

LAB_STATE=/var/lib/llwl-labs
MANIFEST=$LAB_STATE/lab2.manifest

need_linux
need_root
need_cmd systemctl
need_cmd useradd
need_cmd usermod
need_cmd chage
need_cmd visudo

# ---------------------------------------------------------------------------
# 1. Stop anything from a previous planting, so a re-run is a true reset.
# ---------------------------------------------------------------------------

for u in "$REPORT_SVC" "$AUDIT_SVC"; do
	systemctl is-active --quiet "$u" 2>/dev/null && systemctl stop "$u"
done

# ---------------------------------------------------------------------------
# 2. Service identity. llwlops carries over from lab 1: the humans who operate
#    a service. In this lab it is the group allowed to read the credentials.
# ---------------------------------------------------------------------------

getent group "$OPS_GROUP" >/dev/null || groupadd --system "$OPS_GROUP"
getent passwd "$REPORT_USER" >/dev/null || useradd \
	--system \
	--no-create-home \
	--home-dir /nonexistent \
	--shell /usr/sbin/nologin \
	--comment "LLWL lab 2 reporting service account" \
	"$REPORT_USER"

# ---------------------------------------------------------------------------
# 3. The reporting service. Nothing is wrong with it -- this lab is not about
#    fixing a service, it is about who is allowed to restart one.
# ---------------------------------------------------------------------------

mkdir -p "$APP_DIR" "$CONF_DIR" "$LOG_DIR" "$LAB_STATE"

cat >"$CONF_DIR/report.conf" <<'CONF'
# /etc/llwl-report/report.conf -- runtime configuration for llwl-report.
SERVICE_NAME="llwl-report"
TICK_SECONDS=5
CONF

cat >"$CONF_DIR/secrets.env" <<'SECRETS'
# /etc/llwl-report/secrets.env -- credentials for llwl-report.
# Readable by root and by the operators group. Being on call is not the same
# thing as being trusted with these.
REPORT_TOKEN="llwl-7b21e0c4a9-DEMO-NOT-A-REAL-SECRET"
SECRETS

cat >"$APP_DIR/run.sh" <<'RUNSH'
#!/usr/bin/env bash
# /srv/llwl-report/run.sh -- the llwl-report "daemon". Ticks, and says so.
set -euo pipefail
. /etc/llwl-report/report.conf
LOG=/var/log/llwl-report/report.log
echo "llwl-report: starting as $(id -un)"
while :; do
	printf '%s %s tick\n' "$(date -Is)" "${SERVICE_NAME:-llwl-report}" >>"$LOG"
	sleep "${TICK_SECONDS:-5}"
done
RUNSH

cat >"$REPORT_UNIT" <<UNITFILE
[Unit]
Description=LLWL practice reporting service (lab 2)
After=network.target

[Service]
Type=simple
User=$REPORT_USER
Group=$REPORT_USER
ExecStart=$APP_DIR/run.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNITFILE

cat >"$AUDIT_UNIT" <<'UNITFILE'
[Unit]
Description=LLWL practice compliance agent (lab 2)

# This unit does nothing, on purpose. It exists so that the lab has a service
# that the on-call account is NOT supposed to be able to touch -- which means
# you can prove an over-broad sudo rule is over-broad without going anywhere
# near a service that matters.

[Service]
Type=simple
ExecStart=/usr/bin/sleep infinity
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNITFILE

chown root:root "$APP_DIR/run.sh" "$CONF_DIR/report.conf" "$CONF_DIR/secrets.env"
chmod 0755 "$APP_DIR" "$CONF_DIR"
chmod 0755 "$APP_DIR/run.sh"
chmod 0644 "$CONF_DIR/report.conf"
chown root:"$OPS_GROUP" "$CONF_DIR/secrets.env"
chmod 0640 "$CONF_DIR/secrets.env"
chown "$REPORT_USER:$REPORT_USER" "$LOG_DIR"
chmod 0750 "$LOG_DIR"
chown root:root "$REPORT_UNIT" "$AUDIT_UNIT"
chmod 0644 "$REPORT_UNIT" "$AUDIT_UNIT"

systemctl daemon-reload
systemctl enable --now "$REPORT_SVC" >/dev/null
systemctl enable --now "$AUDIT_SVC" >/dev/null

# ---------------------------------------------------------------------------
# 4. Manifest. Everything this lab OWNS, whether setup.sh created it or the
#    learner is expected to. teardown.sh checks each entry for existence, so
#    listing llwlnadia here is how she gets cleaned up even though she is the
#    learner's to create.
# ---------------------------------------------------------------------------

write_manifest() {
	cat >"$MANIFEST" <<MANIFESTEOF
# LLWL lab 2 manifest -- every object this lab owns, in creation order.
# teardown.sh removes these in reverse. Kinds: path, unit, user, group, home, note.
unit $REPORT_SVC.service
unit $AUDIT_SVC.service
path $REPORT_UNIT
path $AUDIT_UNIT
path $SUDOERS_DROPIN
path $APP_DIR
path $CONF_DIR
path $LOG_DIR
path $PROJ_DIR
home /home/llwlmira
home /home/llwltoby
home /home/llwlnadia
user llwlmira
user llwltoby
user llwlnadia
user $REPORT_USER
group $OPS_GROUP
MANIFESTEOF
	chmod 0644 "$MANIFEST"
}
write_manifest
