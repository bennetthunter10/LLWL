#!/usr/bin/env bash
#
# LLWL lab 2 -- checker
#
#     ./check.sh        tiers 1-3, the lab proper
#     ./check.sh 2      just tier 2
#     ./check.sh 4      the optional tier
#
# Run this as YOURSELF, not with sudo.
#
# Almost every check in here asks "can this person actually do this", not "what
# mode is this file". That is deliberate: the group structure in this lab is
# yours to design, so there is no group name for a checker to look for, and no
# number you can match to make it go green. Read it all you like.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=../lib/common.sh
source "$HERE/../lib/common.sh"

REPORT_SVC=llwl-report
AUDIT_SVC=llwl-audit
REPORT_USER=llwlreport
OPS_GROUP=llwlops
MIRA=llwlmira
TOBY=llwltoby
NADIA=llwlnadia

CONF_DIR=/etc/llwl-report
SECRETS=$CONF_DIR/secrets.env
PROJ_DIR=/srv/llwl-projects
ALPHA=$PROJ_DIR/alpha
BETA=$PROJ_DIR/beta
SHARED=$PROJ_DIR/shared
SUDOERS_DROPIN=/etc/sudoers.d/llwl-oncall

need_linux
refuse_root

TIER=${1:-main}
case $TIER in
1 | 2 | 3 | 4 | main) ;;
*) die "usage: $0 [1|2|3|4]" ;;
esac

want_tier() { [[ $TIER == "$1" ]] || { [[ $TIER == main && $1 != 4 ]]; }; }

# Only what setup.sh has planted so far; later tiers add to this list as they
# plant more. The sudoers drop-in is deliberately never in it: a learner may
# delete it, and tier 3 should report that as a failure rather than the whole
# run aborting here.
for p in "$SECRETS"; do
	[[ -e $p ]] || die "$p is missing -- plant (or re-plant) the lab with:  sudo $HERE/setup.sh"
done

# Everything here has to ask what OTHER accounts can do, and that needs root.
# One ticket up front, so you are asked once rather than forty times.
if ! sudo -n true 2>/dev/null; then
	info "This checker has to test what other people's accounts can do, so it needs sudo once."
	sudo -v || die "no sudo available -- if you have just edited a sudoers file, check it with: sudo visudo -c"
fi

# ---------------------------------------------------------------------------
# Tier 1 -- the people
# ---------------------------------------------------------------------------

if want_tier 1; then
	section "Tier 1 -- the people"

	for u in "$MIRA" "$TOBY" "$NADIA"; do
		if user_exists "$u"; then
			pass "$u exists"
		else
			fail "there is no account called $u; somebody has to create it"
			continue
		fi

		if can_user_login "$u"; then
			pass "$u can start a login shell"
		elif account_expired "$u"; then
			fail "$u's account has expired; nothing about the shell or the password will tell you that"
		else
			fail "$u cannot start a login shell (shell is $(login_shell_of "$u")); that shell is for accounts that are never meant to be logged into"
		fi

		h=$(getent passwd "$u" | cut -d: -f6)
		if [[ -d $h ]]; then
			pass "$u has a home directory at $h"
		else
			fail "$u has no home directory at $h; a human account without one lands in / and cannot write anywhere"
			continue
		fi
		owner_uid=$(stat -c '%u' -- "$h")
		if [[ $owner_uid == "$(uid_of "$u")" ]]; then
			pass "$h belongs to $u"
		elif uid_has_name "$owner_uid"; then
			fail "$h belongs to $(stat -c '%U' -- "$h"), not to $u"
		else
			fail "$h belongs to uid $owner_uid, which is not any account on this machine; ownership is a number, and that number belongs to nobody"
		fi
	done

	# Being on call is not the same thing as being trusted with the credentials.
	for u in "$MIRA" "$TOBY"; do
		if user_in_group "$u" "$OPS_GROUP"; then
			pass "$u is an operator ($OPS_GROUP)"
		else
			fail "$u is not in $OPS_GROUP, so cannot read the service credentials they are expected to operate with"
		fi
	done
	if user_in_group "$NADIA" "$OPS_GROUP"; then
		fail "$NADIA is in $OPS_GROUP; she is on call for the service, which is not the same as being trusted with its credentials"
	else
		pass "$NADIA is not in $OPS_GROUP"
	fi
fi

# ... tiers appended by later tasks ...

if [[ $TIER == main ]]; then
	note "tier 4 is optional and was not run; try ./check.sh 4 when you want it"
fi

if finish; then exit 0; else exit 1; fi
