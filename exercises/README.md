# Exercises

Each lab is a directory (`lab1`, `lab2`, …). A lab breaks something real on your own Ubuntu machine
and you fix it. You always get a way to check yourself and a way to undo everything.

## The lab contract

Every lab ships the same four scripts, so you only have to learn the workflow once:

| Script | Run as | What it does |
|---|---|---|
| `setup.sh` | `sudo` | Plants the lab. Only ever **creates** new paths — never touches a file that was already on your system. Records everything in `/var/lib/llwl-labs/<lab>.manifest`. Re-run it any time to reset the lab. |
| `check.sh` | **you**, not root | Tells you what is still wrong, in symptoms rather than fixes. `./check.sh` runs everything, `./check.sh 2` runs one tier. Exit code 0 means solved. |
| `teardown.sh` | `sudo` | Removes everything from the manifest and leaves the machine as it was. |
| `solutions/bennett.sh` | `sudo` | My answer. Read it *after* you're green, then argue with it. |

Ground rules that hold for every lab:

- Take a **Timeshift snapshot** before your first `setup.sh`. These labs use real system paths and
  real `sudo` on purpose — that's the whole point — and a snapshot means a mistake costs you a
  reboot instead of an evening.
- Work as yourself; `sudo` the one command that needs it rather than living in a root shell.
- Never `chmod -R` or `chown -R` a path you haven't looked at first.
- Reading `check.sh` is fine. It's bash, reading bash is a skill, and it never tells you the fix.
- Stuck for more than 30 minutes with nothing new learned? Ask me. Stuck for 30 minutes and still
  finding things out? Keep going — that part is the lab working correctly.

## The workflow

```bash
git switch -c lab1-luke

sudo ./exercises/lab1/setup.sh
cd exercises/lab1
./check.sh 1                  # ... solve ... repeat until green
./check.sh

# write up your answer as a re-runnable script, and prove it works from scratch
sudo ./teardown.sh && sudo ./setup.sh
sudo ./solutions/luke.sh && ./check.sh

git add exercises/lab1/solutions/luke.sh notes/lab1-luke.md
git commit -m "lab1: <one line on what you learned>"
git push -u origin lab1-luke
gh pr create --fill        # or open it in the browser
```

Then I review the PR. That's the point of doing it this way: you get feedback with the actual
commands in front of both of us, on your schedule rather than only when we're both free, and you
learn git as a side effect of learning Linux. Every real infrastructure job is a git workflow
wearing a trench coat.

Two things go in every PR:

1. **`solutions/luke.sh`** — the fix as a script, not a description of a fix. It must take a
   freshly-planted lab to all-green in one run.
2. **`../notes/lab1-luke.md`** — what each command did, in your own words, plus whatever
   surprised you. Write it for yourself in a year, when you've forgotten all of this and need it at
   2am.

## Adding a lab

Copy the shape of `lab1`. Conventions:

- Directory `lab<n>`, no zero padding — matching the `hole1` naming in `vimgolf/`.
- Scripts are `#!/usr/bin/env bash` with `set -euo pipefail`, and they `source ../lib/common.sh` for
  output helpers (`pass`, `fail`, `section`, `note`, `finish`) and permission helpers (`mode_of`,
  `has_bits`, `session_has_group`, …). Don't re-roll those.
- These scripts are teaching material as much as tooling — the learner will read them. Comment the
  *why*, use long flags (`--gid`, not `-g`), and keep them boring.
- `setup.sh` must be idempotent, must only create new paths, and must write a manifest.
- `teardown.sh` must check every path it deletes against an allow-list before `rm -rf`, because it
  runs as root. See `lab1/teardown.sh` for the pattern.
- `check.sh` reports symptoms, never fixes, and at least one check per lab should be **behavioural**
  — actually exercise the thing rather than compare a number, so it can't be gamed.
