# shellcheck shell=bash
#
# Shared helpers for LLWL lab scripts. Source this file, don't execute it:
#
#     source "$(dirname "$0")/../lib/common.sh"
#
# Everything here is deliberately plain POSIX-ish bash. You are meant to read it.

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

# Colour only when we're talking to a real terminal, and honour NO_COLOR.
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
	C_RED=$'\033[31m'
	C_GREEN=$'\033[32m'
	C_YELLOW=$'\033[33m'
	C_BOLD=$'\033[1m'
	C_OFF=$'\033[0m'
else
	C_RED='' C_GREEN='' C_YELLOW='' C_BOLD='' C_OFF=''
fi

LLWL_PASS=0
LLWL_FAIL=0

section() { printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_OFF"; }
pass() {
	LLWL_PASS=$((LLWL_PASS + 1))
	printf '  %sPASS%s  %s\n' "$C_GREEN" "$C_OFF" "$1"
}
fail() {
	LLWL_FAIL=$((LLWL_FAIL + 1))
	printf '  %sFAIL%s  %s\n' "$C_RED" "$C_OFF" "$1"
}
skip() { printf '  %sSKIP%s  %s\n' "$C_YELLOW" "$C_OFF" "$1"; }
note() { printf '        %s\n' "$1"; }
info() { printf '%s\n' "$1"; }
warn() { printf '%s%s%s\n' "$C_YELLOW" "$1" "$C_OFF" >&2; }

# Print a message and give up.
die() {
	printf '%s%s%s\n' "$C_RED" "$1" "$C_OFF" >&2
	exit 1
}

# Print the tally. Returns 0 only if nothing failed, so callers can do:
#     if finish; then exit 0; else exit 1; fi
finish() {
	printf '\n%s%d passed, %d failed%s\n' "$C_BOLD" "$LLWL_PASS" "$LLWL_FAIL" "$C_OFF"
	((LLWL_FAIL == 0))
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

need_linux() {
	[[ $(uname -s) == Linux ]] || die "these labs only run on Linux (you are on $(uname -s))"
}

need_root() {
	[[ $EUID -eq 0 ]] || die "this script must run as root:  sudo $0"
}

refuse_root() {
	[[ $EUID -ne 0 ]] || die "run this as your normal user, not with sudo -- it tests what YOU can do"
}

# ---------------------------------------------------------------------------
# Inspecting permissions
# ---------------------------------------------------------------------------

# Numeric mode with no leading zero: 644, 2750, 1770 ...
mode_of() { stat -c '%a' -- "$1"; }
owner_of() { stat -c '%U:%G' -- "$1"; }
user_of() { stat -c '%U' -- "$1"; }
group_of() { stat -c '%G' -- "$1"; }

# has_bits <mode> <octal-mask> -- true if ANY bit in the mask is set.
#   has_bits 644 2   -> is it world-writable?
#   has_bits 2750 2000 -> is the setgid bit set?
has_bits() {
	local mode=$((8#$1)) mask=$((8#$2))
	((mode & mask))
}

# True if the CURRENT process really carries the named group.
#
# This is not the same question as "is the user listed in /etc/group". Group
# membership is baked into a process when it is created, so a shell that was
# already running when you ran `gpasswd -a` will never see the new group.
# /proc/self/status is the honest source for what this process actually has.
session_has_group() {
	local gid line
	gid=$(getent group "$1" | cut -d: -f3)
	[[ -n $gid ]] || return 1
	line=$(grep -E '^(Groups|Gid):' /proc/self/status || true)
	line=${line//$'\t'/ }
	line=${line//$'\n'/ }
	[[ " $line " == *" $gid "* ]]
}

# True if the named user is listed as a member of the group in the user database.
user_in_group() {
	local user=$1 group=$2
	getent group "$group" | cut -d: -f4 | tr ',' '\n' | grep -qx -- "$user"
}

# ---------------------------------------------------------------------------
# Asking what an account can actually do
#
# Lab 2 onwards, the interesting question is not "what mode is this file" but
# "can this person open it". Those are different questions -- group membership,
# ACLs and the traversability of every parent directory all sit in between --
# and the only honest way to answer the second one is to go and try it.
#
# Every helper here is safe to call for an account that does not exist: you get
# "no, they cannot", not an error. That matters because the learner is halfway
# through creating these people while the checker is running.
#
# Two rules for using them:
#
#   * Every probe returns 1 for "no". Under `set -e` a bare call to one would
#     kill the script, so only ever call them in an `if`, `&&`, `||` or `!`.
#
#   * Every sudo here is `sudo -n`. Without -n, a caller who needs a password
#     gets a prompt in the middle of a probe, and a checker that hangs waiting
#     for input is worse than one that says "no". With -n, sudo fails at once
#     when it has no ticket. That is why check.sh runs `sudo -v` once up front,
#     while a human is there to type the password: the ticket it caches is what
#     lets these probes run silently afterwards.
# ---------------------------------------------------------------------------

user_exists() { getent passwd "$1" >/dev/null 2>&1; }

# Run a command as somebody else. Needs a sudo ticket already in hand (see above).
as_user() {
	local u=$1
	shift
	user_exists "$u" || return 1
	sudo -n -u "$u" -- "$@"
}

can_user_read() { as_user "$1" test -r "$2" 2>/dev/null; }
can_user_write() { as_user "$1" test -w "$2" 2>/dev/null; }

# On a directory, x is the right to go *through* it and r is the right to see
# the names in it. They are genuinely separate powers, so ask separately.
can_user_traverse() { as_user "$1" test -x "$2" 2>/dev/null; }
can_user_list() { as_user "$1" ls -- "$2" >/dev/null 2>&1; }

# The only way to know whether somebody can put a file somewhere is to have them
# put one there. Cleans up after itself as root, because the probe file may well
# belong to somebody the caller cannot touch.
can_user_create() {
	local u=$1 dir=$2 probe rc=0
	user_exists "$u" || return 1
	probe="$dir/.llwl-probe-$$-${RANDOM}"
	as_user "$u" touch -- "$probe" 2>/dev/null || rc=1
	sudo -n rm -f -- "$probe" 2>/dev/null || true
	return $rc
}

# Prints the group a file gets when this user creates it here. That is how you
# tell a setgid directory from a directory somebody chgrp'd once by hand.
new_file_group() {
	local u=$1 dir=$2 probe g=''
	user_exists "$u" || return 1
	probe="$dir/.llwl-probe-$$-${RANDOM}"
	if as_user "$u" touch -- "$probe" 2>/dev/null; then
		# stat needs root: the caller is usually not in the group, so cannot
		# search the directory the probe file is in.
		g=$(sudo -n stat -c '%G' -- "$probe" 2>/dev/null || true)
	fi
	sudo -n rm -f -- "$probe" 2>/dev/null || true
	[[ -n $g ]] || return 1
	printf '%s\n' "$g"
}

login_shell_of() { getent passwd "$1" | cut -d: -f7; }

# Field 8 of /etc/shadow is the expiry date in days since 1970-01-01. Empty
# means "never". This is the only place an expired account is visible, which is
# exactly why an expired account is such a confusing thing to be handed.
#
# The date is the first day the account is DISABLED, not the last day it works.
# Observed on Ubuntu 24.04 (Sep 2026): with the expiry set to today's day number,
# `su` refuses with "Your account has expired"; set to tomorrow, it is allowed.
# So "expired" means exp <= today. (shadow counts UTC days, so use `date +%s`.)
account_expired() {
	local exp today
	user_exists "$1" || return 1
	exp=$(sudo -n getent shadow "$1" 2>/dev/null | cut -d: -f8)
	[[ -n $exp ]] || return 1
	today=$(($(date +%s) / 86400))
	((exp <= today))
}

# Behavioural: actually try to start a login shell as them.
#
# The account_expired guard is NOT redundant -- do not delete it. Verified on
# Ubuntu 24.04 (Sep 2026), as both root and an ordinary user:
# `sudo -u <expired-user> -i true` SUCCEEDS.
#
# What sudo does catch is the OTHER planted defect, and not by inspecting the
# shell -- it execs it, and /usr/sbin/nologin is a program that prints "This
# account is currently not available." and exits non-zero (nologin(8)). Nothing
# on that path consults the target's expiry date. `su - <expired-user>` does,
# and refuses with "Your account has expired; please contact your system
# administrator." / "su: Authentication failure", as would a console or ssh
# login. So without the guard this probe would say "can log in" for someone who
# cannot. Do not replace the guard with a claim about what sudo "cannot" do.
#
# Side effect: `sudo -i` opens a real login session, so systemd starts a
# per-user manager for the target, and it outlives this call by a moment.
# `userdel` refuses to delete an account while that is running ("userdel: user
# X is currently used by process N"). Anything that may have called this probe
# on an account and later deletes it must use delete_user, below, not bare userdel.
can_user_login() {
	local u=$1
	user_exists "$u" || return 1
	! account_expired "$u" || return 1
	sudo -n -u "$u" -i true >/dev/null 2>&1
}

# Delete an account, first ending any login session (see can_user_login), and
# retry for up to ten seconds while systemd tears the user manager down. Needs
# root. Succeeds if the account is gone at the end -- userdel's own exit status
# is not trusted, because it can report failure (no mail spool) after having
# done the job. Warns, rather than looping forever or staying silent, if the
# account will not go.
delete_user() { _delete_user_retrying "$1" --remove; }

# The same, but leaves the home directory alone. For an account whose home is
# not one the caller is willing to delete (or does not exist): it still needs
# the session teardown and the retry, or it survives because a user manager
# was still running.
delete_user_keep_home() { _delete_user_retrying "$1"; }

# Shared mechanism: _delete_user_retrying NAME [--remove]
_delete_user_retrying() {
	local u=$1 i
	shift
	user_exists "$u" || return 0
	loginctl terminate-user "$u" 2>/dev/null || true
	for i in {1..20}; do
		userdel "$@" "$u" 2>/dev/null || true
		user_exists "$u" || return 0
		sleep 0.5
	done
	warn "could not delete account $u"
	return 1
}

uid_of() { id -u "$1" 2>/dev/null; }
uid_has_name() { getent passwd "$1" >/dev/null 2>&1; }

# Ask the sudo policy what it would allow, without running anything.
sudo_permits() {
	local u=$1
	shift
	user_exists "$u" || return 1
	sudo -n -l -U "$u" -- "$@" >/dev/null 2>&1
}

acl_of() { getfacl --absolute-names --omit-header -- "$1" 2>/dev/null; }

# ACLs need both the setfacl tool and a filesystem mounted with acl support.
# Neither is guaranteed, so anything that depends on them must skip rather than
# fail when they are missing.
have_working_acls() {
	local dir=$1 probe rc=0
	command -v setfacl >/dev/null 2>&1 || return 1
	command -v getfacl >/dev/null 2>&1 || return 1
	probe="$dir/.llwl-acl-probe-$$"
	sudo -n touch -- "$probe" 2>/dev/null || return 1
	sudo -n setfacl -m u:root:rw -- "$probe" >/dev/null 2>&1 || rc=1
	sudo -n rm -f -- "$probe" 2>/dev/null || true
	return $rc
}
