#!/usr/bin/env bash
#
# LLWL lab 1 -- checker
#
#     ./check.sh        run every tier
#     ./check.sh 1      run just tier 1
#
# Run this as YOURSELF, not with sudo. Tier 3 tests what your account can do.
#
# It reports symptoms, in the language an auditor or a monitoring system would
# use. Translating "writable by every user on the system" into the right chmod
# is your job -- that translation is the entire skill.
#
# Yes, you can read this script and see the modes it wants. Go ahead. Knowing
# that a file should be 0640 is not the lesson; knowing why, and what breaks at
# 0600 and at 0644, is. The tier 3 test cannot be faked by matching numbers
# anyway: it drops a real file in and waits for the service to notice.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=../lib/common.sh
source "$HERE/../lib/common.sh"

SVC=llwl-api
SVC_USER=llwlapi
OPS_GROUP=llwlops

APP_DIR=/srv/llwl-api
CONF_DIR=/etc/llwl-api
LOG_DIR=/var/log/llwl-api
STATE_DIR=/var/lib/llwl-api
INCOMING=$APP_DIR/incoming
LOG_FILE=$LOG_DIR/app.log
UNIT=/etc/systemd/system/$SVC.service

ME=$(id -un)

need_linux
refuse_root

TIER=${1:-all}
case $TIER in
1 | 2 | 3 | all) ;;
*) die "usage: $0 [1|2|3]" ;;
esac

want_tier() { [[ $TIER == all || $TIER == "$1" ]]; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

for p in "$APP_DIR" "$APP_DIR/run.sh" "$CONF_DIR/api.conf" "$CONF_DIR/secrets.env" \
	"$LOG_DIR" "$STATE_DIR" "$INCOMING" "$UNIT"; do
	[[ -e $p ]] || die "$p is missing -- plant (or re-plant) the lab with:  sudo $HERE/setup.sh"
done

if want_tier 2 || want_tier 3; then
	# sudo -n succeeds silently if we already have a valid ticket (or passwordless
	# sudo); only prompt when we actually need to.
	if ! sudo -n true 2>/dev/null; then
		info "Tiers 2 and 3 have to look inside root-owned directories, so this script needs sudo once."
		sudo -v || die "no sudo available; ./check.sh 1 works without it"
	fi
fi

# ---------------------------------------------------------------------------
# Tier 1 -- the service will not even start
# ---------------------------------------------------------------------------

if want_tier 1; then
	section "Tier 1 -- the service will not even start"

	m=$(mode_of "$APP_DIR/run.sh")
	if has_bits "$m" 100; then
		pass "run.sh is executable by its owner"
	else
		fail "$APP_DIR/run.sh is not executable by its owner (mode $m); systemd cannot exec it"
	fi
	if has_bits "$m" 22; then
		fail "$APP_DIR/run.sh is writable by its group or by everyone (mode $m); anyone who can edit it decides what root's service manager launches"
	else
		pass "run.sh is not writable by group or other"
	fi

	m=$(mode_of "$CONF_DIR/api.conf")
	if has_bits "$m" 2; then
		fail "$CONF_DIR/api.conf is writable by every user on the system (mode $m); run.sh sources it, so that is arbitrary command execution as $SVC_USER"
	else
		pass "api.conf is not writable by other users"
	fi
	if has_bits "$m" 20; then
		fail "$CONF_DIR/api.conf is group-writable (mode $m, group $(group_of "$CONF_DIR/api.conf"))"
	else
		pass "api.conf is not group-writable"
	fi
	if has_bits "$m" 400; then
		pass "api.conf is still readable by its owner"
	else
		fail "$CONF_DIR/api.conf is no longer readable by its owner (mode $m); you have locked out the service"
	fi
fi

# ---------------------------------------------------------------------------
# Tier 2 -- it starts, and then it dies
# ---------------------------------------------------------------------------

if want_tier 2; then
	section "Tier 2 -- it starts, and then it dies"

	if sudo -u "$SVC_USER" test -w "$LOG_DIR"; then
		pass "$SVC_USER can write to $LOG_DIR"
	else
		fail "$SVC_USER cannot write to $LOG_DIR ($(owner_of "$LOG_DIR"), mode $(mode_of "$LOG_DIR")); the service dies on its first log line"
	fi
	m=$(mode_of "$LOG_DIR")
	if has_bits "$m" 7; then
		fail "$LOG_DIR is open to every user on the system (mode $m); logs are not public"
	else
		pass "$LOG_DIR is closed to users outside its group"
	fi

	if sudo -u "$SVC_USER" test -w "$STATE_DIR"; then
		pass "$SVC_USER can write to $STATE_DIR"
	else
		fail "$SVC_USER cannot write to $STATE_DIR ($(owner_of "$STATE_DIR"), mode $(mode_of "$STATE_DIR")); the service cannot record what it has processed"
	fi

	m=$(mode_of "$CONF_DIR/secrets.env")
	if has_bits "$m" 4; then
		fail "$CONF_DIR/secrets.env is readable by every user on the system (mode $m); the API token is not a secret"
	else
		pass "secrets.env is not readable by other users"
	fi
	if has_bits "$m" 22; then
		fail "$CONF_DIR/secrets.env is writable by its group or by everyone (mode $m); it is sourced at runtime, so that is command execution as $SVC_USER"
	else
		pass "secrets.env is not writable by group or other"
	fi
	if sudo -u "$SVC_USER" test -r "$CONF_DIR/secrets.env"; then
		pass "$SVC_USER can still read secrets.env"
	else
		fail "you have locked secrets.env down so far that $SVC_USER cannot read it ($(owner_of "$CONF_DIR/secrets.env"), mode $m); a secret the service cannot read is just a broken service"
	fi

	# The needle. Nothing in the deployment has any business being world-writable.
	ww=$(sudo find "$APP_DIR" "$CONF_DIR" "$LOG_DIR" "$STATE_DIR" -xdev -perm /o+w -print 2>/dev/null || true)
	if [[ -z $ww ]]; then
		pass "nothing under the deployment is writable by every user on the system"
	else
		fail "these paths are writable by every user on the system:"
		while read -r p; do note "$p"; done <<<"$ww"
	fi

	if systemctl is-active --quiet "$SVC"; then
		pass "$SVC is running"
	else
		fail "$SVC is not running; look at 'systemctl status $SVC' and 'journalctl -u $SVC -n 20' to find out where it died"
	fi

	if sudo test -s "$LOG_FILE"; then
		pass "$LOG_FILE has content"
	else
		fail "$LOG_FILE is empty or missing; the service never got far enough to log anything"
	fi
fi

# ---------------------------------------------------------------------------
# Tier 3 -- the bits nobody explains
# ---------------------------------------------------------------------------

if want_tier 3; then
	section "Tier 3 -- the bits nobody explains"

	m=$(mode_of "$LOG_DIR")
	if has_bits "$m" 2000; then
		pass "$LOG_DIR carries the setgid bit"
	else
		fail "$LOG_DIR has no setgid bit (mode $m); files created in it get the creator's group instead of the directory's, so tomorrow's log is unreadable again"
	fi
	if [[ $(group_of "$LOG_DIR") == "$OPS_GROUP" ]]; then
		pass "$LOG_DIR belongs to group $OPS_GROUP"
	else
		fail "$LOG_DIR belongs to group $(group_of "$LOG_DIR"); no human is a member of that, so no human can read the logs"
	fi

	m=$(mode_of "$INCOMING")
	if has_bits "$m" 1000; then
		pass "$INCOMING carries the sticky bit"
	else
		fail "$INCOMING has no sticky bit (mode $m); in a shared drop directory any writer can delete another writer's files"
	fi
	if has_bits "$m" 20; then
		pass "$INCOMING is group-writable"
	else
		fail "$INCOMING is not group-writable (mode $m); nobody but its owner can drop files in it"
	fi
	if [[ $(group_of "$INCOMING") == "$OPS_GROUP" ]]; then
		pass "$INCOMING belongs to group $OPS_GROUP"
	else
		fail "$INCOMING belongs to group $(group_of "$INCOMING") rather than $OPS_GROUP"
	fi
	if has_bits "$m" 7; then
		fail "$INCOMING is open to every user on the system (mode $m); a drop directory is for the operators, not for everyone"
	else
		pass "$INCOMING is closed to users outside its group"
	fi

	if user_in_group "$ME" "$OPS_GROUP"; then
		pass "$ME is listed as a member of $OPS_GROUP"
		if session_has_group "$OPS_GROUP"; then
			pass "this shell actually carries the $OPS_GROUP group"
		else
			fail "this shell predates the membership: group changes only apply to processes started afterwards. Log out and back in, or run 'exec newgrp $OPS_GROUP', then check again"
		fi
	else
		fail "$ME is not a member of $OPS_GROUP, so none of the group permissions above apply to you"
	fi

	# The test that cannot be faked: drop a real file in as yourself and see
	# whether the service notices, then read the log without sudo.
	probe="probe-$$-$(date +%s)"
	# The subshell is not decoration: a failing redirection is reported by the
	# shell itself, so "2>/dev/null" on the command alone would not silence it.
	if (: >"$INCOMING/$probe") 2>/dev/null; then
		pass "you can create a file in $INCOMING as yourself"
		printf 'dropped by %s\n' "$ME" >"$INCOMING/$probe"

		if [[ -r $LOG_FILE ]]; then
			pass "you can read $LOG_FILE without sudo"
			found=false
			for _ in $(seq 1 15); do
				if grep -q -- "$probe" "$LOG_FILE"; then
					found=true
					break
				fi
				sleep 1
			done
			if $found; then
				pass "end to end: the service picked up your file, logged it, and you read that log unprivileged"
			else
				fail "the service never logged $probe within 15s; is it still running? 'journalctl -u $SVC -n 20'"
			fi
		else
			fail "$LOG_FILE is not readable by you ($(sudo stat -c '%U:%G, mode %a' -- "$LOG_FILE" 2>/dev/null || echo 'cannot stat it either')). Remember that changing a directory's group does not change the group of files already inside it"
		fi
		rm -f -- "$INCOMING/$probe"
	else
		fail "you cannot create a file in $INCOMING as yourself ($(owner_of "$INCOMING"), mode $(mode_of "$INCOMING"))"
	fi
fi

if finish; then
	if [[ $TIER == all ]]; then
		info "Lab 1 is solved. Write your fix up as a script in solutions/, jot your notes in ../../notes/, and compare against solutions/bennett.sh."
	fi
	exit 0
else
	exit 1
fi
