# Lab 2 — Onboard the team: users, groups, ACLs, and delegated sudo

**Status:** approved design, ready for an implementation plan
**Date:** 2026-08-30
**Learner:** Luke (second lab; first lab was permissions and a broken service deploy)

## Why this lab, and why here

Lab 1 ends on a cliffhanger the learner does not realise is one: he adds himself to `llwlops`,
runs `id`, and the group is not there. He has just met group membership as a real mechanism. The
next question a person actually asks is "so how do I make an account, and how do I let somebody do
one root thing without handing them the whole machine."

Lab 2 answers that. It takes the mode bits from lab 1 to the point where they run out of room
(three parties, one group slot) and then introduces ACLs as the answer, and it teaches delegated
administration by handing the learner a `sudoers` rule that is secretly a root shell.

This displaces "processes and services" from slot 2. See **Curriculum change** below.

## Learning objectives

By the end, Luke can:

1. Create a human account correctly and say how it differs from a service account —
   `useradd` vs `useradd --system`, `--create-home`, `--shell`, `-G` vs `-g`.
2. Diagnose "this person cannot log in" from symptoms, using `getent`, `id`, `chage -l`,
   `sudo -u X -i`, and by reading `/etc/passwd` and `/etc/shadow` as data.
3. Understand that file ownership is a **number**, not a name, and recognise what an orphaned uid
   looks like (`ls -ln`, `chown --from=`).
4. Design a group structure from a set of requirements, rather than being handed one.
5. Express an access requirement that mode bits cannot express, using POSIX ACLs — including
   **default ACLs** as the inheritance mechanism, the `+` in `ls -l`, and the way a later `chmod`
   guts the ACL mask.
6. Read a `sudoers` rule adversarially: spot an unconstrained argument list and a permitted program
   that can spawn a shell, demonstrate the escalation, and then write the minimal rule that grants
   the intended power and nothing else — validated with `visudo -cf` before it goes live.

## Premise

`llwl-api` survived lab 1 and the team grew. Three people need accounts:

- **`llwlmira`** — operator, project *alpha*.
- **`llwltoby`** — operator, project *beta*.
- **`llwlnadia`** — the on-call junior. Needs exactly one privileged power: restart the reporting
  service. Nothing else. Specifically must not be able to read the service's secret and must not
  be able to become root.

The same departed admin left a `/etc/sudoers.d/` drop-in that was meant to grant Nadia's one
power. It does not work, and it also makes its user root.

`llwlops` carries over from lab 1 as the group of humans who operate a service, and in lab 2 it is
the group permitted to read the service secret. So the requirement is not just "make three
accounts": Mira and Toby are operators and belong to it, and **Nadia does not** — she is on call,
which is not the same thing as being trusted with the credentials. That distinction is the whole
point of tier 3's "cannot read `secrets.env`" check, and it is the kind of judgement call worth
making Luke defend in his notes.

**The lab is self-contained.** `setup.sh` plants its own service (`llwl-report`) and its own paths,
so lab 2 runs whether or not lab 1 is still planted. It reuses the group name `llwlops` for
continuity of story but creates it itself if absent.

### Usernames are dictated; group names are Luke's to invent

Luke is given the three people and what each must be able to do. **The group structure is his
design problem.** He may create as many groups as he likes and name them what he likes.

Consequently `check.sh` verifies **capabilities, not names**: "can `llwltoby` read this file",
never "is there a group called `llwlbeta`". This is a deliberate strengthening of the lab-1
convention that at least one check be behavioural — here essentially every check is, which makes
the lab ungameable by reading `check.sh`.

Usernames stay fixed so `teardown.sh` knows exactly which accounts it is permitted to delete.

## What `setup.sh` plants

### The service (working, not broken)

Lab 2 is not about fixing a service. `llwl-report` starts correctly and is enabled from the start;
it exists to be a thing worth delegating a restart on.

- System account `llwlreport` (`--system`, `nologin`, no home) — the same shape as lab 1's
  `llwlapi`, deliberately, as the contrast case for tier 1.
- `/srv/llwl-report/run.sh` — a small loop that writes a heartbeat and a log line. Keep it shorter
  than lab 1's `run.sh`; it is scenery, not subject matter.
- `/etc/llwl-report/report.conf` — **sourced** by `run.sh` as the service account. This property is
  load-bearing for tier 3: write access to this file is code execution as the service.
- `/etc/llwl-report/secrets.env` — `0640 root:llwlops`, i.e. already correct per lab 1's lesson.
  Tier 3 asserts Nadia cannot read it.
- `/etc/systemd/system/llwl-report.service` — `0644 root:root`, enabled and started.

### The two broken accounts

| Account | Planted defect | What it teaches |
|---|---|---|
| `llwlmira` | login shell is `/usr/sbin/nologin`; no supplementary groups | a human account created as if it were a service account |
| `llwltoby` | `--expiredate` set in the past | accounts expire; `chage -l` is the only place this is visible |
| `llwltoby` | home directory owned by an orphaned numeric uid | ownership is a number, not a name |

`llwlnadia` is **not** created. Luke creates her from scratch — the build half of tier 1.

For the orphaned uid, `setup.sh` picks the first unused uid in the range 61000–61999 (checked with
`getent passwd`) and records it in the manifest, so that a re-plant reproduces the same
state and so a human reading the manifest can see where the odd number came from.

### The project tree

`/srv/llwl-projects/{alpha,beta,shared}`, planted as `root:root 0755` with a seed file in each —
the state you get when somebody ran `mkdir` and walked away. The requirements Luke must satisfy:

- `alpha/` — mira's team read/write; **files created in it later must belong to the team group
  automatically** (setgid, recapping lab 1 rather than re-teaching it); nobody else may enter.
- `beta/` — the same, for toby's team.
- `shared/` — read-write for alpha, **read-only for beta**, and no access at all for anybody else.
  Including files created tomorrow.

`shared/` is the wall: three parties, and mode bits offer exactly one group slot. That wall is the
lesson, and the README should let him hit it rather than announcing it.

### The sudoers drop-in

`/etc/sudoers.d/llwl-oncall`, planted at valid mode `0440 root:root` (see **Safety** — this is not
negotiable), containing roughly:

```
# so that whoever is on call can bounce the reporting service at 3am
%llwloncall ALL=(ALL) NOPASSWD: /usr/bin/systemctl, /usr/bin/vim /etc/llwl-report/report.conf
```

Three defects:

1. **It grants nobody anything.** The group `llwloncall` does not exist and Nadia does not exist.
   `sudo -l -U llwlnadia` is the instrument. Luke may either create a group by that name or use his
   own name for it in the rule he writes — the checks care about what Nadia can do, not what the
   group is called.
2. **`/usr/bin/systemctl` with no arguments constrained.** Any subcommand: mask the firewall,
   disable auditing, `systemctl edit` into a root-owned unit.
3. **An editor on a config file.** `sudo vim` → `:!/bin/sh` → root. And even with the shell escape
   disallowed, `report.conf` is sourced by the service, so write access is code execution as
   `llwlreport`.

Luke replaces it with a minimal rule — full paths, explicit arguments, a `Cmnd_Alias`, `NOPASSWD`
scoped to just that — validated with `visudo -cf` *before* it is in place, and mode `0440`.

## Tiers

### Tier 1 — the people

Named files and named accounts, as lab 1's tier 1 does, because this is the tier where he is
learning the tools rather than the diagnosis.

Create `llwlnadia` properly. Fix Mira's shell. Fix Toby's expiry and his home directory's
ownership. Then `id`, `getent passwd`, `groups`, and the lab-1 callback that a shell only learns
its groups at start.

Checks: each account exists; each can actually start a login shell (behavioural —
`sudo -u <user> -i true`); no home directory is owned by a uid with no name.

### Tier 2 — one tree, two teams

Symptoms only from here, per lab 1's convention.

Group design, ownership, setgid on `alpha/` and `beta/`; then `shared/` and ACLs. Stated plainly
rather than left as a puzzle, because it is cruel otherwise: **a `chmod` after a `setfacl` silently
rewrites the ACL mask**, and the `+` at the end of `ls -l`'s mode column is the only hint an ACL
exists at all.

Checks, all behavioural, all through `sudo -u`:

- Mira can create a file in `alpha/`; it comes out owned by the team group without her doing
  anything (proves setgid, not a one-off `chown`).
- Mira creates a file in `shared/`; **Toby can read it** (proves a *default* ACL — a single
  `setfacl -R` over existing files does not pass) and **cannot write to it**.
- A third account (`llwlreport`) can neither list nor traverse `shared/`.
- `alpha/` and `beta/` are mutually inaccessible.

### Tier 3 — delegate one power

1. Find out why the on-call rule grants nobody anything (`sudo -l -U`, `visudo -c`).
2. Make it work for Nadia.
3. **Exploit it.** Become root through the rule as Nadia, with his own hands. This is not optional
   colour; it is the moment "least privilege" stops being a phrase. The README walks him to the
   door (`sudo -l` first, then think about what each permitted program can do) without naming
   `:!sh`.
4. Rewrite it to the minimum. `visudo -cf` on a temporary copy first, `0440`, full paths, explicit
   arguments.

Checks:

- Nadia **can** restart `llwl-report` with no password prompt (behavioural: restart it and confirm
  the service's start time moved).
- Nadia **cannot** stop, mask, or disable an unrelated unit.
- Nadia **cannot** read `secrets.env`.
- Nadia **cannot** write `report.conf`.
- The exact escape from step 3, replayed, now fails.
- `visudo -c` is clean, and the drop-in is `0440 root:root`.

## Scaffolding

### `check.sh`

Runs as Luke, not root — same contract as lab 1, and lab 1's `check.sh` already escalates with
`sudo -n`/`sudo -v` internally for the tiers that need it. Lab 2 needs it from tier 1 onward
because impersonating other users requires root. Reuse lab 1's preflight block verbatim in spirit,
with the message adjusted, and `die` with a pointer to `visudo -c` if `sudo` itself is broken.

`./check.sh [1|2|3]`, `refuse_root`, symptoms not fixes, exit 0 when solved.

### `lib/common.sh` additions

Capability probes, since the whole lab is checked by capability:

- `as_user <user> -- <cmd...>` — thin wrapper over `sudo -u <user> --` for readability.
- `can_user_read <user> <path>`, `can_user_write <user> <path>`, `can_user_traverse <user> <dir>`
- `can_user_create <user> <dir>` — actually creates a probe file and cleans it up as root.
- `can_user_login <user>` — `sudo -u <user> -i true`. **Verify in a VM** that this actually fails
  for an *expired* account and not only for a `nologin` shell; `sudo` runs PAM's account phase, so
  it should, but if it does not, fall back to `su - <user> -c true` or to parsing `chage -l`. Tier
  1's second defect is untestable if this probe is blind to expiry.
- `acl_of <path>` — `getfacl --absolute-names --omit-header`.
- `sudo_permits <user> <cmd...>` — asks the policy via `sudo -l -U`, without running anything.
- `uid_of <user>`, `uid_has_name <uid>`.

Follow the existing house style: comment the *why*, long flags, plain bash, written to be read.

### `teardown.sh`

Extends lab 1's pattern. New manifest kind `home <path>`, and users now need `userdel --remove`.
Because that deletes home directories as root, the allow-list check gets stricter, not looser:

- Refuse `userdel --remove` unless the account name matches `^llwl[a-z]+$` **and** its home
  directory resolves under `/home/llwl*`. If either fails, `userdel` without `--remove` and warn
  loudly, leaving the directory for a human.
- The path allow-list gains `/srv/llwl-report`, `/etc/llwl-report`, `/var/log/llwl-report`,
  `/var/lib/llwl-report`, `/srv/llwl-projects`, `/etc/systemd/system/llwl-report.service`,
  `/etc/sudoers.d/llwl-oncall`.
- Groups Luke invented are not in the manifest and must not be guessed at. Teardown prints the
  `getent group | grep` command for him to review by hand instead. Deleting groups a human created,
  by pattern match, as root, is exactly the class of thing this course teaches people not to do.

The new `home` manifest kind also needs adding to the "Adding a lab" conventions in
`exercises/README.md`, alongside the existing `path`/`unit`/`user`/`group` list, so the next lab
inherits it rather than reinventing it.

This is the highest-risk file in the lab and should be reviewed as such.

## Safety

- **`setup.sh` must never write an invalid or non-`0440` file into `/etc/sudoers.d/`.** A sudoers
  file that sudo rejects can, depending on version, take away the learner's ability to `sudo` at
  all — on his own daily-driver machine. The mode-`0440` convention is taught as a stated ground
  rule and asserted by `check.sh` on Luke's *own* file; it is never planted as a defect. The
  implementation must verify in a throwaway VM that a freshly planted lab leaves `sudo -v` working.
- `setup.sh` keeps lab 1's promise: it only ever creates new paths. It must not touch
  `/etc/sudoers`, any pre-existing drop-in, `/etc/login.defs`, or `/etc/skel`.
- The README repeats the sudoers danger rules: never edit a sudoers file with a plain editor,
  always `visudo -cf` a copy before it goes live, keep a second root shell open while you work.
- Timeshift snapshot advice as in lab 1.
- All account impersonation in `check.sh` goes through `sudo -u`/`-i` from root, so Luke never needs
  to know or set these users' passwords.

## Deliverables asked of Luke

1. `exercises/lab2/solutions/luke.sh` — takes a freshly planted lab to all-green in one run.
2. `notes/lab2-luke.md`, answering:
   - What the `+` in `ls -l` means, and what `getfacl` shows that `ls -l` cannot.
   - Why a default ACL rather than a script that re-runs `setfacl` every night.
   - The exact escape he used to become root, and the specific property of his rewritten rule that
     closes it.
   - Why a `sudoers` drop-in is `0440` and not `0644`.
   - Why ownership being a number and not a name matters when you restore a backup.
   - What he would type first if someone said "the new hire can't log in."
3. Read `solutions/bennett.sh` afterwards and argue with it.

## Curriculum change

`README.md`'s ladder currently promises lab 2 = processes and services, lab 5 = filesystems, lab 6 =
users and sudoers. Luke has read that table, so it gets rewritten to eight rows, one story each:

| Lab | What breaks |
|---|---|
| 1 | permissions, on a service that will not start |
| 2 | **users, groups, ACLs, delegated sudo** |
| 3 | processes and services |
| 4 | text as data |
| 5 | shell scripting for real |
| 6 | disks and filesystems |
| 7 | networking and SSH |
| 8 | capstone |

Splitting the old "disks and networking" row also gives the filesystem material a lab where it is
the subject rather than a passenger — `losetup`, `mkfs`, mount units, and the
prove-it-before-you-reboot habit (`findmnt --verify`, `nofail`) — at a point where Luke has the
shell fluency for it. `sudoers` moving to lab 2 leaves lab 7 as key-only SSH and why SSH refuses
your private key.

`exercises/README.md` also needs one edit: the lab-contract table says `check.sh` runs as you, not
root, which stays true, but should note that it will ask for `sudo` once because verifying what
*other* people can do requires it.

## Out of scope, deliberately

- **Filesystems, `mkfs`, `losetup`, `fstab`.** Different mental model; it gets lab 6.
- **`umask` and `/etc/skel`.** Real, but a third of a tier's payoff, and it would blur the lab's
  one story. Candidate for a lab-2 stretch goal later.
- **Password and account policy beyond expiry** (`passwd -l`, `/etc/shadow` fields in depth).
  Belongs with SSH in lab 7. Account *expiry* is in scope only because it is a planted symptom.
- Quotas, PAM configuration, LDAP, `sudo` I/O logging.
