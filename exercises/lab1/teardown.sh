#!/usr/bin/env bash
#
# LLWL lab 1 -- teardown
#
#     sudo ./teardown.sh
#
# Removes everything setup.sh created, using the manifest it left behind, and
# leaves the machine exactly as it was. Safe to run at any point, solved or not.
#
# Note the safety check below. This script runs "rm -rf" on paths it reads out
# of a file, as root. That is exactly the shape of a script that eats somebody's
# home directory, so every path is checked against an allow-list first. Write
# your own root scripts this way.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=../lib/common.sh
source "$HERE/../lib/common.sh"

LAB_STATE=/var/lib/llwl-labs
MANIFEST=$LAB_STATE/lab1.manifest

# The only paths this script is ever allowed to delete.
ALLOWED=(
	/srv/llwl-api
	/etc/llwl-api
	/var/log/llwl-api
	/var/lib/llwl-api
	/etc/systemd/system/llwl-api.service
)

need_linux
need_root
need_cmd systemctl

is_allowed() {
	local p=$1 a
	[[ $p == /* && $p != *..* ]] || return 1
	for a in "${ALLOWED[@]}"; do
		[[ $p == "$a" || $p == "$a"/* ]] && return 0
	done
	return 1
}

# ---------------------------------------------------------------------------
# Read the manifest, or fall back to the known layout if it is gone.
# ---------------------------------------------------------------------------

units=() paths=() users=() groups=()

if [[ -f $MANIFEST ]]; then
	while read -r kind value; do
		[[ -z ${kind:-} || $kind == '#'* ]] && continue
		case $kind in
		unit) units+=("$value") ;;
		path) paths+=("$value") ;;
		user) users+=("$value") ;;
		group) groups+=("$value") ;;
		*) warn "ignoring unknown manifest entry: $kind $value" ;;
		esac
	done <"$MANIFEST"
else
	warn "no manifest at $MANIFEST -- falling back to the default lab 1 layout"
	units=(llwl-api.service)
	paths=("${ALLOWED[@]}")
	users=(llwlapi)
	groups=(llwlapi llwlops)
fi

# ---------------------------------------------------------------------------
# 1. Units first: a running service holds files open.
# ---------------------------------------------------------------------------

for u in "${units[@]}"; do
	if systemctl is-active --quiet "$u"; then
		info "stopping $u"
		systemctl stop "$u"
	fi
	if systemctl is-enabled --quiet "$u" 2>/dev/null; then
		info "disabling $u"
		systemctl disable "$u" >/dev/null
	fi
done

# ---------------------------------------------------------------------------
# 2. Paths, in reverse order, allow-list checked.
# ---------------------------------------------------------------------------

for ((i = ${#paths[@]} - 1; i >= 0; i--)); do
	p=${paths[i]}
	if ! is_allowed "$p"; then
		warn "refusing to delete $p -- not on this lab's allow-list"
		continue
	fi
	if [[ -e $p ]]; then
		info "removing $p"
		rm -rf -- "$p"
	fi
done

systemctl daemon-reload
systemctl reset-failed llwl-api.service 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. Accounts. Strip secondary members before deleting a group, or groupdel
#    refuses.
# ---------------------------------------------------------------------------

for u in "${users[@]}"; do
	if getent passwd "$u" >/dev/null; then
		info "deleting user $u"
		userdel "$u"
	fi
done

for g in "${groups[@]}"; do
	getent group "$g" >/dev/null || continue
	members=$(getent group "$g" | cut -d: -f4)
	if [[ -n $members ]]; then
		IFS=',' read -r -a member_list <<<"$members"
		for m in "${member_list[@]}"; do
			[[ -n $m ]] || continue
			info "removing $m from $g"
			gpasswd -d "$m" "$g" >/dev/null
		done
	fi
	info "deleting group $g"
	groupdel "$g"
done

# ---------------------------------------------------------------------------
# 4. Lab bookkeeping.
# ---------------------------------------------------------------------------

rm -f "$MANIFEST"
[[ -d $LAB_STATE ]] && rmdir --ignore-fail-on-non-empty "$LAB_STATE"

cat <<'DONE'

Lab 1 removed. Verify for yourself that nothing is left behind:

    getent passwd llwlapi; getent group llwlops
    ls -d /srv/llwl-api /etc/llwl-api /var/log/llwl-api /var/lib/llwl-api
    systemctl list-unit-files | grep llwl

All three should come back empty. Re-plant any time with: sudo ./setup.sh

DONE
