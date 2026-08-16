# Lab 1 — Rescue a Broken Service Deploy

**Skills:** the shell, `ls -l`, `chmod`, `chown`, `find`, `stat`, `systemctl`, `journalctl`, groups, setgid, sticky bit
**Time:** tier 1 in an evening. All three tiers over a week or two. There is no prize for rushing.

## The situation

A service called `llwl-api` is installed on this machine. It was deployed by an admin who has
since left the company. It does not work.

Nothing is wrong with its code and nothing is wrong with its systemd unit. **Every single problem
is a permission or an ownership.** That is not a hint I would normally give you — in real life you
have to find that out yourself — but it's true here, so spend your effort in the right place.

Three people care about this service:

- **`llwlapi`** — the unprivileged system account the service runs as. It has no password and no
  shell. It needs to read its config, read its secret, write its log, and write its state.
- **`llwlops`** — the group for humans who operate this service. That's you, eventually.
- **everyone else on the machine** — who should be able to read the config, and nothing more.

Your job, in one sentence: **make the service run, keep its secret secret, and be able to read its
log without typing `sudo`.**

## Before you start

```bash
sudo ./setup.sh        # plants the lab (safe to re-run any time to reset it)
./check.sh 1           # see where you stand
```

- **Take a Timeshift snapshot first**, the first time. You are about to run `chmod` and `chown` as
  root, which is how people break Linux installs. `setup.sh` only ever creates new files and never
  touches anything that was already on your system, and `sudo ./teardown.sh` removes all of it —
  but a snapshot costs you two minutes and buys you the freedom to be fearless.
- **Never type `chmod -R 777` or `chown -R` on a path you haven't looked at.** `-R` on the wrong
  directory as root is the single most common way to ruin a machine. Look, then act.
- Work as **yourself**, and reach for `sudo` only for the specific command that needs it. Living in
  a root shell is a habit worth not forming.
- Run `./check.sh` as yourself too, **not** with `sudo` — tier 3 tests what *your* account can do.
- Reading `check.sh` is allowed and encouraged. It's bash; reading other people's bash is the job.
  It tells you what's wrong, never how to fix it.

Where things live:

| Path | What it is |
|---|---|
| `/srv/llwl-api/run.sh` | the service program |
| `/srv/llwl-api/incoming/` | drop directory the service watches |
| `/etc/llwl-api/api.conf` | configuration |
| `/etc/llwl-api/secrets.env` | the API token |
| `/var/log/llwl-api/` | where the log goes |
| `/var/lib/llwl-api/` | where the service keeps its state |
| `/etc/systemd/system/llwl-api.service` | the unit file (this one is already correct) |

## Tier 1 — it will not even start

```bash
sudo systemctl start llwl-api
systemctl status llwl-api
```

Two problems, both in files I'll name for you this once: `/srv/llwl-api/run.sh` and
`/etc/llwl-api/api.conf`.

One of them stops the service dead. The other doesn't break anything at all today — it's a security
hole, and `check.sh` is the only thing that will complain. Work out which is which, and work out
*why* the second one matters. (Look at what `run.sh` does with `api.conf` on its first few lines.)

When the service gets further than it did before but still doesn't work, you've finished tier 1.

**Worth reading:** `man chmod` (specifically the difference between `chmod 644 f` and
`chmod g-w,o-w f`), `man ls`, and the `Mode` column in `stat -c '%A %a %U:%G %n' <path>`.

**Verify:** `./check.sh 1`

## Tier 2 — it starts, and then it dies

No file names from here on. You get symptoms only, like you would from a monitoring alert:

1. The service exits within a second of starting. **Find out why from the machine, not from me** —
   `systemctl status llwl-api` and `journalctl -u llwl-api -n 30` will tell you the exact path it
   couldn't use. Fix it, start it again, and it will fail on a *second* thing. That's normal; a
   broken system usually only shows you one problem at a time.
2. The API token in `/etc/llwl-api/secrets.env` can currently be read by every user on the machine.
   Lock it down **as far as you can while the service still starts.** There is a trap in here: the
   most locked-down thing you can type stops the service from working. Find the tightest setting
   that still works, and be able to explain the choice.
3. Somewhere under the deployment there is a file that any user on the system can write to. It is
   not in a directory you've been looking at. Don't hunt for it by eye — that doesn't scale to a
   real server with 40,000 files. Learn `find` instead: `man find`, and read the `-perm` section
   carefully, especially what the `/` prefix means (`-perm /o+w`) versus `-` versus neither.

**Worth reading:** `man find` (`-perm`, `-type`, `-print`), `man stat`, `man chown` (note the
`owner:group` form), and the thing nobody tells you: on a **directory**, `r` lets you list names
and `x` lets you actually go through it or touch anything inside. `x` without `r` is a real and
useful state. Try it on a scratch directory until it stops being surprising.

**Verify:** `./check.sh 2` — and `systemctl is-active llwl-api` should say `active` and stay that
way.

## Tier 3 — the bits nobody explains

The service runs now. But you still can't read its log without `sudo`, and you can't put a file in
its drop directory. Fix that *properly* — not by making things world-readable.

1. `/var/log/llwl-api/` should belong to the `llwlops` group, and **every log file created in it
   from now on should belong to that group too, automatically.** There is a bit for this. Find out
   what "setgid on a directory" means (`man chmod`, the `s` in `2750`).
2. `/srv/llwl-api/incoming/` is a shared drop box: every operator writes to it, and **no operator
   should be able to delete anybody else's file.** There is a bit for that too — go read what the
   `t` in `drwxrwxrwt` on `/tmp` is doing, and why `/tmp` would be a disaster without it. Two
   exceptions come with that bit, and knowing them is the difference between using it and
   understanding it: whoever owns a *file* can always delete their own, and whoever owns the
   *directory* can always delete anything in it. Once you've set it, prove both to yourself.
3. You are not in the `llwlops` group. Put yourself in it (`man gpasswd`, or `man usermod` and its
   `-aG` flag — note what happens if you forget the `a`). Then run `id` and notice something
   annoying: the group isn't there. A process gets its group list when it starts and never updates
   it, so your existing shell will never see it. Log out and back in, or `exec newgrp llwlops`.
   This costs people an hour of confusion exactly once in their career, and now it won't cost you
   one.
4. One gotcha, stated plainly because it's cruel to leave it as a puzzle: **changing a directory's
   group does not change the group of files that are already inside it.** If the service already
   wrote a log before you fixed the directory, that file still has the old group. Look at
   `ls -l /var/log/llwl-api/` and deal with it.

**The final test** is behavioural, not cosmetic: `check.sh` drops a real file into `incoming/` as
you, waits for the service to notice it, and then reads the log as you, without `sudo`. Matching
the numbers in `check.sh` won't pass this; the thing actually has to work.

**Verify:** `./check.sh`

## Deliverables

Once `./check.sh` is all green:

1. **`solutions/luke.sh`** — your fix as a script that can be re-run from scratch. Prove it:

   ```bash
   sudo ./teardown.sh && sudo ./setup.sh
   sudo ./solutions/luke.sh
   exec newgrp llwlops          # or log out and back in
   ./check.sh                   # all green, from nothing, in one shot
   ```

   Getting a permission right by hand once is a shell command. Getting a machine into a known-good
   state with a script somebody else can run is the job.

2. **`../../notes/lab1-luke.md`** — in your own words:
   - What each command you used actually did (not "chmod fixed it").
   - Why the log directory is `2750` and not `0750`, and not `2755`.
   - Why `0600 root:root` on `secrets.env` would be wrong even though it's "more secure".
   - The command you'd run *first* if a colleague said "the service is down" — and why that one.
   - Anything that surprised you. Those are the notes worth having in a year.

3. Read `solutions/bennett.sh` afterwards and argue with it. Some choices in there are judgement
   calls, not facts, and disagreeing with them well is a better outcome than matching them.

Then commit, push, and open the PR — see `../README.md` for the flow.

## When you're finished

```bash
sudo ./teardown.sh
```

Leaves the machine exactly as it was. Or leave the lab planted and break it again on purpose to see
what happens — `sudo ./setup.sh` resets it whenever you want.
