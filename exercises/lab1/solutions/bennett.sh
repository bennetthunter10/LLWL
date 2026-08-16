#!/usr/bin/env bash
#
# LLWL lab 1 -- Bennett's reference solution.
#
#     sudo ./solutions/bennett.sh
#
# Don't read this until check.sh is green for you. Then read it and argue with
# it -- there is more than one defensible answer here, and "why 0640 and not
# 0600" is a better conversation than the number itself.
#
# The shape to copy is not the chmod lines, it is this: a fix you can re-run.
# Anybody can click a permission right once. Being able to hand somebody a
# script that puts a machine into a known-good state is the actual job.

set -euo pipefail

SVC=llwl-api
SVC_USER=llwlapi
OPS_GROUP=llwlops

APP_DIR=/srv/llwl-api
CONF_DIR=/etc/llwl-api
LOG_DIR=/var/log/llwl-api
STATE_DIR=/var/lib/llwl-api
INCOMING=$APP_DIR/incoming
CACHE_DIR=$APP_DIR/.deploy-cache

[[ $EUID -eq 0 ]] || {
	echo "run me with sudo: sudo $0" >&2
	exit 1
}

# --- tier 1 ---------------------------------------------------------------

# systemd needs to exec it; nobody but root needs to write it.
chmod 0755 "$APP_DIR/run.sh"

# run.sh sources this, so write access to it is command execution as llwlapi.
# 0644 is right: the service reads it, root maintains it.
chmod 0644 "$CONF_DIR/api.conf"

# --- tier 2 ---------------------------------------------------------------

# The token should be readable by the service and by nobody else. Owner stays
# root because root deploys the file; group is the service account so that the
# service can read it. 0600 root:root would be "more secure" and would also
# stop the service from starting, which is the trap.
chown root:"$SVC_USER" "$CONF_DIR/secrets.env"
chmod 0640 "$CONF_DIR/secrets.env"

# The service writes its own log, and the operators read it. Group ops, setgid
# so that every log file created here inherits that group instead of the
# service account's own.
chown "$SVC_USER":"$OPS_GROUP" "$LOG_DIR"
chmod 2750 "$LOG_DIR"

# Private to the service: nobody else has any business in its state.
chown "$SVC_USER":"$SVC_USER" "$STATE_DIR"
chmod 0750 "$STATE_DIR"

# The leftover deploy cache file. World-writable junk in a service directory is
# not worth arguing about -- delete it.
rm -f "$CACHE_DIR/decoy.tmp"

# --- tier 3 ---------------------------------------------------------------

# A shared drop box. The sticky bit stops one operator from deleting another
# operator's file, which is the same reason /tmp is drwxrwxrwt. Note that it does
# not restrain llwlapi: the owner of a directory can always delete anything in
# it, sticky or not. That is fine here -- the service is supposed to be able to
# clear the box. No access at all for anyone outside the group.
chown "$SVC_USER":"$OPS_GROUP" "$INCOMING"
chmod 1770 "$INCOMING"

# Setgid only affects files created from now on. Anything the service already
# wrote still carries the old group, so fix what is already there by hand.
# This is the step people forget, and then wonder why the fix "didn't work".
chgrp -R "$OPS_GROUP" "$LOG_DIR"
chmod -R g+r "$LOG_DIR"

# Put the human in the operators group. This changes the user database
# immediately, but a process only picks up its groups when it starts, so any
# shell that is already open still has the old set. Log out and back in, or
# 'exec newgrp llwlops'.
LEARNER=${SUDO_USER:-}
if [[ -n $LEARNER ]]; then
	if id -nG "$LEARNER" | tr ' ' '\n' | grep -qx "$OPS_GROUP"; then
		echo "$LEARNER is already in $OPS_GROUP"
	else
		gpasswd -a "$LEARNER" "$OPS_GROUP" >/dev/null
		echo "added $LEARNER to $OPS_GROUP"
	fi
else
	echo "could not tell who invoked me; add yourself with: sudo gpasswd -a \$USER $OPS_GROUP" >&2
fi

# --- and now it should run ------------------------------------------------

systemctl restart "$SVC"
systemctl --no-pager --lines=0 status "$SVC" || true

cat <<EOF

Fixed. If your current shell was open before the group change, it does not have
$OPS_GROUP yet and check.sh's tier 3 will still fail. Either log out and back in
or run:

    exec newgrp $OPS_GROUP

then:

    ./check.sh

EOF
