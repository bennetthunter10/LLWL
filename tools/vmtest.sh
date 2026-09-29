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

step "1. plant"
VM_ROOT "$LAB_DIR/setup.sh" || fatal "setup.sh failed on a fresh machine"

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
VM bash -c "cd $LAB_DIR && ./check.sh" || fatal "check.sh still fails after bennett.sh"

step "4. re-planting a SOLVED lab must break it again"
VM_ROOT "$LAB_DIR/setup.sh" || fatal "setup.sh failed when re-run over a solved lab"
expect_check_failure "setup.sh did not reset a solved lab back to broken"

step "5. teardown must leave nothing behind"
VM_ROOT "$LAB_DIR/teardown.sh" || fatal "teardown.sh exited non-zero"
leftovers=$(VM bash -c "
	getent passwd | grep -E '^llwl' || true
	getent group  | grep -E '^llwl' || true
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
