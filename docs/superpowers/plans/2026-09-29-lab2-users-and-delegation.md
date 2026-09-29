# LLWL Lab 2 — Users, Groups, Project Directories, Delegated Sudo — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `exercises/lab2/` — a four-script lab in which the learner creates and repairs user
accounts, designs a group structure, builds shared project directories, and cuts an over-broad
`sudo` rule down to the one power it was meant to grant.

**Architecture:** Lab 2 copies the shape of `lab1` exactly: `setup.sh` (root, plants, idempotent,
only creates new paths, writes a manifest), `check.sh` (the learner, symptoms not fixes, tiered),
`teardown.sh` (root, manifest-driven, allow-list checked), `solutions/bennett.sh` (root, the
reference fix). Shared helpers go in `exercises/lib/common.sh`. Unlike lab 1, almost every check is
a **capability probe** — "can this account actually do this thing" — because the learner invents
his own group names and only capabilities are stable.

**Tech Stack:** Bash (`#!/usr/bin/env bash`, `set -euo pipefail`), systemd, `useradd`/`usermod`/
`chage`, `visudo`, `setfacl`/`getfacl` (optional tier), and an OrbStack Ubuntu machine as the test
environment. Development happens on macOS, so **nothing in this repo can be tested on the host** —
Task 1 exists to solve that before anything else is written.

**Spec:** `docs/superpowers/specs/2026-08-30-lab2-users-and-delegation-design.md`

## Global Constraints

- Every script: `#!/usr/bin/env bash`, `set -euo pipefail`, sources `../lib/common.sh`, uses long
  flags (`--gid`, not `-g`).
- These scripts are teaching material. Comment the *why*, not the what. Keep them boring and
  readable; the learner will read them.
- `setup.sh` only ever **creates** new paths. It never modifies a file that was already on the
  system. Specifically forbidden: `/etc/sudoers`, any pre-existing `/etc/sudoers.d/*`,
  `/etc/login.defs`, `/etc/skel`, `/etc/passwd` entries it did not create.
- `setup.sh` is idempotent: re-running it resets the lab to its planted-broken state, including
  from a fully solved state.
- `setup.sh` **must never leave an invalid or non-`0440` file in `/etc/sudoers.d/`.** Write to a
  temp file, `visudo --check --file=` it, and only then `install -m 0440 -o root -g root` into
  place. A rejected sudoers file can cost the learner `sudo` entirely on his own machine.
- `check.sh` runs as the learner (`refuse_root`) and escalates internally with `sudo -n`/`sudo -v`,
  exactly as `lab1/check.sh` already does.
- `teardown.sh` checks every path against an allow-list before `rm -rf`, and every account against
  a name+home allow-list before `userdel --remove`.
- Fixed names the lab owns: users `llwlmira`, `llwltoby`, `llwlnadia`, `llwlreport`; group
  `llwlops`; units `llwl-report.service`, `llwl-audit.service`; paths `/srv/llwl-report`,
  `/etc/llwl-report`, `/var/log/llwl-report`, `/srv/llwl-projects`, `/etc/sudoers.d/llwl-oncall`.
- **Group names the learner invents are never checked by name and never deleted by teardown.**
- Manifest lives at `/var/lib/llwl-labs/lab2.manifest`.
- Commit after every task. Branch: `lab2-bennett`.

## Review Focus

Five failure modes the spec implies that no task's happy path exercises. Each has a test assigned
to the task that owns the code.

1. **Re-planting over a solved lab.** `setup.sh` on a machine where the learner already fixed
   everything must return it to the broken state — not silently no-op because the users already
   exist. Test in Task 3.
2. **`teardown.sh` with no manifest, or on a machine that was never planted.** Must warn and
   no-op, never delete something outside the allow-list. Test in Task 3.
3. **`check.sh` run before `setup.sh`, or mid-solve when `llwlnadia` does not exist yet.** Every
   capability probe must return false cleanly instead of emitting `sudo: unknown user` to stderr
   or killing the script under `set -e`. Test in Task 2.
4. **The learner's own `sudo` is password-required on one machine and `NOPASSWD` on another**, and
   may be broken outright. `check.sh`'s preflight must work in all three, and say something useful
   in the third. Test in Task 2.
5. **`setfacl` not installed, or the filesystem mounted without ACL support.** Tier 4 must `skip`
   with an actionable message, never `fail`. Test in Task 7.

---

## File Structure

| File | Responsibility |
|---|---|
| `tools/vmtest.sh` | **new.** Dev-only. Runs a lab's full lifecycle inside a disposable Ubuntu machine and asserts the red→green→clean cycle. The repo's test suite. |
| `tools/test-common.sh` | **new.** Dev-only. Unit tests for the `lib/common.sh` helpers, run inside the VM. |
| `exercises/lib/common.sh` | **modify.** Add capability probes and account-inspection helpers. |
| `exercises/lab2/setup.sh` | **new.** Plants two services, two broken accounts, the project tree, the sudoers drop-in; writes the manifest. |
| `exercises/lab2/check.sh` | **new.** Four tiers; tiers 1–3 gate, tier 4 optional. |
| `exercises/lab2/teardown.sh` | **new.** Manifest-driven removal with a stricter allow-list than lab 1's. |
| `exercises/lab2/solutions/bennett.sh` | **new.** Reference fix, all-green in one run. |
| `exercises/lab2/README.md` | **new.** The learner-facing lab. |
| `README.md` | **modify.** Ladder table → eight rows. |
| `exercises/README.md` | **modify.** `home` manifest kind; note that `check.sh` asks for sudo. |

---

## Task 1: The test harness

Nothing else in this plan can be verified without it. Development is on macOS; the labs are Ubuntu
and systemd. Lab 1 is already known-good, so it is the fixture that proves the harness works.

**Files:**
- Create: `tools/vmtest.sh`
- Create: `tools/README.md`

**Interfaces:**
- Consumes: nothing.
- Produces: `tools/vmtest.sh <lab-name> [--keep]` — creates or reuses an OrbStack Ubuntu machine
  named `llwl-test`, syncs the repo into it, and runs the lifecycle below. Exit 0 = the lab is
  well-formed. Every later task's verification step calls this.

- [ ] **Step 1: Stand up the machine and confirm systemd is PID 1**

The labs need real systemd, so a container will not do. OrbStack Linux machines boot a real VM.

```bash
orb create ubuntu:24.04 llwl-test
orb -m llwl-test -- ps -p 1 -o comm=
```

Expected: `systemd`. If OrbStack is unavailable or PID 1 is not systemd, fall back to
`limactl start template://ubuntu-lts` or `multipass launch 24.04 --name llwl-test` and adjust the
`VM` wrapper in Step 2 — everything downstream goes through that one function.

- [ ] **Step 2: Write the harness**

```bash
#!/usr/bin/env bash
#
# tools/vmtest.sh -- run a lab's whole lifecycle in a disposable Ubuntu machine.
#
#     tools/vmtest.sh lab1          # prove lab1 still behaves
#     tools/vmtest.sh lab2 --keep   # leave the machine up to poke at afterwards
#
# This is the repo's test suite. A lab is "well-formed" when all five of these
# hold, which is exactly what this script asserts:
#
#   1. setup.sh plants cleanly on a fresh machine
#   2. check.sh FAILS afterwards -- a lab nobody can fail teaches nothing
#   3. solutions/bennett.sh takes it to all-green in one run
#   4. re-running setup.sh from the SOLVED state breaks it again
#   5. teardown.sh leaves no users, groups, units or paths behind
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
VM() { orb -m "$MACHINE" -- "$@"; }
VM_ROOT() { orb -m "$MACHINE" -u root -- "$@"; }

fatal() { printf '\033[31mFAIL\033[0m  %s\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

# The learner is not root, so the test account must not be either. OrbStack's
# default user has passwordless sudo, which matches a normal Ubuntu desktop.
step "sync the repo into $MACHINE"
VM rm -rf /tmp/llwl
VM mkdir -p /tmp/llwl
tar -C "$REPO" --exclude .git -cf - . | VM tar -C /tmp/llwl -xf -
VM chmod +x "/tmp/llwl/exercises/$LAB/setup.sh" \
	"/tmp/llwl/exercises/$LAB/check.sh" \
	"/tmp/llwl/exercises/$LAB/teardown.sh"
VM find "/tmp/llwl/exercises/$LAB/solutions" -name '*.sh' -exec chmod +x {} +

LAB_DIR=/tmp/llwl/exercises/$LAB

step "1. plant"
VM_ROOT "$LAB_DIR/setup.sh" || fatal "setup.sh failed on a fresh machine"

step "2. check must FAIL on a freshly planted lab"
if VM bash -c "cd $LAB_DIR && ./check.sh" >/tmp/llwl-check-1.log 2>&1; then
	cat /tmp/llwl-check-1.log
	fatal "check.sh passed on a freshly planted lab -- nothing is actually broken"
fi

step "3. the reference solution must take it to green"
VM_ROOT "$LAB_DIR/solutions/bennett.sh" || fatal "solutions/bennett.sh exited non-zero"
VM bash -c "cd $LAB_DIR && ./check.sh" || fatal "check.sh still fails after bennett.sh"

step "4. re-planting a SOLVED lab must break it again"
VM_ROOT "$LAB_DIR/setup.sh" || fatal "setup.sh failed when re-run over a solved lab"
if VM bash -c "cd $LAB_DIR && ./check.sh" >/dev/null 2>&1; then
	fatal "setup.sh did not reset a solved lab back to broken"
fi

step "5. teardown must leave nothing behind"
VM_ROOT "$LAB_DIR/teardown.sh" || fatal "teardown.sh exited non-zero"
leftovers=$(VM bash -c "
	getent passwd | grep -E '^llwl' || true
	getent group  | grep -E '^llwl' || true
	ls -d /srv/llwl* /etc/llwl* /var/log/llwl* /var/lib/llwl-* 2>/dev/null || true
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
```

- [ ] **Step 3: Run it against lab 1 and watch it pass**

Run: `chmod +x tools/vmtest.sh && tools/vmtest.sh lab1`
Expected: every step green, ending `PASS  lab1 is well-formed`.

If lab 1 fails step 2 or 3, the harness is wrong, not lab 1 — lab 1 is known-good. Debug the
harness with `tools/vmtest.sh lab1 --keep` and `orb -m llwl-test` to get a shell.

- [ ] **Step 4: Prove the harness can actually fail**

A test suite that cannot go red is not a test suite.

```bash
orb -m llwl-test -u root -- chmod +x /srv/llwl-api/run.sh   # pre-fix one tier-1 defect
```

Then temporarily edit the harness's step 2 to run `./check.sh 1` and confirm it still reports
FAIL for the remaining defects but not for `run.sh`. Revert the edit.

- [ ] **Step 5: Write `tools/README.md`**

```markdown
# tools/

Development tooling for people *writing* labs. Learners never need anything in here.

## vmtest.sh

The repo's test suite. Labs are Ubuntu and systemd; development is usually not, so every lab is
verified inside a disposable Ubuntu machine rather than on your laptop.

    tools/vmtest.sh lab1            # assert lab1 is well-formed
    tools/vmtest.sh lab2 --keep     # ... and leave the machine up to poke at

A lab is well-formed when it plants cleanly, fails its own checker afterwards, goes green under
`solutions/bennett.sh`, breaks again when re-planted from the solved state, and tears down without
a trace. Run it before opening a PR that adds or changes a lab.

The machine is created on demand and named `llwl-test`. Delete it with `orb delete llwl-test`.

## test-common.sh

Unit tests for `exercises/lib/common.sh`. Run inside the machine:

    orb -m llwl-test -u root -- /tmp/llwl/tools/test-common.sh
```

- [ ] **Step 6: Commit**

```bash
git add tools/vmtest.sh tools/README.md
git commit -m "Add tools/vmtest.sh, the lab test harness

Labs are Ubuntu and systemd and development is on macOS, so a lab can
only really be verified inside a disposable machine. Asserts the full
red-green-reset-clean cycle, validated against lab1 as a known-good
fixture."
```

---

## Task 2: Capability probes in `lib/common.sh`

Lab 2 checks what accounts can *do*, because the learner invents his own group names. These
helpers are that vocabulary, and Review Focus items 3 and 4 live here.

**Files:**
- Modify: `exercises/lib/common.sh` (append a new section after "Inspecting permissions")
- Create: `tools/test-common.sh`

**Interfaces:**
- Consumes: `tools/vmtest.sh` from Task 1 (for the machine); existing `die`/`warn` from `common.sh`.
- Produces, all returning 0 for true and 1 for false, all safe to call for a user that does not
  exist:
  `user_exists <user>`, `as_user <user> <cmd...>`, `can_user_read <user> <path>`,
  `can_user_write <user> <path>`, `can_user_traverse <user> <dir>`, `can_user_list <user> <dir>`,
  `can_user_create <user> <dir>`, `can_user_login <user>`, `new_file_group <user> <dir>` (prints a
  group name), `login_shell_of <user>` (prints a path), `account_expired <user>`,
  `uid_of <user>` (prints a number), `uid_has_name <uid>`,
  `sudo_permits <user> <cmd...>`, `acl_of <path>` (prints `getfacl` output),
  `have_working_acls <path>`.

- [ ] **Step 1: Write the failing unit tests**

Create `tools/test-common.sh`. It runs as root inside the machine, builds its own fixtures, and
cleans up after itself.

```bash
#!/usr/bin/env bash
#
# tools/test-common.sh -- unit tests for exercises/lib/common.sh.
#
#     orb -m llwl-test -u root -- /tmp/llwl/tools/test-common.sh
#
# Runs as root because it creates throwaway accounts. It removes them again.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=../exercises/lib/common.sh
source "$HERE/../exercises/lib/common.sh"

U=llwltmpa
V=llwltmpb
D=/tmp/llwl-probe-dir

cleanup() {
	userdel --remove "$U" 2>/dev/null || true
	userdel --remove "$V" 2>/dev/null || true
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
```

- [ ] **Step 2: Run it and watch it fail**

Run:
```bash
tools/vmtest.sh lab1 --keep >/dev/null   # gets the repo into the machine
orb -m llwl-test -u root -- /tmp/llwl/tools/test-common.sh
```
Expected: FAIL, `user_exists: command not found` or similar — none of the helpers exist yet.

- [ ] **Step 3: Implement the helpers**

Append to `exercises/lib/common.sh`:

```bash
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
# ---------------------------------------------------------------------------

user_exists() { getent passwd "$1" >/dev/null 2>&1; }

# Run a command as somebody else. Needs a sudo ticket already in hand, which is
# why check.sh does `sudo -v` in its preflight.
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
		g=$(stat -c '%G' -- "$probe" 2>/dev/null || true)
	fi
	sudo -n rm -f -- "$probe" 2>/dev/null || true
	[[ -n $g ]] || return 1
	printf '%s\n' "$g"
}

login_shell_of() { getent passwd "$1" | cut -d: -f7; }

# Field 8 of /etc/shadow is the expiry date in days since 1970-01-01. Empty
# means "never". This is the only place an expired account is visible, which is
# exactly why an expired account is such a confusing thing to be handed.
account_expired() {
	local exp today
	user_exists "$1" || return 1
	exp=$(sudo -n getent shadow "$1" 2>/dev/null | cut -d: -f8)
	[[ -n $exp ]] || return 1
	today=$(($(date +%s) / 86400))
	((exp < today))
}

# Behavioural: actually try to start a login shell as them.
can_user_login() {
	local u=$1
	user_exists "$u" || return 1
	! account_expired "$u" || return 1
	sudo -n -u "$u" -i true >/dev/null 2>&1
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
```

Note on `can_user_login`: it checks expiry explicitly *before* the behavioural attempt, rather
than trusting `sudo -i` to enforce it. Step 4 decides whether that belt-and-braces is needed.

- [ ] **Step 4: Settle the expiry question the spec flagged**

The spec says to verify whether `sudo -u X -i true` alone rejects an expired account. Find out:

```bash
orb -m llwl-test -u root -- bash -c '
  useradd --create-home --shell /bin/bash llwlexptest
  usermod --expiredate 2020-01-01 llwlexptest
  if sudo -n -u llwlexptest -i true; then echo "SUDO IGNORES EXPIRY"; else echo "sudo enforces expiry"; fi
  userdel --remove llwlexptest'
```

Either answer is fine — the implementation above already handles both, because `account_expired`
gates the behavioural attempt. Record the answer in a comment above `can_user_login` so nobody
removes the `account_expired` guard later thinking it is redundant.

- [ ] **Step 5: Run the unit tests to green**

Run:
```bash
tar -C . --exclude .git -cf - . | orb -m llwl-test -- tar -C /tmp/llwl -xf -
orb -m llwl-test -u root -- /tmp/llwl/tools/test-common.sh
```
Expected: `N passed, 0 failed`.

- [ ] **Step 6: Review Focus 4 — the three sudo situations**

Confirm the probes behave on a machine where the calling user needs a password. In the machine:

```bash
orb -m llwl-test -u root -- bash -c 'echo "%sudo ALL=(ALL:ALL) ALL" > /etc/sudoers.d/99-llwl-pwtest && chmod 0440 /etc/sudoers.d/99-llwl-pwtest'
orb -m llwl-test -- bash -c 'sudo -k; sudo -n true'   # expect failure, no hang
orb -m llwl-test -u root -- rm -f /etc/sudoers.d/99-llwl-pwtest
```

Expected: `sudo -n true` fails immediately rather than hanging on a prompt. This is why every
helper uses `-n` and why `check.sh` calls `sudo -v` once up front — record that reasoning in the
comment block. Then run `tools/vmtest.sh lab1` again to confirm lab 1 still passes with the
enlarged `common.sh`.

- [ ] **Step 7: Commit**

```bash
git add exercises/lib/common.sh tools/test-common.sh tools/README.md
git commit -m "Add capability probes to lib/common.sh

Lab 2 checks what accounts can do rather than what mode a file is,
because the learner invents his own group names and only capabilities
are stable. Every probe is false-and-quiet for an account that does not
exist yet, since the checker runs while he is halfway through creating
them."
```

---

## Task 3: Lab 2 scaffolding — `setup.sh` services and `teardown.sh`

The safety-critical pair, built and reviewed before a single defect is planted. Review Focus 1 and
2 live here.

**Files:**
- Create: `exercises/lab2/setup.sh`
- Create: `exercises/lab2/teardown.sh`
- Create: `exercises/lab2/solutions/bennett.sh` (skeleton that exits 0)
- Create: `exercises/lab2/check.sh` (skeleton: preflight and tier dispatch only)

**Interfaces:**
- Consumes: `lib/common.sh` helpers from Task 2; `tools/vmtest.sh` from Task 1.
- Produces: `/var/lib/llwl-labs/lab2.manifest` with kinds `unit`, `path`, `user`, `group`, `home`,
  `note`; both units active; the shell variables every later task extends
  (`REPORT_SVC=llwl-report`, `AUDIT_SVC=llwl-audit`, `PROJ_DIR=/srv/llwl-projects`,
  `SUDOERS_DROPIN=/etc/sudoers.d/llwl-oncall`).

- [ ] **Step 1: Write the lifecycle test first**

There is no new test file — `tools/vmtest.sh lab2` *is* the test, and right now it must fail at
step 2 (a lab with nothing broken in it). That is the red state for this task, and it is the
correct red state: the harness is asserting that a lab with no defects is not a lab.

Run: `tools/vmtest.sh lab2`
Expected: fails at step 1 with "no such lab: lab2".

- [ ] **Step 2: Write `setup.sh`, services and manifest only**

```bash
#!/usr/bin/env bash
#
# LLWL lab 2 -- setup
#
# Plants the state of a team that just grew: two services, two accounts that
# were created carelessly, a project directory nobody has organised, and a sudo
# rule the previous admin left behind.
#
#     sudo ./setup.sh
#
# Same two promises as lab 1:
#   1. It only ever CREATES new paths and accounts. It never modifies anything
#      that was already on your system -- in particular it never touches
#      /etc/sudoers or any drop-in it did not write.
#   2. Everything is recorded in /var/lib/llwl-labs/lab2.manifest and removed
#      completely by ./teardown.sh
#
# Idempotent: re-run it at any time, including from a fully solved lab, to put
# the machine back in its original broken state.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=../lib/common.sh
source "$HERE/../lib/common.sh"

REPORT_SVC=llwl-report
AUDIT_SVC=llwl-audit
REPORT_USER=llwlreport
OPS_GROUP=llwlops

APP_DIR=/srv/llwl-report
CONF_DIR=/etc/llwl-report
LOG_DIR=/var/log/llwl-report
PROJ_DIR=/srv/llwl-projects
REPORT_UNIT=/etc/systemd/system/$REPORT_SVC.service
AUDIT_UNIT=/etc/systemd/system/$AUDIT_SVC.service
SUDOERS_DROPIN=/etc/sudoers.d/llwl-oncall

LAB_STATE=/var/lib/llwl-labs
MANIFEST=$LAB_STATE/lab2.manifest

need_linux
need_root
need_cmd systemctl
need_cmd useradd
need_cmd usermod
need_cmd chage
need_cmd visudo

# ---------------------------------------------------------------------------
# 1. Stop anything from a previous planting, so a re-run is a true reset.
# ---------------------------------------------------------------------------

for u in "$REPORT_SVC" "$AUDIT_SVC"; do
	systemctl is-active --quiet "$u" 2>/dev/null && systemctl stop "$u"
done

# ---------------------------------------------------------------------------
# 2. Service identity. llwlops carries over from lab 1: the humans who operate
#    a service. In this lab it is the group allowed to read the credentials.
# ---------------------------------------------------------------------------

getent group "$OPS_GROUP" >/dev/null || groupadd --system "$OPS_GROUP"
getent passwd "$REPORT_USER" >/dev/null || useradd \
	--system \
	--no-create-home \
	--home-dir /nonexistent \
	--shell /usr/sbin/nologin \
	--comment "LLWL lab 2 reporting service account" \
	"$REPORT_USER"

# ---------------------------------------------------------------------------
# 3. The reporting service. Nothing is wrong with it -- this lab is not about
#    fixing a service, it is about who is allowed to restart one.
# ---------------------------------------------------------------------------

mkdir -p "$APP_DIR" "$CONF_DIR" "$LOG_DIR" "$LAB_STATE"

cat >"$CONF_DIR/report.conf" <<'CONF'
# /etc/llwl-report/report.conf -- runtime configuration for llwl-report.
SERVICE_NAME="llwl-report"
TICK_SECONDS=5
CONF

cat >"$CONF_DIR/secrets.env" <<'SECRETS'
# /etc/llwl-report/secrets.env -- credentials for llwl-report.
# Readable by root and by the operators group. Being on call is not the same
# thing as being trusted with these.
REPORT_TOKEN="llwl-7b21e0c4a9-DEMO-NOT-A-REAL-SECRET"
SECRETS

cat >"$APP_DIR/run.sh" <<'RUNSH'
#!/usr/bin/env bash
# /srv/llwl-report/run.sh -- the llwl-report "daemon". Ticks, and says so.
set -euo pipefail
. /etc/llwl-report/report.conf
LOG=/var/log/llwl-report/report.log
echo "llwl-report: starting as $(id -un)"
while :; do
	printf '%s %s tick\n' "$(date -Is)" "${SERVICE_NAME:-llwl-report}" >>"$LOG"
	sleep "${TICK_SECONDS:-5}"
done
RUNSH

cat >"$REPORT_UNIT" <<UNITFILE
[Unit]
Description=LLWL practice reporting service (lab 2)
After=network.target

[Service]
Type=simple
User=$REPORT_USER
Group=$REPORT_USER
ExecStart=$APP_DIR/run.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNITFILE

cat >"$AUDIT_UNIT" <<'UNITFILE'
[Unit]
Description=LLWL practice compliance agent (lab 2)

# This unit does nothing, on purpose. It exists so that the lab has a service
# that the on-call account is NOT supposed to be able to touch -- which means
# you can prove an over-broad sudo rule is over-broad without going anywhere
# near a service that matters.

[Service]
Type=simple
ExecStart=/usr/bin/sleep infinity
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNITFILE

chown root:root "$APP_DIR/run.sh" "$CONF_DIR/report.conf" "$CONF_DIR/secrets.env"
chmod 0755 "$APP_DIR" "$CONF_DIR"
chmod 0755 "$APP_DIR/run.sh"
chmod 0644 "$CONF_DIR/report.conf"
chown root:"$OPS_GROUP" "$CONF_DIR/secrets.env"
chmod 0640 "$CONF_DIR/secrets.env"
chown "$REPORT_USER:$REPORT_USER" "$LOG_DIR"
chmod 0750 "$LOG_DIR"
chown root:root "$REPORT_UNIT" "$AUDIT_UNIT"
chmod 0644 "$REPORT_UNIT" "$AUDIT_UNIT"

systemctl daemon-reload
systemctl enable --now "$REPORT_SVC" >/dev/null
systemctl enable --now "$AUDIT_SVC" >/dev/null

# ---------------------------------------------------------------------------
# 4. Manifest. Everything this lab OWNS, whether setup.sh created it or the
#    learner is expected to. teardown.sh checks each entry for existence, so
#    listing llwlnadia here is how she gets cleaned up even though she is the
#    learner's to create.
# ---------------------------------------------------------------------------

write_manifest() {
	cat >"$MANIFEST" <<MANIFESTEOF
# LLWL lab 2 manifest -- every object this lab owns, in creation order.
# teardown.sh removes these in reverse. Kinds: path, unit, user, group, home, note.
unit $REPORT_SVC.service
unit $AUDIT_SVC.service
path $REPORT_UNIT
path $AUDIT_UNIT
path $SUDOERS_DROPIN
path $APP_DIR
path $CONF_DIR
path $LOG_DIR
path $PROJ_DIR
home /home/llwlmira
home /home/llwltoby
home /home/llwlnadia
user llwlmira
user llwltoby
user llwlnadia
user $REPORT_USER
group $OPS_GROUP
MANIFESTEOF
	chmod 0644 "$MANIFEST"
}
write_manifest
```

Leave the briefing block out for now; Task 8 writes it alongside the README.

- [ ] **Step 3: Write `teardown.sh`**

```bash
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
# clear two independent gates before it is touched: its NAME must look like a
# lab account, and its HOME must be where a lab account's home belongs. If
# either is off, the account goes but the directory stays, loudly.
#
# Groups are different again. The learner invents his own group names in this
# lab, so they are not in the manifest -- and this script will not go guessing
# at groups by pattern and deleting them as root. It prints them for a human.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=../lib/common.sh
source "$HERE/../lib/common.sh"

LAB_STATE=/var/lib/llwl-labs
MANIFEST=$LAB_STATE/lab2.manifest

ALLOWED=(
	/srv/llwl-report
	/etc/llwl-report
	/var/log/llwl-report
	/srv/llwl-projects
	/etc/systemd/system/llwl-report.service
	/etc/systemd/system/llwl-audit.service
	/etc/sudoers.d/llwl-oncall
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

# Two gates, both must pass, before any home directory is deleted.
home_is_safe_to_delete() {
	local user=$1 home=$2
	[[ $user =~ ^llwl[a-z]+$ ]] || return 1
	[[ $home == /home/llwl* && $home != *..* ]] || return 1
	[[ -d $home ]] || return 1
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
	units=(llwl-report.service llwl-audit.service)
	paths=("${ALLOWED[@]}")
	users=(llwlmira llwltoby llwlnadia llwlreport)
	groups=(llwlops)
	homes=(/home/llwlmira /home/llwltoby /home/llwlnadia)
fi

for u in "${units[@]}"; do
	systemctl is-active --quiet "$u" 2>/dev/null && { info "stopping $u"; systemctl stop "$u"; }
	systemctl is-enabled --quiet "$u" 2>/dev/null && { info "disabling $u"; systemctl disable "$u" >/dev/null; }
done

for ((i = ${#paths[@]} - 1; i >= 0; i--)); do
	p=${paths[i]}
	if ! is_allowed "$p"; then
		warn "refusing to delete $p -- not on this lab's allow-list"
		continue
	fi
	[[ -e $p ]] && { info "removing $p"; rm -rf -- "$p"; }
done

systemctl daemon-reload
for u in "${units[@]}"; do systemctl reset-failed "$u" 2>/dev/null || true; done

# Accounts. Home directories are matched to their owner from the manifest, so a
# stale `home` line cannot cause an unrelated directory to be deleted.
for u in "${users[@]}"; do
	getent passwd "$u" >/dev/null || continue
	h=$(getent passwd "$u" | cut -d: -f6)
	if home_is_safe_to_delete "$u" "$h"; then
		info "deleting user $u and its home $h"
		userdel --remove "$u"
	else
		info "deleting user $u"
		userdel "$u"
		[[ -d $h && $h != /nonexistent ]] &&
			warn "left $h in place -- it does not look like a lab home directory; remove it yourself if you are sure"
	fi
done

# Anything listed as a lab home that survived the loop above is now orphaned.
for h in "${homes[@]}"; do
	[[ -d $h ]] || continue
	warn "$h still exists and no lab account owns it -- review and remove it by hand"
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
```

- [ ] **Step 4: Write the `check.sh` skeleton**

```bash
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

for p in "$SECRETS" "$PROJ_DIR" "$SUDOERS_DROPIN"; do
	[[ -e $p ]] || die "$p is missing -- plant (or re-plant) the lab with:  sudo $HERE/setup.sh"
done

# Everything here has to ask what OTHER accounts can do, and that needs root.
# One ticket up front, so you are asked once rather than forty times.
if ! sudo -n true 2>/dev/null; then
	info "This checker has to test what other people's accounts can do, so it needs sudo once."
	sudo -v || die "no sudo available -- if you have just edited a sudoers file, check it with: sudo visudo -c"
fi

# ... tiers appended by later tasks ...

if [[ $TIER == main ]]; then
	note "tier 4 is optional and was not run; try ./check.sh 4 when you want it"
fi

if finish; then exit 0; else exit 1; fi
```

- [ ] **Step 5: Write the `solutions/bennett.sh` skeleton**

```bash
#!/usr/bin/env bash
#
# LLWL lab 2 -- Bennett's answer.
#
#     sudo ./solutions/bennett.sh
#
# Read this after you are green, not before, and then argue with it. Several
# choices in here are judgement calls rather than facts.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=../../lib/common.sh
source "$HERE/../../lib/common.sh"

need_linux
need_root

# ... tiers appended by later tasks ...

info "lab 2 solved. Run ./check.sh as yourself."
```

- [ ] **Step 6: Run the harness and read the failure carefully**

Run: `chmod +x exercises/lab2/*.sh exercises/lab2/solutions/*.sh && tools/vmtest.sh lab2`
Expected: fails at harness step 2 — "check.sh passed on a freshly planted lab". Correct: there are
no defects yet. Every later task moves this forward.

Also confirm by hand in the machine that both units are up:
`orb -m llwl-test -- systemctl is-active llwl-report llwl-audit` → `active` twice.

- [ ] **Step 7: Review Focus 1 and 2 — the two teardown edge cases**

```bash
# 2a. teardown on a machine that was never planted
orb -m llwl-test -u root -- /tmp/llwl/exercises/lab2/teardown.sh
orb -m llwl-test -u root -- /tmp/llwl/exercises/lab2/teardown.sh   # twice in a row
```
Expected: exit 0 both times, warnings about the missing manifest on the second, nothing deleted
outside the allow-list.

```bash
# 2b. teardown with the manifest deleted but the lab planted
orb -m llwl-test -u root -- /tmp/llwl/exercises/lab2/setup.sh
orb -m llwl-test -u root -- rm -f /var/lib/llwl-labs/lab2.manifest
orb -m llwl-test -u root -- /tmp/llwl/exercises/lab2/teardown.sh
orb -m llwl-test -- bash -c 'getent passwd | grep llwl; ls -d /srv/llwl-* 2>/dev/null'
```
Expected: the fallback layout kicks in, everything goes, the grep is empty.

```bash
# 2c. a poisoned manifest must not escape the allow-list
orb -m llwl-test -u root -- /tmp/llwl/exercises/lab2/setup.sh
orb -m llwl-test -u root -- bash -c 'echo "path /etc/passwd" >> /var/lib/llwl-labs/lab2.manifest'
orb -m llwl-test -u root -- /tmp/llwl/exercises/lab2/teardown.sh
orb -m llwl-test -- test -f /etc/passwd && echo "/etc/passwd survived, good"
```
Expected: a `refusing to delete /etc/passwd` warning, and the file survives.

Review Focus 1 (re-planting over a solved lab) is asserted by harness step 4 and cannot be tested
until there is something to solve — it is verified in Task 10.

- [ ] **Step 8: Commit**

```bash
git add exercises/lab2 && git commit -m "Add lab 2 scaffolding: services, manifest, teardown

The safety-critical pair first, before any defect is planted. teardown
deletes home directories, which lab 1 never did, so an account clears two
independent gates -- name and home location -- before userdel --remove
touches it, and invented groups are printed for a human rather than
pattern-matched and deleted as root."
```

---

## Task 4: Tier 1 — the people

**Files:**
- Modify: `exercises/lab2/setup.sh` (add section 5, the broken accounts)
- Modify: `exercises/lab2/check.sh` (append tier 1)
- Modify: `exercises/lab2/solutions/bennett.sh` (append tier 1)

**Interfaces:**
- Consumes: `user_exists`, `can_user_login`, `account_expired`, `login_shell_of`, `uid_of`,
  `uid_has_name`, `user_in_group` from `common.sh`; `$MIRA`/`$TOBY`/`$NADIA`/`$OPS_GROUP`.
- Produces: accounts `llwlmira` (nologin shell, no supplementary groups) and `llwltoby` (expired,
  home owned by an orphaned uid); the manifest gains `note orphanuid <n>`.

- [ ] **Step 1: Write the failing checks**

Append to `check.sh`, before the trailing `finish` block:

```bash
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
```

- [ ] **Step 2: Run and watch it fail for the wrong reason**

Run: `tar -C . --exclude .git -cf - . | orb -m llwl-test -- tar -C /tmp/llwl -xf - && orb -m llwl-test -- bash -c 'cd /tmp/llwl/exercises/lab2 && ./check.sh 1'`
Expected: three "there is no account called ..." failures. Nothing is planted yet.

- [ ] **Step 3: Plant the two broken accounts**

Insert into `setup.sh` before the manifest section:

```bash
# ---------------------------------------------------------------------------
# 5. The two accounts the previous admin made. Both are wrong, in ways that are
#    invisible from `ls` and almost invisible from `getent passwd`.
# ---------------------------------------------------------------------------

# An unused uid, so that Toby's home directory ends up belonging to a number
# with no name behind it -- what you get when somebody restores a backup from a
# machine whose users were numbered differently.
pick_unused_uid() {
	local lo=$1 hi=$2 candidate
	for ((candidate = lo; candidate <= hi; candidate++)); do
		getent passwd "$candidate" >/dev/null && continue
		getent group "$candidate" >/dev/null && continue
		printf '%s\n' "$candidate"
		return 0
	done
	die "no unused uid available in the range $lo-$hi"
}
ORPHAN_UID=$(pick_unused_uid 61000 61999)

# Created as if she were a service account: a shell that refuses logins, and no
# groups beyond her own.
getent passwd llwlmira >/dev/null || useradd \
	--create-home \
	--shell /usr/sbin/nologin \
	--comment "Mira -- operator, project alpha" \
	llwlmira
usermod --shell /usr/sbin/nologin llwlmira
for g in $(id -nG llwlmira); do
	[[ $g == llwlmira ]] && continue
	gpasswd --delete llwlmira "$g" >/dev/null
done

# Created correctly, then expired -- and his home directory came off a backup.
getent passwd llwltoby >/dev/null || useradd \
	--create-home \
	--shell /bin/bash \
	--comment "Toby -- operator, project beta" \
	llwltoby
usermod --shell /bin/bash llwltoby
chage --expiredate 2020-01-01 llwltoby
chown -R "$ORPHAN_UID:$ORPHAN_UID" /home/llwltoby

# Nadia does not exist. Creating her is the learner's job.
userdel --remove llwlnadia 2>/dev/null || true
```

Then add to the manifest heredoc, after the `group` line:

```
note orphanuid $ORPHAN_UID
```

- [ ] **Step 4: Run the checks and confirm the right failures**

Run: `tar -C . --exclude .git -cf - . | orb -m llwl-test -- tar -C /tmp/llwl -xf - && orb -m llwl-test -u root -- /tmp/llwl/exercises/lab2/setup.sh && orb -m llwl-test -- bash -c 'cd /tmp/llwl/exercises/lab2 && ./check.sh 1'`

Expected, exactly: Mira exists but cannot log in (nologin shell); Mira is not in `llwlops`; Toby
exists but his account has expired; Toby's home belongs to a uid with no name; Toby is not in
`llwlops`; Nadia does not exist. Nadia's absence must produce one clean failure line and no `sudo:
unknown user` noise on stderr — that is Review Focus 3 landing in its real setting.

- [ ] **Step 5: Write the tier 1 solution**

Append to `solutions/bennett.sh`:

```bash
# --- Tier 1: the people ----------------------------------------------------

# Nadia is a human being, so: a home directory and a shell she can actually use.
getent passwd llwlnadia >/dev/null || useradd \
	--create-home \
	--shell /bin/bash \
	--comment "Nadia -- on call" \
	llwlnadia

# Mira was created as though she were a daemon. Give her a login shell.
usermod --shell /bin/bash llwlmira

# Toby's account expired. `chage -l llwltoby` is the only place that shows up.
chage --expiredate '' llwltoby

# And his home directory came back from a backup owned by a uid that means
# nothing on this machine. --from is the careful way to do this: it only
# rewrites ownership that is currently the wrong one, so a file in there that
# is legitimately owned by somebody else is left alone.
orphan_uid=$(awk '$1 == "note" && $2 == "orphanuid" { print $3 }' /var/lib/llwl-labs/lab2.manifest)
if [[ -n ${orphan_uid:-} ]]; then
	chown -R --from="$orphan_uid:$orphan_uid" llwltoby:llwltoby /home/llwltoby
else
	chown -R llwltoby:llwltoby /home/llwltoby
fi

# Operators get the credentials. On call does not.
gpasswd --add llwlmira llwlops >/dev/null
gpasswd --add llwltoby llwlops >/dev/null
```

- [ ] **Step 6: Run to green**

Run: `orb -m llwl-test -u root -- /tmp/llwl/exercises/lab2/solutions/bennett.sh && orb -m llwl-test -- bash -c 'cd /tmp/llwl/exercises/lab2 && ./check.sh 1'`
Expected: `N passed, 0 failed`.

- [ ] **Step 7: Commit**

```bash
git add exercises/lab2 && git commit -m "lab2: tier 1, the people

Two accounts made badly -- one with a service account's shell, one
expired with a home directory owned by a uid that means nothing on this
machine -- and a third the learner creates himself."
```

---

## Task 5: Tier 2 — the project directories

**Files:**
- Modify: `exercises/lab2/setup.sh` (add section 6, the project tree)
- Modify: `exercises/lab2/check.sh` (append tier 2)
- Modify: `exercises/lab2/solutions/bennett.sh` (append tier 2)

**Interfaces:**
- Consumes: `can_user_create`, `can_user_list`, `can_user_traverse`, `new_file_group` from Task 2;
  the accounts from Task 4.
- Produces: `/srv/llwl-projects/{alpha,beta,shared}`, planted `root:root 0755`.

- [ ] **Step 1: Write the failing checks**

Append to `check.sh`:

```bash
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
			fail "$owner cannot create files in $dir ($(owner_of "$dir"), mode $(mode_of "$dir")); it is supposed to be her team's working directory"
			return
		fi

		# The point is not that today's file has the right group. It is that
		# tomorrow's will, without anybody remembering to fix it.
		local g
		g=$(new_file_group "$owner" "$dir" || true)
		if [[ -n ${g:-} && $g == "$(group_of "$dir")" ]]; then
			pass "files $owner creates in $dir inherit the directory's group ($g)"
		else
			fail "a file $owner creates in $dir comes out group ${g:-unknown}, but the directory's group is $(group_of "$dir"); in six months half this tree will be unreadable to her own team"
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
```

- [ ] **Step 2: Run and watch it fail**

Run: `tar -C . --exclude .git -cf - . | orb -m llwl-test -- tar -C /tmp/llwl -xf - && orb -m llwl-test -- bash -c 'cd /tmp/llwl/exercises/lab2 && ./check.sh 2'`
Expected: `/srv/llwl-projects/alpha` does not exist yet → `check.sh` dies in preflight. Add
`$ALPHA` and `$BETA` to the preflight path list in `check.sh` only after Step 3 plants them; for
now the failure is "is missing -- plant the lab", which is the honest red.

- [ ] **Step 3: Plant the project tree**

Insert into `setup.sh` after section 5:

```bash
# ---------------------------------------------------------------------------
# 6. The project tree. Somebody ran mkdir and walked away: root owns all of it,
#    world-readable, no group structure at all. Nothing here is subtle, and
#    that is the point -- tier 2 is where the learner has to invent structure
#    rather than repair it.
# ---------------------------------------------------------------------------

mkdir -p "$PROJ_DIR/alpha" "$PROJ_DIR/beta" "$PROJ_DIR/shared"

cat >"$PROJ_DIR/alpha/README" <<'SEED'
Project alpha. Mira's team.
SEED
cat >"$PROJ_DIR/beta/README" <<'SEED'
Project beta. Toby's team.
SEED
cat >"$PROJ_DIR/shared/handbook.md" <<'SEED'
Shared between both project teams. Alpha maintains it; beta reads it.
SEED

chown -R root:root "$PROJ_DIR"
chmod 0755 "$PROJ_DIR" "$PROJ_DIR/alpha" "$PROJ_DIR/beta" "$PROJ_DIR/shared"
chmod 0644 "$PROJ_DIR/alpha/README" "$PROJ_DIR/beta/README" "$PROJ_DIR/shared/handbook.md"
```

Then add `"$ALPHA" "$BETA"` to the `check.sh` preflight loop.

- [ ] **Step 4: Confirm the right failures**

Run: `tar -C . --exclude .git -cf - . | orb -m llwl-test -- tar -C /tmp/llwl -xf - && orb -m llwl-test -u root -- /tmp/llwl/exercises/lab2/setup.sh && orb -m llwl-test -- bash -c 'cd /tmp/llwl/exercises/lab2 && ./check.sh 2'`
Expected: Mira cannot create in `alpha` (root-owned 0755); Toby cannot create in `beta`; each can
*enter* the other's directory (0755) so both "kept out" checks fail; `llwlreport` can enter both.

- [ ] **Step 5: Write the tier 2 solution**

Append to `solutions/bennett.sh`:

```bash
# --- Tier 2: the project directories ---------------------------------------
#
# Two groups, one per project team. I could have used one group and leaned on
# directory permissions, but then "who is on alpha" would have no answer you
# could query -- and `getent group` being the answer to that question is worth
# more than saving a group.

getent group llwlalpha >/dev/null || groupadd llwlalpha
getent group llwlbeta >/dev/null || groupadd llwlbeta
gpasswd --add llwlmira llwlalpha >/dev/null
gpasswd --add llwltoby llwlbeta >/dev/null

# 2770 rather than 0770: the setgid bit is the whole reason this keeps working
# after today. Without it every file Mira creates comes out group llwlmira, and
# in six months the tree is a patchwork nobody can read.
#
# The directory stays owned by root. Nobody needs to own it for the group to
# work, and root owning it means neither operator can chmod their way out.
chown root:llwlalpha /srv/llwl-projects/alpha
chown root:llwlbeta /srv/llwl-projects/beta
chmod 2770 /srv/llwl-projects/alpha
chmod 2770 /srv/llwl-projects/beta

# The files that were already in there predate the group, so they still carry
# the old one. Changing a directory's group never touches what is inside it.
chgrp -R llwlalpha /srv/llwl-projects/alpha
chgrp -R llwlbeta /srv/llwl-projects/beta
chmod 0660 /srv/llwl-projects/alpha/README /srv/llwl-projects/beta/README

# The parent has to be traversable or nothing below it is reachable, but it
# does not have to be listable by strangers.
chown root:root /srv/llwl-projects
chmod 0755 /srv/llwl-projects
```

- [ ] **Step 6: Run to green**

Run: `orb -m llwl-test -u root -- /tmp/llwl/exercises/lab2/solutions/bennett.sh && orb -m llwl-test -- bash -c 'cd /tmp/llwl/exercises/lab2 && ./check.sh 2'`
Expected: `N passed, 0 failed`. If "kept out" still fails, the parent `/srv/llwl-projects` at 0755
is fine — the failing mode will be on `alpha`/`beta` themselves.

- [ ] **Step 7: Commit**

```bash
git add exercises/lab2 && git commit -m "lab2: tier 2, the project directories

Checked by behaviour throughout: the setgid assertion creates a file as
the operator and reads its group back, so a one-off chgrp does not pass."
```

---

## Task 6: Tier 3 — delegate one power

The highest-risk task in the plan. Read the Global Constraints on `/etc/sudoers.d/` again before
starting.

**Files:**
- Modify: `exercises/lab2/setup.sh` (add section 7, the drop-in)
- Modify: `exercises/lab2/check.sh` (append tier 3)
- Modify: `exercises/lab2/solutions/bennett.sh` (append tier 3)

**Interfaces:**
- Consumes: `can_user_read`, `as_user`, `mode_of`, `owner_of` from `common.sh`; `llwlnadia` from
  Task 4; `llwl-audit.service` from Task 3.
- Produces: `/etc/sudoers.d/llwl-oncall`, `0440 root:root`, `visudo`-valid.

- [ ] **Step 1: Write the failing checks**

Append to `check.sh`:

```bash
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

	if [[ -f $SUDOERS_DROPIN ]]; then
		m=$(mode_of "$SUDOERS_DROPIN")
		o=$(owner_of "$SUDOERS_DROPIN")
		if [[ $m == 440 && $o == root:root ]]; then
			pass "$SUDOERS_DROPIN is $o mode $m"
		else
			fail "$SUDOERS_DROPIN is $o mode $m; sudo refuses to read a drop-in that anyone but root can write, and it will not tell you it is ignoring your rule"
		fi
	else
		fail "$SUDOERS_DROPIN is gone; the on-call rule has to live in that file so teardown knows it owns it"
	fi

	# The one power she is supposed to have. Behavioural: actually restart the
	# service as her, with no password, and confirm it really restarted.
	if user_exists "$NADIA"; then
		before=$(sudo -n systemctl show --property=ExecMainStartTimestampMonotonic --value "$REPORT_SVC" 2>/dev/null || echo 0)
		if as_user "$NADIA" sudo -n systemctl restart "$REPORT_SVC" >/dev/null 2>&1; then
			sleep 1
			after=$(sudo -n systemctl show --property=ExecMainStartTimestampMonotonic --value "$REPORT_SVC" 2>/dev/null || echo 0)
			if [[ $after -gt $before ]]; then
				pass "$NADIA can restart $REPORT_SVC without a password, and it really restarted"
			else
				fail "$NADIA's restart of $REPORT_SVC returned success but the service did not restart"
			fi
		else
			fail "$NADIA cannot restart $REPORT_SVC; that is the one thing she is on call to be able to do"
		fi

		# The one power she is not supposed to have. If she can stop this, she
		# can stop anything on the machine.
		if as_user "$NADIA" sudo -n systemctl stop "$AUDIT_SVC" >/dev/null 2>&1; then
			fail "$NADIA can stop $AUDIT_SVC, a service she has nothing to do with; the rule grants far more than one power"
			sudo -n systemctl start "$AUDIT_SVC" >/dev/null 2>&1 || true
		else
			pass "$NADIA cannot stop $AUDIT_SVC"
		fi

		if as_user "$NADIA" sudo -n systemctl mask "$AUDIT_SVC" >/dev/null 2>&1; then
			fail "$NADIA can mask $AUDIT_SVC; masking a unit is how you make a service unstartable until somebody works out why"
			sudo -n systemctl unmask "$AUDIT_SVC" >/dev/null 2>&1 || true
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
```

- [ ] **Step 2: Run and watch it fail**

Run: `tar -C . --exclude .git -cf - . | orb -m llwl-test -- tar -C /tmp/llwl -xf - && orb -m llwl-test -- bash -c 'cd /tmp/llwl/exercises/lab2 && ./check.sh 3'`
Expected: the drop-in is missing (not planted yet), and Nadia cannot restart the service.

- [ ] **Step 3: Plant the drop-in, safely**

Insert into `setup.sh` after section 6:

```bash
# ---------------------------------------------------------------------------
# 7. The rule the previous admin left behind.
#
# Read the installation dance below carefully, because it is the pattern for
# writing any sudoers file from a script: build it somewhere harmless, have
# visudo parse it, and only then move it into place. A file in /etc/sudoers.d
# that sudo cannot parse can cost you sudo on the whole machine, and this lab
# refuses to be the thing that does that to somebody.
# ---------------------------------------------------------------------------

SYSTEMCTL=$(command -v systemctl)

dropin_tmp=$(mktemp)
cat >"$dropin_tmp" <<DROPIN
# /etc/sudoers.d/llwl-oncall
#
# So that whoever is on call can bounce the reporting service at 3am without
# having to wake anybody up.
#
#   -- the previous admin, who no longer works here
%llwloncall ALL=(ALL) NOPASSWD: $SYSTEMCTL
DROPIN

if ! visudo --check --quiet --file="$dropin_tmp"; then
	rm -f "$dropin_tmp"
	die "refusing to install a sudoers drop-in that visudo will not accept"
fi
install --owner=root --group=root --mode=0440 "$dropin_tmp" "$SUDOERS_DROPIN"
rm -f "$dropin_tmp"

# And prove the whole configuration still parses with it in place. If it does
# not, take it straight back out -- a planted lab must never cost the learner
# their own sudo.
if ! visudo --check --quiet; then
	rm -f "$SUDOERS_DROPIN"
	die "installing the drop-in broke sudo's configuration; removed it again"
fi
```

- [ ] **Step 4: Verify the machine's sudo survived, then confirm the right failures**

Run:
```bash
tar -C . --exclude .git -cf - . | orb -m llwl-test -- tar -C /tmp/llwl -xf -
orb -m llwl-test -u root -- /tmp/llwl/exercises/lab2/setup.sh
orb -m llwl-test -- sudo -n true && echo "sudo still works"
orb -m llwl-test -- bash -c 'cd /tmp/llwl/exercises/lab2 && ./check.sh 3'
```
Expected: `sudo still works` prints. Then: the drop-in is `0440 root:root` (pass), and Nadia cannot
restart the service (fail) — the rule names a group nobody is in.

- [ ] **Step 5: Confirm the over-reach is real before fixing it**

This is the demonstration the README will ask the learner to do, so verify it works:

```bash
orb -m llwl-test -u root -- bash -c '
  groupadd llwloncall
  useradd --create-home --shell /bin/bash llwlnadia 2>/dev/null || true
  gpasswd --add llwlnadia llwloncall'
orb -m llwl-test -u root -- sudo -n -u llwlnadia sudo -n -l
orb -m llwl-test -u root -- sudo -n -u llwlnadia sudo -n systemctl stop llwl-audit
orb -m llwl-test -- systemctl is-active llwl-audit    # expect: inactive
orb -m llwl-test -u root -- systemctl start llwl-audit
```
Expected: `sudo -l` prints `(ALL) NOPASSWD: /usr/bin/systemctl`, the stop succeeds, `is-active`
says `inactive`. That is the whole lesson, and it worked. Re-plant afterwards:
`orb -m llwl-test -u root -- /tmp/llwl/exercises/lab2/setup.sh`

- [ ] **Step 6: Write the tier 3 solution**

Append to `solutions/bennett.sh`:

```bash
# --- Tier 3: delegate one power --------------------------------------------
#
# The rule as I found it said `NOPASSWD: /usr/bin/systemctl` with nothing after
# it. sudo takes a command with no arguments to mean *any* arguments, so that
# rule is not "restart the reporting service" -- it is "run any systemctl
# subcommand against any unit on this machine as root", which includes stopping
# the firewall and masking the audit agent.
#
# What I want instead is one command, spelled out in full, with its arguments
# fixed. A Cmnd_Alias is not strictly necessary for one command, but it gives
# the thing a name, and a named rule is one somebody can review in a year.

getent group llwloncall >/dev/null || groupadd llwloncall
gpasswd --add llwlnadia llwloncall >/dev/null

systemctl_path=$(command -v systemctl)

dropin_tmp=$(mktemp)
cat >"$dropin_tmp" <<DROPIN
# /etc/sudoers.d/llwl-oncall
#
# On-call may restart the reporting service. That is the entire grant.
#
# Arguments are spelled out deliberately. A command with no arguments after it
# in a sudoers rule means any arguments at all, which is how the previous
# version of this file ended up granting the whole machine.
Cmnd_Alias LLWL_RESTART_REPORT = $systemctl_path restart llwl-report, \\
                                 $systemctl_path restart llwl-report.service
%llwloncall ALL=(root) NOPASSWD: LLWL_RESTART_REPORT
DROPIN

# Never move an unvalidated file into /etc/sudoers.d.
visudo --check --quiet --file="$dropin_tmp" ||
	die "my replacement rule does not parse; leaving the old one alone"
install --owner=root --group=root --mode=0440 "$dropin_tmp" /etc/sudoers.d/llwl-oncall
rm -f "$dropin_tmp"
visudo --check --quiet || die "sudo configuration broke; fix it from the root shell you kept open"
```

- [ ] **Step 7: Run to green, then re-verify sudo**

Run:
```bash
orb -m llwl-test -u root -- /tmp/llwl/exercises/lab2/solutions/bennett.sh
orb -m llwl-test -- sudo -n true && echo "sudo still works"
orb -m llwl-test -- bash -c 'cd /tmp/llwl/exercises/lab2 && ./check.sh 3'
```
Expected: `sudo still works`, then `N passed, 0 failed`.

Confirm the `restart` grant is genuinely narrow and not accidentally wide:
```bash
orb -m llwl-test -u root -- sudo -n -u llwlnadia sudo -n -l
```
Expected: exactly the two `restart llwl-report` forms, nothing else.

- [ ] **Step 8: Commit**

```bash
git add exercises/lab2 && git commit -m "lab2: tier 3, delegate one power

Planted rule grants unconstrained systemctl, so the on-call account can
stop a service it has nothing to do with -- demonstrated against a
lab-owned unit that does nothing, never against anything real. Both
setup.sh and the solution build sudoers files in a temp file, visudo
them, and only then install; a planted lab must never cost somebody
their own sudo."
```

---

## Task 7: Tier 4 — optional, when mode bits run out

**Files:**
- Modify: `exercises/lab2/check.sh` (append tier 4)
- Modify: `exercises/lab2/solutions/bennett.sh` (append tier 4)

**Interfaces:**
- Consumes: `have_working_acls`, `acl_of`, `can_user_read`, `can_user_write`, `can_user_create`,
  `can_user_list` from Task 2; `/srv/llwl-projects/shared` from Task 5.
- Produces: nothing later tasks depend on. Tier 4 never gates `./check.sh`.

- [ ] **Step 1: Write the failing checks**

Append to `check.sh`:

```bash
# ---------------------------------------------------------------------------
# Tier 4 -- optional: when mode bits run out
# ---------------------------------------------------------------------------

if want_tier 4; then
	section "Tier 4 (optional) -- when mode bits run out"

	if ! have_working_acls "$PROJ_DIR"; then
		skip "no working ACL support here"
		if ! command -v setfacl >/dev/null 2>&1; then
			note "setfacl is not installed:  sudo apt install acl"
		else
			note "$PROJ_DIR is on a filesystem mounted without ACL support; check 'findmnt -no OPTIONS -T $PROJ_DIR'"
		fi
	else
		if can_user_create "$MIRA" "$SHARED"; then
			pass "$MIRA can add to $SHARED"
		else
			fail "$MIRA cannot add to $SHARED; alpha maintains the shared handbook"
		fi

		# The whole point of tier 4 is files that do not exist yet. Create one
		# now, as Mira, and see whether Toby can read it -- a one-off setfacl
		# over what was already there will not survive this.
		probe=$SHARED/.llwl-inherit-probe-$$
		if sudo -n -u "$MIRA" touch -- "$probe" 2>/dev/null; then
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

		if acl_of "$SHARED" | grep -q '^default:'; then
			pass "$SHARED carries a default ACL, so new files inherit it"
		else
			fail "$SHARED has no default ACL; nothing makes tomorrow's files come out right"
		fi
	fi
fi
```

- [ ] **Step 2: Run and watch it fail (or skip)**

Run: `tar -C . --exclude .git -cf - . | orb -m llwl-test -- tar -C /tmp/llwl -xf - && orb -m llwl-test -- bash -c 'cd /tmp/llwl/exercises/lab2 && ./check.sh 4'`
Expected on a stock Ubuntu image: `setfacl` is usually absent, so every check `skip`s with the
`apt install acl` note. **That is Review Focus 5 passing.** Then install it and get the real red:

```bash
orb -m llwl-test -u root -- apt-get install -y acl
orb -m llwl-test -- bash -c 'cd /tmp/llwl/exercises/lab2 && ./check.sh 4'
```
Expected now: Mira cannot add to `shared` (root-owned 0755), no default ACL.

- [ ] **Step 3: Write the tier 4 solution**

Append to `solutions/bennett.sh`:

```bash
# --- Tier 4 (optional): when mode bits run out ------------------------------
#
# shared/ has three audiences and mode bits have room for one group. Alpha
# writes, beta reads, nobody else gets in. There is no chmod that says that.
#
# The `-d` entries are the ones that matter. Without them this is correct today
# and wrong tomorrow, in exactly the way the tier 2 setgid bit was about.

if ! command -v setfacl >/dev/null 2>&1; then
	warn "tier 4 needs the acl package: sudo apt install acl -- skipping"
else
	chown root:llwlalpha /srv/llwl-projects/shared
	chmod 2770 /srv/llwl-projects/shared
	chgrp -R llwlalpha /srv/llwl-projects/shared
	chmod 0660 /srv/llwl-projects/shared/handbook.md

	# Beta gets read and traverse on the directory, read on its contents, and
	# the same for everything created here from now on.
	setfacl --modify=group:llwlbeta:r-x /srv/llwl-projects/shared
	setfacl --default --modify=group:llwlbeta:r-- /srv/llwl-projects/shared
	setfacl --default --modify=group:llwlalpha:rw- /srv/llwl-projects/shared
	setfacl --default --modify=other::--- /srv/llwl-projects/shared
	setfacl --recursive --modify=group:llwlbeta:r-- /srv/llwl-projects/shared/handbook.md

	# Anything already in here predates the ACL, same as the group did in tier 2.
	setfacl --recursive --modify=group:llwlbeta:r-- /srv/llwl-projects/shared
	setfacl --modify=group:llwlbeta:r-x /srv/llwl-projects/shared
fi
```

- [ ] **Step 4: Run to green**

Run: `orb -m llwl-test -u root -- /tmp/llwl/exercises/lab2/solutions/bennett.sh && orb -m llwl-test -- bash -c 'cd /tmp/llwl/exercises/lab2 && ./check.sh 4'`
Expected: `N passed, 0 failed`.

Then confirm the mask gotcha the README will warn about is real, so the warning is accurate:
```bash
orb -m llwl-test -u root -- bash -c 'chmod 2770 /srv/llwl-projects/shared; getfacl -c /srv/llwl-projects/shared'
```
Expected: the `mask::` line has changed and beta's effective permission is reduced. Record what it
actually does — the README sentence must describe the observed behaviour, not the folklore.

- [ ] **Step 5: Confirm tier 4 does not gate the lab**

Run: `orb -m llwl-test -u root -- /tmp/llwl/exercises/lab2/setup.sh && orb -m llwl-test -u root -- /tmp/llwl/exercises/lab2/solutions/bennett.sh`

Then temporarily neutralise tier 4 only:
```bash
orb -m llwl-test -u root -- setfacl --remove-all --recursive /srv/llwl-projects/shared
orb -m llwl-test -- bash -c 'cd /tmp/llwl/exercises/lab2 && ./check.sh'      # expect: exit 0
orb -m llwl-test -- bash -c 'cd /tmp/llwl/exercises/lab2 && ./check.sh 4'    # expect: failures
```
Expected: the bare run exits 0 and prints the "tier 4 is optional and was not run" note; `./check.sh 4`
fails. That is the gate behaviour the spec asks for.

- [ ] **Step 6: Commit**

```bash
git add exercises/lab2 && git commit -m "lab2: tier 4, optional ACLs

Skips with an actionable message when the acl package is missing or the
filesystem has no ACL support, rather than failing for something that is
not the learner's mistake. Never gates a bare ./check.sh."
```

---

## Task 8: The lab README and the setup briefing

**Files:**
- Create: `exercises/lab2/README.md`
- Modify: `exercises/lab2/setup.sh` (add the closing briefing block)

**Interfaces:**
- Consumes: the finished behaviour of all four tiers.
- Produces: the learner-facing document. No code depends on it.

- [ ] **Step 1: Write the README**

Match `lab1/README.md`'s voice exactly: second person, named files in tier 1 only, symptoms
afterwards, "worth reading" blocks with specific `man` pages, gotchas stated plainly where leaving
them as puzzles would be cruel. Required sections, in order:

1. **Header** — `**Skills:**` list (`useradd`, `usermod`, `chage`, `gpasswd`, `id`, `getent`,
   setgid recap, `visudo`, `sudo -l`, `setfacl`) and `**Time:**`.
2. **The situation** — the team grew; the three people and exactly what each must be able to do;
   the explicit statement that Nadia being on call is not the same as being trusted with the
   credentials.
3. **Before you start** — Timeshift; `sudo ./setup.sh`; run `check.sh` as yourself; **the sudoers
   danger rules**: never edit a sudoers file with a plain editor, always
   `sudo visudo --check --file=<copy>` before it goes live, and keep a second terminal with a root
   shell open (`sudo -i`) while you work on tier 3 so a mistake is an inconvenience rather than a
   reinstall. State that the on-call rule must stay in `/etc/sudoers.d/llwl-oncall`.
4. **Where things live** — a path table, same shape as lab 1's.
5. **Tier 1 — the people.** Name the accounts. Say Nadia does not exist yet. For the other two,
   give symptoms, not diagnoses: "one of them cannot log in, and the reason is not her password";
   "the other's home directory looks wrong in a way `ls -l` will not show you — try `ls -ln`".
   Worth reading: `man useradd` (`--system` vs not, `-G` vs `-g`), `man chage`, `man 5 passwd`,
   `man 5 shadow`.
6. **Tier 2 — the project directories.** State the requirements for alpha and beta as
   requirements, not as instructions. Remind him the setgid bit from lab 1 is the thing that makes
   this survive contact with six months of use, and state plainly that changing a directory's
   group does not change what is already inside it. Worth reading: `man chmod` (the `s` bit),
   `man gpasswd`, `man newgrp`.
7. **Tier 3 — delegate one power.** Four numbered beats matching the spec: find out why it grants
   nobody anything (`sudo -l -U llwlnadia`, `sudo visudo -c`); make it work for Nadia; **read what
   it actually grants and prove it** — "as Nadia, stop `llwl-audit.service`. It is a service that
   does nothing and has nothing to do with her. It will work. Start it again, and then go and
   read the rule once more, asking what else it lets her do"; rewrite it to the minimum. Explicit
   instruction not to try the rule against any service that is not `llwl-*`. Worth reading:
   `man 5 sudoers` (Cmnd_Alias, and what a command with no arguments means), `man visudo`,
   `man sudo` (`-l`, `-U`).
8. **Tier 4 — optional.** Frame it as "come back to this one". The `shared/` requirement as a
   requirement. State the `+` in `ls -l` and the `chmod`-rewrites-the-mask gotcha plainly, using
   the behaviour observed in Task 7 Step 4. Note it needs `sudo apt install acl`. Worth reading:
   `man setfacl`, `man getfacl`, `man 5 acl`.
9. **Deliverables** — `solutions/luke.sh` proved from scratch with the exact command sequence, and
   `../../notes/lab2-luke.md` with the seven questions from the spec's Deliverables section
   (copy them verbatim, including the tier-4-only one marked as such).
10. **What's next** — the storage preview. `df -h /srv/llwl-projects`, `du -sh /srv/llwl-projects/*`,
    and the paragraph: the tree he just built shares a filesystem with his logs, his packages and
    his home directory; nothing stops project alpha filling the disk for everybody; a full `/`
    takes the machine down rather than just the greedy directory; lab 3 gives the projects their
    own filesystem and their own boundary.
11. **When you're finished** — `sudo ./teardown.sh`, and the note that the groups he invented are
    his to clean up because the lab will not guess at them.

- [ ] **Step 2: Add the briefing to `setup.sh`**

```bash
cat <<BRIEF

${C_BOLD}Lab 2 is planted.${C_OFF}

  The team grew. Three people need accounts on this machine, two of them
  already exist and were made carelessly, and the previous admin left a sudo
  rule behind that does not do what its comment says.

  Start here:
      ./check.sh 1
      getent passwd | grep llwl
      sudo -l -U llwlnadia

  Read ./README.md for the tiers and the ground rules -- especially the ones
  about editing sudoers files, which are the only way this lab can cost you
  an evening.

  Undo everything at any time with:  sudo ./teardown.sh

BRIEF
```

- [ ] **Step 3: Read the README as the learner**

Read it start to finish out loud against `lab1/README.md`. Check: does tier 2 onward give symptoms
rather than instructions? Is every `man` page reference one that actually contains what you claim?
Is there any sentence that would read as condescending to someone on their second lab?

Verify the man page claims:
```bash
orb -m llwl-test -- man 5 sudoers | grep -n -A3 'Cmnd_Alias'
orb -m llwl-test -- man chage | head -30
```

- [ ] **Step 4: Commit**

```bash
git add exercises/lab2/README.md exercises/lab2/setup.sh
git commit -m "lab2: the README

Closes with a df/du look at where the project tree actually lives, which
is the question lab 3 answers."
```

---

## Task 9: Repo-level documentation

**Files:**
- Modify: `README.md` (the ladder table and the lab-1 pointer)
- Modify: `exercises/README.md` (manifest kinds; the sudo note)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing. Documentation only.

- [ ] **Step 1: Rewrite the ladder**

Replace the table in `README.md` with eight rows:

```markdown
| Lab | What breaks | What you come out knowing |
|---|---|---|
| **1** | A deployed service that won't start | the shell, `ls -l`, `chmod`, `chown`, `find -perm`, `stat`, `systemctl`, `journalctl`, groups, setgid, sticky bit |
| **2** | A team that just grew | `useradd`, `usermod`, `chage`, group design, setgid directories that stay correct, `sudoers` drop-ins and why one command can mean the whole machine, ACLs |
| 3 | Where the files actually live | `df`, `du`, partitions and filesystems, `mkfs`, mounting, `/etc/fstab` and how not to make a machine unbootable |
| 4 | A machine that has gone slow | `top`, `ps`, load average, `nice`, signals, `kill` vs `kill -9`, finding the process nobody admits to starting |
| 5 | Text as data | `grep`, `cut`, `sort`, `uniq`, `awk`, `xargs`, pipes — answering real questions about a real 100k-line log |
| 6 | Shell scripting for real | `set -euo pipefail`, `trap`, argument parsing, `--dry-run`, a backup script on a timer |
| 7 | Networking and getting in | `ip`, `ss`, `curl`, `ufw`, key-only SSH, and why SSH refuses your private key |
| 8 | Capstone | take a bare VM to a live TLS website — nginx, systemd, firewall — with a runbook good enough for someone else to follow |
```

Leave the paragraph under it about RHCSA/Linux+ as it is — still true.

- [ ] **Step 2: Update the lab contract table**

In `exercises/README.md`, change the `check.sh` row's description to end with: "From lab 2 onward
it will ask for `sudo` once, because checking what *other* people's accounts can do requires
root — it still never runs as root itself."

- [ ] **Step 3: Update the "Adding a lab" conventions**

Add to that section:

```markdown
- Manifest kinds are `path`, `unit`, `user`, `group`, `home` and `note`. `home` is a home
  directory; `teardown.sh` only passes `--remove` to `userdel` when the account's name and its
  home location *both* look like a lab's. `note` is free-form state the lab needs to remember
  between `setup.sh` and `solutions/`, like a generated uid.
- Labs are verified with `tools/vmtest.sh <lab>`, which runs the whole lifecycle in a disposable
  Ubuntu machine and asserts plant → fail → solve → re-plant → fail → teardown → nothing left.
  Run it before opening a PR.
```

- [ ] **Step 4: Check the cross-references still hold**

```bash
grep -rn 'lab1\|lab 1\|Lab 1' README.md exercises/README.md exercises/lab2/README.md
```
Confirm nothing now points at a lab number that moved.

- [ ] **Step 5: Commit**

```bash
git add README.md exercises/README.md
git commit -m "Reorder the ladder: users at 2, storage at 3, processes at 4

Users and delegation follow directly from lab 1 ending on group
membership. Storage follows lab 2 ending on 'where does this tree
actually live'. Splitting the old disks-and-networking row gives
filesystems a lab where they are the subject."
```

---

## Task 10: Full-lifecycle verification

**Files:**
- No new files. This task either passes or sends you back to a previous one.

**Interfaces:**
- Consumes: everything.
- Produces: a verified branch ready for review.

- [ ] **Step 1: Destroy the test machine and start clean**

The machine has had thirty experiments run on it. None of the earlier results count.

```bash
orb delete llwl-test --force
orb create ubuntu:24.04 llwl-test
```

- [ ] **Step 2: Run the harness on both labs**

Run: `tools/vmtest.sh lab1 && tools/vmtest.sh lab2`
Expected: `PASS  lab1 is well-formed` and `PASS  lab2 is well-formed`. Lab 1 is in there to prove
the `common.sh` changes did not regress it.

Note that harness step 4 is Review Focus 1 — re-planting over a solved lab — now finally
exercisable, and step 6 confirms the learner's sudo survived the whole thing.

- [ ] **Step 3: Run the tier-4 path, which the harness does not cover**

```bash
orb -m llwl-test -u root -- apt-get install -y acl
tar -C . --exclude .git -cf - . | orb -m llwl-test -- tar -C /tmp/llwl -xf -
orb -m llwl-test -u root -- /tmp/llwl/exercises/lab2/setup.sh
orb -m llwl-test -- bash -c 'cd /tmp/llwl/exercises/lab2 && ./check.sh 4'   # expect: failures
orb -m llwl-test -u root -- /tmp/llwl/exercises/lab2/solutions/bennett.sh
orb -m llwl-test -- bash -c 'cd /tmp/llwl/exercises/lab2 && ./check.sh 4'   # expect: 0 failed
orb -m llwl-test -u root -- /tmp/llwl/exercises/lab2/teardown.sh
```

- [ ] **Step 4: Run the unit tests once more on the clean machine**

Run: `orb -m llwl-test -u root -- /tmp/llwl/tools/test-common.sh`
Expected: `0 failed`.

- [ ] **Step 5: Shellcheck everything**

```bash
shellcheck -x exercises/lab2/*.sh exercises/lab2/solutions/*.sh exercises/lib/common.sh tools/*.sh
```
Expected: clean. `common.sh` already carries `# shellcheck shell=bash`; add `# shellcheck source=`
directives where needed rather than disabling warnings.

- [ ] **Step 6: Solve it by hand once, as a human would**

The harness proves `bennett.sh` works. It does not prove the *lab* works. Get a shell as an
ordinary user and actually do tier 1 through 3 from the README alone, without looking at the
solution. This is the only step that can catch a README that says something untrue, a check whose
failure message does not point anywhere useful, or a tier that is impossible in the order it is
presented.

```bash
orb -m llwl-test -u root -- /tmp/llwl/exercises/lab2/setup.sh
orb -m llwl-test          # a normal shell as the default (non-root) user
```

Write down anything that made you stop and re-read. Those are README bugs.

- [ ] **Step 7: Commit and open the PR**

```bash
git add -A
git commit -m "lab2: verified end to end on a clean Ubuntu machine"
git push -u origin lab2-bennett
gh pr create --fill
```

---

## Notes for the implementer

- **You cannot test any of this on the host.** macOS has no systemd, no `useradd`, no `visudo` in
  the form these scripts expect. Every verification step goes through `tools/vmtest.sh` or `orb`.
- **`set -e` and the capability probes.** Every helper returns 1 for "no". Calling one bare at the
  top level of a script under `set -e` will exit it. Always use them in an `if`, `&&`, `||` or `!`
  context. `check.sh` does this everywhere; keep it that way.
- **When in doubt about a sudoers change, get a root shell open first.** `sudo -i` in a second
  terminal before you touch `/etc/sudoers.d/`. This applies to you writing the lab, not just to
  the learner doing it.
- **Do not add `/etc/sudoers.d` files with names other than `llwl-oncall`.** Teardown's allow-list
  is exact, and an orphan file in there is the one piece of litter this lab could leave that would
  genuinely matter.
