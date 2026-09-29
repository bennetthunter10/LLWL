#!/usr/bin/env bash
#
# tools/test-common.sh -- unit tests for exercises/lib/common.sh.
#
#     orb -m llwl-test -u root /tmp/llwl/tools/test-common.sh
#
# Runs as root because it creates throwaway accounts. It removes them again.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=../exercises/lib/common.sh
source "$HERE/../exercises/lib/common.sh"

U=llwltmpa
V=llwltmpb
D=/tmp/llwl-probe-dir

# can_user_login runs `sudo -i`, which opens a real login session, and that makes
# systemd start a per-user manager that outlives the command by a moment. userdel
# refuses ("currently used by process") until it has gone, so end the session
# and wait for the account to actually disappear. userdel can also exit non-zero
# after succeeding (no mail spool), so ask getent rather than trusting its status.
remove_user() {
	local u=$1 i
	user_exists "$u" || return 0
	loginctl terminate-user "$u" 2>/dev/null || true
	for i in {1..20}; do
		userdel --remove "$u" 2>/dev/null || true
		user_exists "$u" || return 0
		sleep 0.5
	done
	warn "could not remove test account $u"
}

cleanup() {
	remove_user "$U"
	remove_user "$V"
	groupdel llwltmpg 2>/dev/null || true
	rm -rf "$D"
}
trap cleanup EXIT
cleanup

groupadd llwltmpg
useradd --create-home --shell /bin/bash --groups llwltmpg "$U"
useradd --create-home --shell /usr/sbin/nologin "$V"
mkdir -p "$D"

ok() { if "$@"; then pass "$*"; else fail "$*"; fi; }
no() { if "$@"; then fail "NOT $*"; else pass "NOT $*"; fi; }

section "existence"
ok user_exists "$U"
no user_exists llwlnosuchuser

# Review Focus 3: every probe must be false-and-quiet for a missing account,
# never a sudo error and never a set -e kill.
section "a user that does not exist is simply 'cannot', not an error"
no can_user_read llwlnosuchuser /etc/hostname
no can_user_write llwlnosuchuser /tmp
no can_user_create llwlnosuchuser /tmp
no can_user_login llwlnosuchuser
no can_user_traverse llwlnosuchuser /tmp
stderr=$(can_user_read llwlnosuchuser /etc/hostname 2>&1 >/dev/null || true)
[[ -z $stderr ]] && pass "no stderr noise for a missing user" || fail "leaked to stderr: $stderr"

section "read, write, traverse, create"
chmod 0700 "$D"
chown "$U:$U" "$D"
ok can_user_create "$U" "$D"
no can_user_create "$V" "$D"
ok can_user_traverse "$U" "$D"
no can_user_traverse "$V" "$D"
printf 'x\n' >"$D/f"
chmod 0640 "$D/f"
chown "$U:llwltmpg" "$D/f"
ok can_user_read "$U" "$D/f"
ok can_user_write "$U" "$D/f"

section "setgid inheritance is observable"
chgrp llwltmpg "$D"
chmod 2770 "$D"
[[ $(new_file_group "$U" "$D") == llwltmpg ]] &&
	pass "new_file_group sees the setgid group" ||
	fail "new_file_group returned $(new_file_group "$U" "$D"), expected llwltmpg"

section "login"
ok can_user_login "$U"
no can_user_login "$V"          # nologin shell

# The spec flags this as unverified: does sudo's PAM account phase reject an
# expired account? If this test fails, can_user_login needs the account_expired
# fallback wired into it -- see Step 4.
usermod --expiredate 2020-01-01 "$U"
ok account_expired "$U"
no can_user_login "$U"
usermod --expiredate '' "$U"
no account_expired "$U"

section "uids are numbers"
[[ $(uid_of "$U") -gt 0 ]] && pass "uid_of returns a number" || fail "uid_of"
ok uid_has_name "$(uid_of "$U")"
no uid_has_name 61999

section "acl support detection"
if have_working_acls /tmp; then
	pass "have_working_acls says yes on /tmp"
	[[ -n $(acl_of /tmp) ]] && pass "acl_of prints something" || fail "acl_of empty"
else
	skip "no ACL support here -- tier 4 will skip, which is the point"
fi

finish
