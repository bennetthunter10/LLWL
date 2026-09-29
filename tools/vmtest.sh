#!/usr/bin/env bash
#
# tools/vmtest.sh -- run a lab's whole lifecycle in a disposable Ubuntu machine.
#
#     tools/vmtest.sh lab1          # prove lab1 still behaves
#     tools/vmtest.sh lab2 --keep   # leave the synced repo in the machine to poke at
#
# This is the repo's test suite. A lab is "well-formed" when all of these
# hold, which is exactly what this script asserts:
#
#   1. setup.sh plants cleanly on a fresh machine
#   2. check.sh FAILS afterwards -- a lab nobody can fail teaches nothing
#   3. solutions/bennett.sh takes it to all-green in one run
#   4. re-running setup.sh from the SOLVED state breaks it again
#   5. teardown.sh leaves no users, groups, units or paths behind
#   6. the learner's sudo still works afterwards
#
# Development happens on macOS, so none of this can run on the host.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
REPO=$(cd -- "$HERE/.." && pwd)
MACHINE=${LLWL_TEST_MACHINE:-llwl-test}
LAB=${1:-}
KEEP=${2:-}

[[ -n $LAB ]] || { echo "usage: $0 <lab-name> [--keep]" >&2; exit 2; }
[[ -d $REPO/exercises/$LAB ]] || { echo "no such lab: $LAB" >&2; exit 2; }

# Everything that runs inside the machine goes through here, so swapping
# OrbStack for lima or multipass means changing these two functions only.
#
# There is deliberately no "--" between the orb flags and the command: `orb run`
# rejects it as an unknown flag, and it stops parsing flags at the command anyway.
VM() { orb -m "$MACHINE" "$@"; }

# Root-requiring scripts are run as the machine's ordinary user and escalated
# with sudo, exactly as a learner does -- NOT with `orb -u root`. Run directly
# as root, SUDO_USER is unset, and labs read it to learn which human account to
# act on (lab1's solution adds $SUDO_USER to llwlops). The lab would then be
# unsolvable under test although it works fine for a real learner. Do not
# "simplify" this into `-u root`.
VM_ROOT() { orb -m "$MACHINE" sudo -- "$@"; }

fatal() { printf '\033[31mFAIL\033[0m  %s\n' "$1" >&2; exit 1; }
info() { printf '\033[33mNOTE\033[0m  %s\n' "$1"; }
step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

# Create the machine on first use. A real VM is required (not a container)
# because the labs need systemd as PID 1.
if ! orb list --quiet | grep --quiet --line-regexp --fixed-strings -- "$MACHINE"; then
	step "create $MACHINE"
	orb create ubuntu:24.04 "$MACHINE"
fi
[[ $(VM ps -p 1 -o comm=) == systemd ]] || fatal "PID 1 in $MACHINE is not systemd; the labs cannot run"

# The learner is not root, so the test account must not be either. OrbStack's
# default user has passwordless sudo, which matches a normal Ubuntu desktop.
#
# .git is dead weight; .superpowers and .worktrees are scratch directories that
# live inside the repo root and must not be shipped (or recursed into).
step "sync the repo into $MACHINE"
VM rm -rf /tmp/llwl
VM mkdir -p /tmp/llwl
tar --no-xattrs -C "$REPO" --exclude .git --exclude .superpowers --exclude .worktrees -cf - . | VM tar -C /tmp/llwl -xf -
VM chmod +x "/tmp/llwl/exercises/$LAB/setup.sh" \
	"/tmp/llwl/exercises/$LAB/check.sh" \
	"/tmp/llwl/exercises/$LAB/teardown.sh"
VM find "/tmp/llwl/exercises/$LAB/solutions" -name '*.sh' -exec chmod +x {} +

LAB_DIR=/tmp/llwl/exercises/$LAB

# Who owns which mess. teardown.sh promises to remove what setup.sh created and
# nothing else, so the harness measures exactly that: names present before and
# after setup.sh are the lab's; names that turn up later are the learner's (here,
# the reference solution's) and teardown deliberately leaves the groups among
# them alone. The pipelines run inside the machine because the host's cut is
# BSD and has no long flags.
#
# The set operations use grep, not comm: comm needs both inputs sorted in the
# same locale, and the VM's sort and the host's disagree about names like _ssh,
# which made an ordinary system group look like a leak. Do not "simplify" this
# back to comm.
db_names() { VM bash -c "getent $1 | cut --delimiter=: --fields=1"; }
only_in_second() { grep --invert-match --line-regexp --fixed-strings --file=<(printf '%s\n' "$1") <<<"$2" || true; }
in_both() { grep --line-regexp --fixed-strings --file=<(printf '%s\n' "$1") <<<"$2" || true; }

# A "nothing leaked" verdict is only worth something if the machine started with
# nothing to leak: anything llwl* that is already here would sit in the "before"
# snapshot, be classified as nobody's, and vanish from every assertion below.
# So establish that baseline rather than hope for it. This is start-of-run setup,
# and it hides nothing: a run that leaks still fails at the end of THAT run.
# (Cleaning after teardown would be different -- it would suppress the assertion.)
#
# Lab 2 leaves the learner's own groups behind by design, so a second run always
# starts with some. Every removal is printed. Everything here goes through
# orb -m "$MACHINE" (VM_ROOT), so it can only ever touch the disposable machine.
step "0. clear llwl* leftovers from earlier runs"
# The script below is single-quoted on purpose: $u and $g must expand inside the
# machine, in the loops that define them, not here on the host where they are unset.
# shellcheck disable=SC2016
removed=$(VM_ROOT bash -c '
	for u in $(getent passwd | cut --delimiter=: --fields=1 | grep "^llwl" || true); do
		loginctl terminate-user "$u" 2>/dev/null || true
		if userdel --force --remove "$u" >/dev/null 2>&1; then echo "removed user $u"; else echo "COULD NOT REMOVE user $u"; fi
	done
	for g in $(getent group | cut --delimiter=: --fields=1 | grep "^llwl" || true); do
		if groupdel "$g" >/dev/null 2>&1; then echo "removed group $g"; else echo "COULD NOT REMOVE group $g"; fi
	done
')
if [[ -n $removed ]]; then
	printf '%s\n' "$removed" | sed 's/^/  /'
else
	echo "  nothing to remove"
fi
! grep --quiet 'COULD NOT' <<<"$removed" || fatal "could not clear the machine; fix it by hand and re-run"

groups_pre=$(db_names group)
users_pre=$(db_names passwd)

step "1. plant"
VM_ROOT "$LAB_DIR/setup.sh" || fatal "setup.sh failed on a fresh machine"
groups_post_setup=$(db_names group)
users_post_setup=$(db_names passwd)
lab_groups=$(only_in_second "$groups_pre" "$groups_post_setup")

# Run check.sh and require that it failed *by reporting symptoms*. "Non-zero"
# alone is not enough: orb failing, a missing file, a syntax error (exit 2) or a
# crash (126, 127, a signal) are all non-zero too, and would let a broken lab or a
# broken machine pass the "must fail" steps for the wrong reason. The contract is
# exit 1 plus at least one FAIL line printed by the checker.
expect_check_failure() {
	local status=0
	check_output=$(VM bash -c "cd $LAB_DIR && ./check.sh" 2>&1) || status=$?
	printf '%s\n' "$check_output"
	((status != 0)) || fatal "$1"
	((status == 1)) || fatal "check.sh exited $status, not 1 -- it crashed or could not run rather than reporting symptoms"
	grep --quiet 'FAIL' <<<"$check_output" || fatal "check.sh exited 1 but printed no FAIL line -- it is not reporting symptoms"
}

step "2. check must FAIL on a freshly planted lab"
expect_check_failure "check.sh passed on a freshly planted lab -- nothing is actually broken"

step "3. the reference solution must take it to green"
VM_ROOT "$LAB_DIR/solutions/bennett.sh" || fatal "solutions/bennett.sh exited non-zero"
# What the solution created is the learner's. Accounts it made take their
# private group with them when deleted, so teardown owes a clean-up of those
# (see step 5); any other group is the learner's own design and is left alone.
learner_groups=$(only_in_second "$groups_post_setup" "$(db_names group)")
learner_users=$(only_in_second "$users_post_setup" "$(db_names passwd)")
VM bash -c "cd $LAB_DIR && ./check.sh" || fatal "check.sh still fails after bennett.sh"

step "4. re-planting a SOLVED lab must break it again"
VM_ROOT "$LAB_DIR/setup.sh" || fatal "setup.sh failed when re-run over a solved lab"
expect_check_failure "setup.sh did not reset a solved lab back to broken"

step "5. teardown must leave nothing behind"
VM_ROOT "$LAB_DIR/teardown.sh" || fatal "teardown.sh exited non-zero"

groups_final=$(db_names group)

# What teardown promises: no group that setup.sh created survives it.
lab_survivors=$(in_both "$lab_groups" "$groups_final")
if [[ -n $lab_survivors ]]; then
	printf '%s\n' "$lab_survivors"
	fatal "teardown left the above groups behind, and setup.sh created them"
fi

# The private group of an account the learner made goes with the account: userdel
# removes it, and teardown deletes the account. A survivor means teardown broke
# that, even though the group itself is not setup.sh's.
account_groups=$(in_both "$learner_users" "$groups_final")
if [[ -n $account_groups ]]; then
	printf '%s\n' "$account_groups"
	fatal "teardown left the private groups of accounts it deleted"
fi

# The backstop, and the assertion that cannot be evaded by classification: after
# teardown the machine may hold only what it held before, plus groups the
# learner made. Anything else is a leak, whoever's it is, and whichever step
# (including the step-4 re-plant) made it. Accounts get no allowance at all,
# since teardown deletes the ones the solution created too.
unexpected_groups=$(only_in_second "$(printf '%s\n%s\n' "$groups_pre" "$learner_groups")" "$groups_final")
if [[ -n $unexpected_groups ]]; then
	printf '%s\n' "$unexpected_groups"
	fatal "teardown left groups that were neither there before nor made by the learner"
fi
unexpected_users=$(only_in_second "$users_pre" "$(db_names passwd)")
if [[ -n $unexpected_users ]]; then
	printf '%s\n' "$unexpected_users"
	fatal "teardown left accounts that were not there before the lab"
fi

# Everything else the solution made is the learner's design. Report, never fail
# and never delete: a harness that tidies up in order to pass hides the day
# teardown stops removing something it does own.
kept=$(in_both "$learner_groups" "$groups_final")
if [[ -n $kept ]]; then
	info "left behind by design (learner-created groups; teardown does not delete them): $(tr '\n' ' ' <<<"$kept")"
fi

leftovers=$(VM bash -c "
	getent passwd | grep -E '^llwl' || true
	ls -d /srv/llwl* /etc/llwl* /var/log/llwl* /var/lib/llwl-* /home/llwl* 2>/dev/null || true
	ls /etc/systemd/system/llwl-* 2>/dev/null || true
	ls /etc/sudoers.d/llwl-* 2>/dev/null || true
")
if [[ -n ${leftovers//[[:space:]]/} ]]; then
	printf '%s\n' "$leftovers"
	fatal "teardown left the above behind"
fi

step "6. the learner's sudo still works"
VM sudo -n true || fatal "sudo is broken on the test machine after this lab ran"

[[ $KEEP == --keep ]] || VM rm -rf /tmp/llwl
printf '\n\033[32mPASS\033[0m  %s is well-formed\n' "$LAB"
