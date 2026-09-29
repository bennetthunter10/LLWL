# Lab 2 — Onboard the team: users, groups, project directories, and delegated sudo

**Status:** approved design, ready for an implementation plan
**Date:** 2026-08-30 · **Revised:** 2026-09-29
**Learner:** Luke (second lab; first lab was permissions and a broken service deploy)

## Why this lab, and why here

Lab 1 ends on a cliffhanger the learner does not realise is one: he adds himself to `llwlops`,
runs `id`, and the group is not there. He has just met group membership as a real mechanism. The
next question a person actually asks is "so how do I make an account, and how do I let somebody do
one root thing without handing them the whole machine."

Lab 2 answers that. The team grows, he creates the people and designs the groups, he builds the
project directories they share, and he takes a `sudo` rule that grants far more than it claims and
cuts it down to the one power it was supposed to give.

This displaces "processes and services" from slot 2. See **Curriculum change** below.

## Tone

This is the learner's second lab ever, on his own daily-driver machine. The lab teaches least
privilege by making over-privilege *visible*, not by walking him through a root shell. There is no
privilege-escalation exercise — an earlier draft had him break out of `sudo vim` with `:!/bin/sh`
and that is the wrong register for a beginner. The same lesson lands when he discovers that the
on-call account can stop a service it has no business touching.

## Learning objectives

By the end, Luke can:

1. Create a human account correctly and say how it differs from a service account —
   `useradd` vs `useradd --system`, `--create-home`, `--shell`, `-G` vs `-g`.
2. Diagnose "this person cannot log in" from symptoms, using `getent`, `id`, `chage -l`,
   `sudo -u X -i`, and by reading `/etc/passwd` and `/etc/shadow` as data.
3. Understand that file ownership is a **number**, not a name, and recognise what an orphaned uid
   looks like (`ls -ln`, `chown --from=`).
4. Design a group structure from a set of requirements, rather than being handed one, and build a
   shared project tree that stays correct as people add files to it (setgid).
5. Read a `sudoers` rule and say what it *actually* permits as opposed to what its comment claims,
   then write the minimal rule that grants the intended power and nothing else — validated with
   `visudo -cf` before it goes live.
6. *(optional tier)* Express an access requirement that mode bits cannot express, using POSIX
   ACLs — including default ACLs as the inheritance mechanism, the `+` in `ls -l`, and the way a
   later `chmod` rewrites the ACL mask.

## Premise

`llwl-api` survived lab 1 and the team grew. Three people need accounts:

- **`llwlmira`** — operator, project *alpha*.
- **`llwltoby`** — operator, project *beta*.
- **`llwlnadia`** — the on-call junior. Needs exactly one privileged power: restart the reporting
  service. Nothing else — in particular she should not be able to read the service's credentials
  or interfere with any other service on the machine.

The same departed admin left a `/etc/sudoers.d/` drop-in that was meant to grant Nadia's one
power. It grants nobody anything today, and the moment you make it work it turns out to grant far
more than its comment claims.

`llwlops` carries over from lab 1 as the group of humans who operate a service, and in lab 2 it is
the group permitted to read the service secret. So the requirement is not just "make three
accounts": Mira and Toby are operators and belong to it, and **Nadia does not** — she is on call,
which is not the same thing as being trusted with the credentials. That distinction is the point of
tier 3's "cannot read `secrets.env`" check, and it is a judgement call worth making Luke defend in
his notes.

**The lab is self-contained.** `setup.sh` plants its own services and its own paths, so lab 2 runs
whether or not lab 1 is still planted. It reuses the group name `llwlops` for continuity of story
but creates it itself if absent.

### Usernames are dictated; group names are Luke's to invent

Luke is given the three people and what each must be able to do. **The group structure is his
design problem.** He may create as many groups as he likes and name them what he likes.

Consequently `check.sh` verifies **capabilities, not names**: "can `llwltoby` read this file",
never "is there a group called `llwlbeta`". This is a deliberate strengthening of the lab-1
convention that at least one check be behavioural — here essentially every check is, which makes
the lab ungameable by reading `check.sh`.

Usernames stay fixed so `teardown.sh` knows exactly which accounts it is permitted to delete.

## What `setup.sh` plants

### Two services (working, not broken)

Lab 2 is not about fixing a service. Both units start correctly and are enabled from the start;
they exist so there is something real to delegate a restart on, and something real that the
delegation must *not* reach.

- **`llwl-report.service`** — the service Nadia is on call for. System account `llwlreport`
  (`--system`, `nologin`, no home), deliberately the same shape as lab 1's `llwlapi` so tier 1 has
  a contrast case. `/srv/llwl-report/run.sh` is a small heartbeat loop — keep it shorter than lab
  1's `run.sh`; it is scenery, not subject matter.
- **`llwl-audit.service`** — a second trivial unit that exists for exactly one reason: it is the
  thing Nadia can stop under the planted rule and must not be able to stop under Luke's. Having a
  lab-owned unit to demonstrate over-reach against means the demonstration never touches a real
  system service. See **Safety**.
- `/etc/llwl-report/report.conf` — ordinary configuration, read by `run.sh`.
- `/etc/llwl-report/secrets.env` — `0640 root:llwlops`, i.e. already correct per lab 1's lesson.
  Tier 3 asserts Nadia cannot read it.
- Both unit files `0644 root:root`, enabled and started.

### The two broken accounts

| Account | Planted defect | What it teaches |
|---|---|---|
| `llwlmira` | login shell is `/usr/sbin/nologin`; no supplementary groups | a human account created as if it were a service account |
| `llwltoby` | `--expiredate` set in the past | accounts expire; `chage -l` is the only place this is visible |
| `llwltoby` | home directory owned by an orphaned numeric uid | ownership is a number, not a name |

`llwlnadia` is **not** created. Luke creates her from scratch — the build half of tier 1.

For the orphaned uid, `setup.sh` picks the first unused uid in the range 61000–61999 (checked with
`getent passwd`) and records it in the manifest, so that a re-plant reproduces the same state and
so a human reading the manifest can see where the odd number came from.

### The project tree

`/srv/llwl-projects/{alpha,beta}`, planted as `root:root 0755` with a seed file in each — the state
you get when somebody ran `mkdir` and walked away. The requirements Luke must satisfy:

- `alpha/` — Mira's team read/write; **files created in it later must belong to the team group
  automatically** (setgid, recapping lab 1 rather than re-teaching it); nobody else may enter.
- `beta/` — the same, for Toby's team.
- The two must be mutually inaccessible.

`/srv/llwl-projects/shared/` is planted too, but its requirement belongs to the optional tier 4
below. If Luke never does tier 4, it just sits there as a directory nobody can use — which is
itself an honest state of affairs and a fine place to leave it.

### The sudoers drop-in

`/etc/sudoers.d/llwl-oncall`, planted at valid mode `0440 root:root` (see **Safety** — this is not
negotiable), containing roughly:

```
# so that whoever is on call can bounce the reporting service at 3am
%llwloncall ALL=(ALL) NOPASSWD: /usr/bin/systemctl
```

Two defects:

1. **It grants nobody anything.** The group `llwloncall` does not exist and Nadia does not exist.
   `sudo -l -U llwlnadia` is the instrument. Luke may either create a group by that name or use his
   own name for it in the rule he writes — the checks care about what Nadia can do, not what the
   group is called.
2. **The command has no arguments constrained**, so "restart the reporting service" is really "any
   `systemctl` subcommand against any unit on the machine". Once Luke has made the rule work for
   Nadia, the README asks him to run `sudo -l -U llwlnadia`, read what it actually says, and then
   demonstrate it: as Nadia, stop `llwl-audit.service` — a service she has no business touching —
   and watch it succeed. Then start it again. That is the whole security lesson, and it costs
   nothing and breaks nothing.

Luke replaces the rule with a minimal one: full path, explicit arguments, a `Cmnd_Alias`,
`NOPASSWD` scoped to just that, mode `0440`, validated with `visudo -cf` on a copy *before* it goes
live.

## Tiers

Tiers 1–3 are the lab. Tier 4 is optional and `./check.sh` is green without it.

### Tier 1 — the people

Named accounts and named tools, as lab 1's tier 1 does, because this is the tier where he is
learning the commands rather than the diagnosis.

Create `llwlnadia` properly. Fix Mira's shell. Fix Toby's expiry and his home directory's
ownership. Then `id`, `getent passwd`, `groups`, and the lab-1 callback that a shell only learns
its groups at start.

Checks: each account exists; each can actually start a login shell (behavioural —
`sudo -u <user> -i true`); no home directory is owned by a uid with no name; Mira and Toby are
operators, Nadia is not.

### Tier 2 — the project directories

Symptoms only from here, per lab 1's convention.

Group design, ownership, and setgid on `alpha/` and `beta/`. This is where his lab-1 knowledge gets
*used* rather than retaught, and where he first has to invent structure instead of repairing it.

Checks, all behavioural, through `sudo -u`:

- Mira can create a file in `alpha/`; it comes out owned by the team group without her doing
  anything (proves setgid, not a one-off `chown`).
- Toby can do the same in `beta/`.
- Neither can list or traverse the other's directory.
- `llwlreport` can reach neither.

### Tier 3 — delegate one power

1. Find out why the on-call rule grants nobody anything (`sudo -l -U`, `visudo -c`).
2. Make it work for Nadia.
3. Read what it *actually* grants, and demonstrate the gap harmlessly: as Nadia, stop
   `llwl-audit.service`, then start it again. Nothing in the rule was supposed to allow that.
4. Rewrite it to the minimum. `visudo -cf` on a temporary copy first, then `0440`, full path,
   explicit arguments.

Checks:

- Nadia **can** restart `llwl-report` with no password prompt (behavioural: restart it and confirm
  the service's start time moved).
- Nadia **cannot** stop, mask, or disable `llwl-audit.service` — the same command that worked in
  step 3 now fails.
- Nadia **cannot** read `secrets.env`.
- `visudo -c` is clean, and the drop-in is `0440 root:root`.

### Tier 4 — optional: when mode bits run out

Clearly marked optional in the README, and skipped by a bare `./check.sh`. For when he wants it,
or for when Bennett wants to talk about it on a PR.

`shared/` states a requirement mode bits cannot express: read-write for alpha, **read-only for
beta**, and no access at all for anybody else — including for files created tomorrow. Three
parties, one group slot. That wall is the lesson, and the README should let him hit it rather than
announcing it.

Stated plainly rather than left as a puzzle, because it is cruel otherwise: **a `chmod` after a
`setfacl` rewrites the ACL mask**, and the `+` at the end of `ls -l`'s mode column is the only hint
an ACL exists at all.

Checks: Mira creates a file in `shared/`; Toby can read it (proves a *default* ACL — a one-off
`setfacl -R` over existing files does not pass) and cannot write it; `llwlreport` can neither list
nor traverse.

## What's next — the storage preview

A short closing section in the lab README, not a tier and not checked. He has just built a project
tree for two teams; the obvious next question is where it actually lives.

```bash
df -h /srv/llwl-projects
du -sh /srv/llwl-projects/*
```

The point to land, in a paragraph: that tree is on the root filesystem, sharing space with his
logs, his packages, and his home directory, and nothing whatsoever stops project alpha filling the
disk for everybody including the OS. Give the real-world version — a full `/` takes the whole
machine down, not just the greedy directory — and say that lab 3 gives the projects their own
filesystem and their own boundary. `df`, `du`, and the question "what happens when this fills" are
all he needs to carry forward.

## Scaffolding

### `check.sh`

Runs as Luke, not root — same contract as lab 1, and lab 1's `check.sh` already escalates with
`sudo -n`/`sudo -v` internally for the tiers that need it. Lab 2 needs it from tier 1 onward
because impersonating other users requires root. Reuse lab 1's preflight block in spirit, with the
message adjusted, and `die` with a pointer to `visudo -c` if `sudo` itself is broken.

`./check.sh` runs tiers 1–3 and exits 0 when those are solved. `./check.sh 4` runs the optional
ACL tier; a bare run prints one line noting that tier 4 exists and was not run, so it is
discoverable without being a gate. `refuse_root`, symptoms not fixes.

### `lib/common.sh` additions

Capability probes, since the whole lab is checked by capability:

- `as_user <user> -- <cmd...>` — thin wrapper over `sudo -u <user> --` for readability.
- `can_user_read <user> <path>`, `can_user_write <user> <path>`, `can_user_traverse <user> <dir>`
- `can_user_create <user> <dir>` — actually creates a probe file and cleans it up as root.
- `can_user_login <user>` — `sudo -u <user> -i true`. **Verify in a VM** that this actually fails
  for an *expired* account and not only for a `nologin` shell; `sudo` runs PAM's account phase, so
  it should, but if it does not, fall back to `su - <user> -c true` or to parsing `chage -l`. Tier
  1's second defect is untestable if this probe is blind to expiry.
- `sudo_permits <user> <cmd...>` — asks the policy via `sudo -l -U`, without running anything.
- `uid_of <user>`, `uid_has_name <uid>`.
- `acl_of <path>` — `getfacl --absolute-names --omit-header`. Tier 4 only.

Follow the existing house style: comment the *why*, long flags, plain bash, written to be read.

### `teardown.sh`

Extends lab 1's pattern. New manifest kind `home <path>`, and users now need `userdel --remove`.
Because that deletes home directories as root, the allow-list check gets stricter, not looser:

- Refuse `userdel --remove` unless the account name matches `^llwl[a-z]+$` **and** its home
  directory resolves under `/home/llwl*`. If either fails, `userdel` without `--remove` and warn
  loudly, leaving the directory for a human.
- The path allow-list gains `/srv/llwl-report`, `/etc/llwl-report`, `/var/log/llwl-report`,
  `/var/lib/llwl-report`, `/srv/llwl-projects`, `/etc/systemd/system/llwl-report.service`,
  `/etc/systemd/system/llwl-audit.service`, `/etc/sudoers.d/llwl-oncall`.
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
- **The over-reach demonstration targets a lab-owned unit only.** The README names
  `llwl-audit.service` explicitly and never invites him to try the rule against `ssh`, `ufw`,
  `systemd-journald`, or anything else real. A beginner following instructions should not be able
  to stop something that matters.
- No privilege-escalation exercise. Nothing in this lab asks the learner to obtain a root shell.
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
   - The group structure he chose and why, including what he rejected.
   - Why the project directories are setgid, and what goes wrong over six months without it.
   - What the planted `sudo` rule actually permitted, in his own words, and the specific property
     of his replacement that stops it.
   - Why a `sudoers` drop-in is `0440` and not `0644`.
   - Why ownership being a number and not a name matters when you restore a backup.
   - What he would type first if someone said "the new hire can't log in."
   - *(if he did tier 4)* What the `+` in `ls -l` means, and why a default ACL rather than a script
     that re-runs `setfacl` every night.
3. Read `solutions/bennett.sh` afterwards and argue with it.

## Curriculum change

`README.md`'s ladder currently promises lab 2 = processes and services, lab 5 = filesystems, lab 6 =
users and sudoers. Luke has read that table, so it gets rewritten to eight rows, one story each:

| Lab | What breaks |
|---|---|
| 1 | permissions, on a service that will not start |
| 2 | **users, groups, project directories, delegated sudo** |
| 3 | storage and filesystems |
| 4 | process management |
| 5 | text as data |
| 6 | shell scripting for real |
| 7 | networking and SSH |
| 8 | capstone |

Storage moves to 3 so it lands immediately after lab 2's closing question about where the project
tree lives, and it gets a lab where it is the subject rather than a passenger — `df`, `du`,
`losetup`, `mkfs`, mount units, and the prove-it-before-you-reboot habit (`findmnt --verify`,
`nofail`).

Lab 4 becomes process management, framed the same way as the others: `setup.sh` starts processes
that make the machine noticeably slow without making it unusable, and he has to find them and kill
them — `top`/`htop`, `ps`, load average, `kill` vs `kill -9`, and what a runaway actually looks
like. **Design note for whoever specs it:** the load must be bounded by construction, not by good
intentions — a systemd slice with `CPUQuota=` and `MemoryMax=`, plus `nice`, so the lab cannot take
the machine down even if he walks away mid-lab.

`sudoers` moving to lab 2 leaves lab 7 as key-only SSH and why SSH refuses your private key.

`exercises/README.md` also needs one edit: the lab-contract table says `check.sh` runs as you, not
root, which stays true, but should note that it will ask for `sudo` once because verifying what
*other* people can do requires it.

## Out of scope, deliberately

- **Privilege escalation of any kind.** See **Tone**.
- **Filesystems, `mkfs`, `losetup`, `fstab`.** Previewed at the end of lab 2, specced as lab 3.
- **`umask` and `/etc/skel`.** Real, but a third of a tier's payoff, and it would blur the lab's
  one story.
- **Password and account policy beyond expiry** (`passwd -l`, `/etc/shadow` fields in depth).
  Belongs with SSH in lab 7. Account *expiry* is in scope only because it is a planted symptom.
- Quotas, PAM configuration, LDAP, `sudo` I/O logging.
