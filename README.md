# LLWL

A mentored, hands-on Linux course that runs on your own machine. Not tutorials you follow along
with: things that are actually broken, on a real Ubuntu install, that you have to fix and then
explain.

The aim is the thing employers actually screen for — you can be handed a Linux box that isn't
working and make it work, and you can say afterwards what you did and why. That skill is
unfakeable, and it's the whole reason this repo is labs and not lessons.

## What's here

```
exercises/    the labs. Start with exercises/lab1.
notes/        your write-up for each lab: notes/lab<n>-luke.md
vimgolf/      editor practice, for fun. Optional, take it or leave it.
```

## Start here

```bash
git clone git@github.com:bennetthunter10/LLWL.git
cd LLWL
cat exercises/README.md          # the workflow, once — it's the same for every lab
cat exercises/lab1/README.md     # then lab 1
```

Read `exercises/README.md` before you touch anything. It covers the four scripts every lab has, the
branch-and-PR flow, and the two rules that keep you from having to reinstall Ubuntu.

## The ladder

| Lab | What breaks | What you come out knowing |
|---|---|---|
| **1** | A deployed service that won't start | the shell, `ls -l`, `chmod`, `chown`, `find -perm`, `stat`, `systemctl`, `journalctl`, groups, setgid, sticky bit |
| 2 | Processes and services | writing your own systemd unit, `enable`/`mask`, restart policies, debugging a crash loop, timers vs cron |
| 3 | Text as data | `grep`, `cut`, `sort`, `uniq`, `awk`, `xargs`, pipes — answering real questions about a real 100k-line log |
| 4 | Shell scripting for real | `set -euo pipefail`, `trap`, argument parsing, `--dry-run`, a backup script on a timer |
| 5 | Disks and networking | `apt` vs `dpkg`, filesystems and `/etc/fstab`, `ip`, `ss`, `curl`, `ufw` |
| 6 | Users and SSH | users, groups, `sudoers` drop-ins, key-only SSH, and why SSH refuses your private key |
| 7 | Capstone | take a bare VM to a live TLS website — nginx, systemd, firewall — with a runbook good enough for someone else to follow |

Roughly the ground the RHCSA and Linux+ certifications cover, in the order you'd actually hit it on
the job. If a certificate turns out to be useful to you later, you'll have done the work already.

## How mentoring works

You work a lab alone until you're either done or genuinely stuck. You open a PR with your fix as a
script plus your notes. I review the PR and we talk about the interesting parts.

Being stuck is not a failure state — it's the part where the learning happens. The only bad outcome
is being stuck for an hour and *not* learning anything, so ping me at that point. Everything before
that, sit in it.

## vimgolf

Separate, optional, and just for fun: `vimgolf/` has holes where you turn `start_file.txt` into
`end_file.txt` in as few keystrokes as possible, with my attempt in the directory to beat. Use
whatever editor you like for the labs themselves — `vim`, `nvim`, `hx`, `nano`, VS Code. Nobody has
ever been hired for their editor.
