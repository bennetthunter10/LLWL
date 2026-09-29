#!/usr/bin/env bash
#
# LLWL lab 2 -- teardown
#
#     sudo ./teardown.sh
#
# Removes everything the lab owns and leaves the machine as it was.
#
# This one deletes home directories, which lab 1 did not. `userdel --remove` as
# root is the shape of a script that eats somebody's data, so an account has to
# clear two independent gates before it is touched: its NAME must be one of the
# lab's accounts, and its HOME must be exactly where that account's home
# belongs. If either is off, the account goes but the directory stays, loudly.
#
# The manifest is a file on disk, so it is input, not authority. Every kind of
# entry it can name -- path, unit, user, group -- is checked against a list
# written into this script before anything is acted on. A manifest that says
# "user root" or "unit ssh.service" gets a refusal, not a deletion.
#
# Groups are different again. The learner invents their own group names in this
# lab, so they are not in the manifest -- and this script will not go guessing
# at groups by pattern and deleting them as root. It prints them for a human.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=../lib/common.sh
source "$HERE/../lib/common.sh"

LAB_STATE=/var/lib/llwl-labs
MANIFEST=$LAB_STATE/lab2.manifest

# The only things this script is ever allowed to touch. Exact names, not
# patterns: a pattern like llwl* would also match an account somebody else made.
ALLOWED=(
	/srv/llwl-report
	/etc/llwl-report
	/var/log/llwl-report
	/srv/llwl-projects
	/etc/systemd/system/llwl-report.service
	/etc/systemd/system/llwl-audit.service
	/etc/sudoers.d/llwl-oncall
)
ALLOWED_UNITS=(llwl-report.service llwl-audit.service)
ALLOWED_USERS=(llwlmira llwltoby llwlnadia llwlreport)
ALLOWED_GROUPS=(llwlops)

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

# Exact-match membership: in_list VALUE ITEM...
in_list() {
	local needle=$1 item
	shift
	for item in "$@"; do
		[[ $item == "$needle" ]] && return 0
	done
	return 1
}

# Two gates, both must pass, before any home directory is deleted. The home
# must be /home/<that user's own name> and must be what passwd says it is, so a
# tampered passwd entry or manifest line cannot point the deletion elsewhere.
home_is_safe_to_delete() {
	local user=$1 home=$2
	in_list "$user" "${ALLOWED_USERS[@]}" || return 1
	[[ $home == "/home/$user" ]] || return 1
	[[ -d $home && ! -L $home ]] || return 1
	[[ $(getent passwd "$user" | cut -d: -f6) == "$home" ]] || return 1
	return 0
}

units=() paths=() users=() groups=() homes=()

if [[ -f $MANIFEST ]]; then
	while read -r kind value; do
		[[ -z ${kind:-} || $kind == '#'* ]] && continue
		case $kind in
		unit) units+=("$value") ;;
		path) paths+=("$value") ;;
		user) users+=("$value") ;;
		group) groups+=("$value") ;;
		home) homes+=("$value") ;;
		note) ;;
		*) warn "ignoring unknown manifest entry: $kind $value" ;;
		esac
	done <"$MANIFEST"
else
	warn "no manifest at $MANIFEST -- falling back to the default lab 2 layout"
	units=("${ALLOWED_UNITS[@]}")
	paths=("${ALLOWED[@]}")
	users=("${ALLOWED_USERS[@]}")
	# Groups are never deleted without a manifest. It is the only record of who
	# created llwlops, and deleting as root on a guess is the habit this repo
	# teaches you out of. A kept empty group is litter; a wrongly deleted one
	# silently breaks another lab or something of yours.
	for g in "${ALLOWED_GROUPS[@]}"; do
		getent group "$g" >/dev/null &&
			warn "NOTE: group $g left in place. It may belong to another lab or to you, and with no manifest there is no record of who created it. Review it with: getent group $g"
	done
	homes=(/home/llwlmira /home/llwltoby /home/llwlnadia)
fi

# ---------------------------------------------------------------------------
# 1. Units first: a running service holds files open.
# ---------------------------------------------------------------------------

for u in "${units[@]}"; do
	if ! in_list "$u" "${ALLOWED_UNITS[@]}"; then
		warn "refusing to stop unit $u -- not on this lab's allow-list"
		continue
	fi
	systemctl is-active --quiet "$u" 2>/dev/null && { info "stopping $u"; systemctl stop "$u"; }
	systemctl is-enabled --quiet "$u" 2>/dev/null && { info "disabling $u"; systemctl disable "$u" >/dev/null; }
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
	[[ -e $p || -L $p ]] && { info "removing $p"; rm -rf -- "$p"; }
done

systemctl daemon-reload
for u in "${ALLOWED_UNITS[@]}"; do systemctl reset-failed "$u" 2>/dev/null || true; done

# ---------------------------------------------------------------------------
# 3. Accounts. The name is checked here, before anything else looks at the
#    account. delete_user (lib/common.sh) has no opinion about who may be
#    deleted -- it would remove root if asked -- so the policy lives here.
#    Home directories are matched to their owner, so a stale `home` line cannot
#    cause an unrelated directory to be deleted.
# ---------------------------------------------------------------------------

for u in "${users[@]}"; do
	if ! in_list "$u" "${ALLOWED_USERS[@]}"; then
		warn "refusing to delete user $u -- not on this lab's allow-list"
		continue
	fi
	getent passwd "$u" >/dev/null || continue
	h=$(getent passwd "$u" | cut -d: -f6)
	if home_is_safe_to_delete "$u" "$h"; then
		info "deleting user $u and its home $h"
		delete_user "$u" || warn "$u is still there; remove it by hand once its processes are gone"
		# userdel --remove refuses a home directory whose owner is not the
		# account (Toby's, straight after setup: it belongs to an orphaned uid),
		# and leaves it behind. The gate above already vouched for this exact
		# path, so finishing the job here is no wider than what was approved.
		if ! getent passwd "$u" >/dev/null && [[ -d $h && ! -L $h ]]; then
			rm --recursive --force -- "$h"
		fi
	else
		info "deleting user $u (keeping its home directory)"
		delete_user_keep_home "$u" || warn "$u is still there; remove it by hand once its processes are gone"
		[[ -d $h && $h != /nonexistent ]] &&
			warn "left $h in place -- it does not look like a lab home directory; remove it yourself if you are sure"
	fi
done

# Anything listed as a lab home that survived the loop above is now orphaned.
for h in "${homes[@]}"; do
	[[ -d $h ]] || continue
	warn "$h still exists and no lab account owns it -- review and remove it by hand"
done

# ---------------------------------------------------------------------------
# 4. Groups. Only the lab's own group, however the manifest is worded. Secondary
#    members need no stripping first: groupdel (tested) removes the group and
#    their membership with it, and refuses only when the group is some
#    account's PRIMARY group. Members are never touched on the path that keeps
#    the group, so a learner's membership survives for the lab that needs it.
# ---------------------------------------------------------------------------

for g in "${groups[@]}"; do
	if ! in_list "$g" "${ALLOWED_GROUPS[@]}"; then
		warn "refusing to delete group $g -- not on this lab's allow-list"
		continue
	fi
	getent group "$g" >/dev/null || continue
	# Another planted lab may have written down a claim on this group (lab 1
	# records llwlops whether or not it created it). Reading that claim is not
	# guessing; deleting the group would break that lab.
	claimed_by=""
	for other in "$LAB_STATE"/lab*.manifest; do
		[[ -f $other && $other != "$MANIFEST" ]] || continue
		grep --quiet --line-regexp --fixed-strings "group $g" "$other" && claimed_by=$other
	done
	if [[ -n $claimed_by ]]; then
		warn "group $g left in place -- $claimed_by also claims it, so another lab still needs it"
		continue
	fi
	info "deleting group $g"
	groupdel "$g" ||
		warn "could not delete group $g (is it some account's primary group?) -- left in place; review with: getent group $g"
done

# ---------------------------------------------------------------------------
# 5. Lab bookkeeping.
# ---------------------------------------------------------------------------

rm -f "$MANIFEST"
[[ -d $LAB_STATE ]] && rmdir --ignore-fail-on-non-empty "$LAB_STATE"

cat <<'DONE'

Lab 2 removed. Two things are deliberately left for you.

  The groups you invented are yours, not this lab's, so nothing here deleted
  them. List what is left and clean up whichever ones you no longer want:

      getent group | grep -vE '^(root|daemon|bin|sys|adm|sudo|users|nogroup):'

  Verify nothing else survived:

      getent passwd | grep llwl; getent group | grep llwl
      ls -d /srv/llwl-report /etc/llwl-report /srv/llwl-projects 2>/dev/null
      ls /etc/sudoers.d/llwl-* /etc/systemd/system/llwl-* 2>/dev/null
      sudo visudo -c

Re-plant any time with: sudo ./setup.sh

DONE
