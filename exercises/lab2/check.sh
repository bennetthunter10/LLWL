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
# Tier 3 builds a command line from `command -v systemctl`. Without the tool
# that expands to nothing and the over-reach checks would pass by accident.
need_cmd systemctl
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
for p in "$SECRETS" "$PROJ_DIR" "$ALPHA" "$BETA"; do
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
	# Ask what they can read, not which group they are in: there is more than one
	# way to give somebody a group, and every one of them is a right answer.
	for u in "$MIRA" "$TOBY"; do
		if can_user_read "$u" "$SECRETS"; then
			pass "$u can read the service credentials"
		else
			fail "$u cannot read $SECRETS, so cannot operate the service they are expected to operate"
		fi
	done
	if can_user_read "$NADIA" "$SECRETS"; then
		fail "$NADIA can read $SECRETS; she is on call for the service, which is not the same as being trusted with its credentials"
	else
		pass "$NADIA cannot read the service credentials"
	fi
fi

# ---------------------------------------------------------------------------
# Tier 2 -- the project directories
# ---------------------------------------------------------------------------

if want_tier 2; then
	section "Tier 2 -- the project directories"

	# alpha belongs to Mira's team, beta to Toby's, and neither team has any
	# business in the other's tree.
	check_project_dir() {
		local dir=$1 owner=$2 stranger=$3
		if can_user_create "$owner" "$dir"; then
			pass "$owner can create files in $dir"
		else
			fail "$owner cannot create files in $dir ($(owner_of "$dir"), mode $(mode_of "$dir")); it is supposed to be the team's working directory"
			return
		fi

		# The point is not that today's file has the right group. It is that
		# tomorrow's will, without anybody remembering to fix it.
		local g
		g=$(new_file_group "$owner" "$dir" || true)
		if [[ -n ${g:-} && $g == "$(group_of "$dir")" ]]; then
			pass "files $owner creates in $dir inherit the directory's group ($g)"
		else
			fail "a file $owner creates in $dir comes out group ${g:-unknown}, but the directory's group is $(group_of "$dir"); in six months half this tree will be unreadable to the team"
		fi

		if can_user_list "$stranger" "$dir" || can_user_traverse "$stranger" "$dir"; then
			fail "$stranger can get into $dir (mode $(mode_of "$dir")); that is the other team's directory"
		else
			pass "$stranger is kept out of $dir"
		fi

		if can_user_list "$REPORT_USER" "$dir" || can_user_traverse "$REPORT_USER" "$dir"; then
			fail "the $REPORT_USER service account can get into $dir; a daemon has no business in a human's project directory"
		else
			pass "$REPORT_USER is kept out of $dir"
		fi
	}

	check_project_dir "$ALPHA" "$MIRA" "$TOBY"
	check_project_dir "$BETA" "$TOBY" "$MIRA"
fi

# ---------------------------------------------------------------------------
# Tier 3 -- delegate one power
# ---------------------------------------------------------------------------

if want_tier 3; then
	section "Tier 3 -- delegate one power"

	if sudo -n visudo --check --quiet 2>/dev/null; then
		pass "the sudo configuration parses"
	else
		fail "sudo's configuration does not parse; run 'sudo visudo -c' and fix it before anything else in this tier"
	fi

	# 0440 root:root is asserted because it is the mode the tooling enforces,
	# not because anything looser always breaks. Measured on Ubuntu 24.04
	# (sudo 1.9.15p5), because the folklore here is wrong in both directions:
	# sudo at RUNTIME still obeys a 0644 or 0664 drop-in, and it skips only the
	# ones it actively distrusts -- world-writable, or not owned by root -- and
	# it warns when it does ("is world writable", "is owned by uid N, should be
	# 0"). `visudo -c` is the strict one: it wants exactly 0440 root:root and
	# says "bad permissions, should be mode 0440" about anything else. So the
	# message below states both, and claims no mechanism neither of them has.
	if [[ -f $SUDOERS_DROPIN ]]; then
		m=$(mode_of "$SUDOERS_DROPIN")
		o=$(owner_of "$SUDOERS_DROPIN")
		if [[ $m == 440 && $o == root:root ]]; then
			pass "$SUDOERS_DROPIN is $o mode $m"
		else
			fail "$SUDOERS_DROPIN is $o mode $m; it has to be root:root mode 440. 'visudo -c' rejects any other mode, and sudo itself ignores a drop-in that is world-writable or not owned by root -- warning as it goes, in the noise above the prompt where nobody reads it"
		fi
	else
		fail "$SUDOERS_DROPIN is gone; the on-call rule has to live in that file so teardown knows it owns it"
	fi

	if user_exists "$NADIA"; then
		# The one power she is supposed to have. Behavioural: actually restart
		# the service as her, with no password, and confirm it really restarted.
		before=$(sudo -n systemctl show --property=ExecMainStartTimestampMonotonic --value "$REPORT_SVC" 2>/dev/null || echo 0)
		if as_user "$NADIA" sudo -n systemctl restart "$REPORT_SVC" >/dev/null 2>&1; then
			# The restart returns before the new process has stamped its start
			# time, so poll for a few seconds instead of guessing how long a
			# loaded machine needs. Normally the first look is enough.
			after=$before
			for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
				after=$(sudo -n systemctl show --property=ExecMainStartTimestampMonotonic --value "$REPORT_SVC" 2>/dev/null || echo 0)
				[[ $after -gt $before ]] && break
				sleep 0.25
			done
			if [[ $after -gt $before ]]; then
				pass "$NADIA can restart $REPORT_SVC without a password, and it really restarted"
			else
				fail "$NADIA's restart of $REPORT_SVC returned success but the service did not restart"
			fi
		else
			fail "$NADIA cannot restart $REPORT_SVC; that is the one thing she is on call to be able to do"
		fi

		# The one power she is not supposed to have. If she can stop this, she
		# can stop anything on the machine. On an unsolved lab this attempt
		# SUCCEEDS, so the checker puts the unit back afterwards whatever the
		# outcome: a checker that leaves the machine worse than it found it
		# would make every later check lie.
		if as_user "$NADIA" sudo -n systemctl stop "$AUDIT_SVC" >/dev/null 2>&1; then
			fail "$NADIA can stop $AUDIT_SVC, a service she has nothing to do with; the rule grants far more than one power"
		else
			pass "$NADIA cannot stop $AUDIT_SVC"
		fi
		sudo -n systemctl start "$AUDIT_SVC" >/dev/null 2>&1 || true

		# Masking is tested by asking the policy rather than by doing it: on a
		# unit whose file lives in /etc/systemd/system, systemctl mask refuses
		# ("File exists") even for root, so an attempt would prove nothing.
		# It would fail on the broken rule and the fixed rule alike, and the
		# check would pass every time. Do not turn this back into an attempt.
		if sudo_permits "$NADIA" "$(command -v systemctl)" mask "$AUDIT_SVC"; then
			fail "$NADIA could mask $AUDIT_SVC; masking a unit is how you make a service unstartable until somebody works out why"
		else
			pass "$NADIA cannot mask $AUDIT_SVC"
		fi

		# Ask the policy itself, without running anything. If the rule still
		# permits a command like this, it is still an "any systemctl" rule
		# however narrowly the restart case happens to behave.
		if sudo_permits "$NADIA" "$(command -v systemctl)" poweroff; then
			fail "the sudo policy would let $NADIA run 'systemctl poweroff' as root; the rule is still not scoped to one command"
		else
			pass "the sudo policy does not let $NADIA run arbitrary systemctl subcommands"
		fi

		if can_user_read "$NADIA" "$SECRETS"; then
			fail "$NADIA can read $SECRETS; being on call for a service is not the same as being trusted with its credentials"
		else
			pass "$NADIA cannot read $SECRETS"
		fi
	else
		fail "$NADIA does not exist, so none of tier 3 can be tested; finish tier 1 first"
	fi

	if systemctl is-active --quiet "$AUDIT_SVC"; then
		pass "$AUDIT_SVC is running"
	else
		fail "$AUDIT_SVC is not running; if you stopped it while experimenting, start it again"
	fi
fi

# ---------------------------------------------------------------------------
# Tier 4 -- optional: when mode bits run out
# ---------------------------------------------------------------------------

if want_tier 4; then
	section "Tier 4 (optional) -- when mode bits run out"

	# Missing tooling is not the learner's mistake, so this skips rather than
	# fails. The two causes need different advice, so tell them apart.
	if ! have_working_acls "$PROJ_DIR"; then
		skip "no working ACL support here"
		if ! command -v setfacl >/dev/null 2>&1; then
			note "setfacl is not installed:  sudo apt install acl"
		else
			note "$PROJ_DIR is on a filesystem mounted without ACL support; check 'findmnt -no OPTIONS -T $PROJ_DIR'"
		fi
	else
		# Every check asks what somebody can DO. Nothing here looks at a group
		# name or at a getfacl entry for a named group: the learner chose their
		# own groups, and a check that looked for them would fail a right answer.
		if can_user_create "$MIRA" "$SHARED"; then
			pass "$MIRA can add to $SHARED"
		else
			fail "$MIRA cannot add to $SHARED; alpha maintains the shared handbook"
		fi

		# The whole point of tier 4 is files that do not exist yet. Create one
		# now, as Mira, and see whether Toby can read it -- a one-off setfacl
		# over what was already there will not survive this.
		#
		# The umask is the whole trick. Under the usual 022 the new file is 0644
		# and Toby reads it through "other", ACL or no ACL, so the probe would
		# pass for the wrong reason. With 077 the file is 0600 unless a default
		# ACL on the directory overrides the umask, which is exactly what a
		# default ACL does and nothing else here can.
		probe=$SHARED/.llwl-inherit-probe-$$
		if sudo -n -u "$MIRA" bash -c 'umask 077; touch -- "$1"' _ "$probe" 2>/dev/null; then
			if can_user_read "$TOBY" "$probe"; then
				pass "a file $MIRA creates in $SHARED today is readable by $TOBY"
			else
				fail "$TOBY cannot read a file $MIRA just created in $SHARED; whatever you set applies to the files that were already there, not to the ones that arrive tomorrow"
			fi
			if can_user_write "$TOBY" "$probe"; then
				fail "$TOBY can write a file in $SHARED; beta reads the handbook, alpha maintains it"
			else
				pass "$TOBY cannot write in $SHARED"
			fi
			sudo -n rm -f -- "$probe" 2>/dev/null || true
		else
			fail "$MIRA could not create a probe file in $SHARED"
		fi

		if can_user_list "$REPORT_USER" "$SHARED" || can_user_traverse "$REPORT_USER" "$SHARED"; then
			fail "the $REPORT_USER service account can get into $SHARED"
		else
			pass "$REPORT_USER is kept out of $SHARED"
		fi

		# The one place this looks at the ACL text itself, and only for the fact
		# that a default ACL exists, never for who is named in it.
		if acl_of "$SHARED" | grep -q '^default:'; then
			pass "$SHARED carries a default ACL, so new files inherit it"
		else
			fail "$SHARED has no default ACL; nothing makes tomorrow's files come out right"
		fi
	fi
fi

if [[ $TIER == main ]]; then
	note "tier 4 is optional and was not run; try ./check.sh 4 when you want it"
fi

if finish; then exit 0; else exit 1; fi
