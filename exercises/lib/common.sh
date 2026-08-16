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
