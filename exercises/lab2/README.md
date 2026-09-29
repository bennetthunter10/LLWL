# Lab 2 — Onboard the Team: Users, Groups, and One Delegated Power

**Skills:** `useradd`, `usermod`, `chage`, `gpasswd`, `id`, `getent`, setgid (recap), `visudo`,
`sudo -l`, `setfacl`
**Time:** tier 1 in an evening. All three tiers over a week or two. Tier 4 whenever you feel like
it, including never. There is no prize for rushing.

## The situation

The team grew. Three people need accounts on this machine, and the admin who left made a mess of
two of them on the way out.

- **`llwlmira`** — an operator on project *alpha*. Already exists. Cannot log in.
- **`llwltoby`** — an operator on project *beta*. Already exists. Also cannot log in, for a
  completely different reason, and the home directory has a problem on top of that.
- **`llwlnadia`** — the on-call junior. Does not exist at all. You create her.

Both operators need to be able to read the reporting service's credentials, because operating it
is their job. Each needs a working directory for their project that the other team cannot get
into. And the two of them together should be able to hand the tree to a new colleague in six
months without it having rotted in the meantime.

Nadia needs exactly one privileged power: **restart `llwl-report.service`**, with no password, at
3am, without waking anybody (tier 3 says exactly how the command has to be spelled). That is the whole grant. In particular:

> **Being on call is not the same thing as being trusted with the credentials.** Nadia must not be
> able to read `/etc/llwl-report/secrets.env`, and she must not be able to touch any other service
> on this machine. She is the person who bounces the thing when the pager goes off. She is not an
> operator, and she has not been given the keys.

That distinction is a judgement call, not a law of nature, and you are going to be asked to defend
it in your notes. It is also the reason tier 3 exists.

The previous admin already left a `sudo` rule behind that was meant to grant Nadia's one power.
It is in `/etc/sudoers.d/llwl-oncall` and it has two problems. Today it grants nobody anything.
The moment you make it work, it turns out to grant far more than its comment claims.

### Group names are yours to invent

You are given the three people and what each of them must be able to *do*. **The group structure
is your design problem.** Make as many groups as you like and call them what you like.

`check.sh` follows suit: nearly every check in it asks "can this account do this thing", never "is
there a group called *x*". There is no name to guess and no number to match. Read the whole
checker if you want — it tells you what is wrong and never how to fix it — but you cannot get
green by reading it. The only way through is to make the machine actually behave.

The three *usernames*, on the other hand, are fixed. `teardown.sh` needs to know exactly which
accounts it is allowed to delete, and "the ones the lab named" is the only safe answer to that.

## Before you start

```bash
sudo ./setup.sh        # plants the lab (safe to re-run any time to reset it)
./check.sh 1           # see where you stand
```

- **Take a Timeshift snapshot first**, the first time. `setup.sh` only ever creates new files,
  accounts and units, and never touches anything that was already on your system; `sudo
  ./teardown.sh` removes all of it. A snapshot still costs you two minutes and buys you the
  freedom to be fearless.
- Work as **yourself**, and reach for `sudo` only for the specific command that needs it.
- Run `./check.sh` as yourself, **not** with `sudo`. It will ask for your password once, up front
  (or not at all, if you used `sudo` a minute ago), because the only honest way to test what
  *other* people's accounts can do is to become them, and that needs root.
- You never need any of these three people's passwords. They do not have any. Everything you want
  to try as them, you do with `sudo -u <user> ...` from your own account.

### The sudoers rules, which are the only way this lab can cost you an evening

Tier 3 has you editing a file that decides who is allowed to be root. Get it wrong and `sudo`
stops working — on your own machine, the one you are reading this on. Three rules, and they are
not optional:

1. **Never edit a sudoers file with a plain editor.** Not `vim /etc/sudoers.d/llwl-oncall`, not
   `nano`, not anything. `visudo` exists precisely because a syntax error in these files is
   catastrophic, and it refuses to install one.
2. **Always validate a copy before it goes live.** Write your new rule somewhere harmless, check
   it, and only then move it into place:

   ```bash
   sudo visudo --check --file=/tmp/llwl-oncall.new     # prints "parsed OK" or tells you the line
   sudo install --owner=root --group=root --mode=0440 /tmp/llwl-oncall.new /etc/sudoers.d/llwl-oncall
   sudo visudo -c                                      # and now check the whole configuration
   ```

   That last step is not paranoia. A file can parse perfectly on its own and still break the
   configuration it joins — an alias name that collides with one in `/etc/sudoers` only fails when
   they are read together. `setup.sh` does exactly this dance before it plants anything, and
   `solutions/bennett.sh` does it again; both are worth reading as the pattern.
3. **Keep a second terminal open with a root shell** (`sudo -i`) for the whole of tier 3, and do
   not close it until `sudo visudo -c` is clean. A root shell that is already open stays root even
   if `sudo` stops working. That turns "I have to reinstall" into "I fix it in the other window".

One more constraint, and it is a lab thing rather than a Linux thing: **your rule has to stay at
`/etc/sudoers.d/llwl-oncall`.** That exact path is what `teardown.sh` knows it owns, and it will
not go hunting through `/etc/sudoers.d` for files it did not write. Replace the contents all you
like; leave the name alone.

## Where things live

| Path | What it is |
|---|---|
| `/etc/systemd/system/llwl-report.service` | the reporting service — the one Nadia is on call for |
| `/srv/llwl-report/run.sh` | its program (working; not your problem this time) |
| `/etc/llwl-report/report.conf` | its configuration |
| `/etc/llwl-report/secrets.env` | its credentials — already locked down correctly |
| `/var/log/llwl-report/` | its log |
| `/etc/systemd/system/llwl-audit.service` | a second service that does nothing. See tier 3 |
| `/srv/llwl-projects/alpha/` | project alpha's working directory |
| `/srv/llwl-projects/beta/` | project beta's working directory |
| `/srv/llwl-projects/shared/` | shared between the two teams. Tier 4 only |
| `/etc/sudoers.d/llwl-oncall` | the rule the previous admin left behind |

Neither service is broken. Lab 1 was about fixing a service; this one is about who is allowed to
restart it.

## Tier 1 — the people

Named accounts and named commands, this once, because this is the tier where you are learning the
tools rather than the diagnosis. Start by looking:

```bash
getent passwd | grep llwl
./check.sh 1
```

**Nadia does not exist.** Create her. She is a human being who will log into this machine at 3am,
which tells you most of what her account needs and distinguishes it from `llwlreport` — the
service account in that same `getent` output. Compare the two lines when you are done, field by
field; the contrast is the lesson.

The other two exist and are wrong:

1. **Neither of them can start a login shell, and the two reasons have nothing to do with each
   other.** One of them is sitting in plain sight in the `getent passwd` output you just ran — an
   account shaped like a daemon's, given to a person. The other does not appear in that output at
   all, nor in `ls`, nor in `id`. It lives in a field of `/etc/shadow` that only root can read,
   and there is a command whose whole job is to print that file's aging fields in English.

   A gotcha, stated plainly because it would be cruel as a puzzle. The obvious way to test
   "can this person log in" is:

   ```bash
   sudo -u <user> -i true; echo $?
   ```

   On **one** of these two accounts that command exits `0` — it says yes — and the account still
   cannot log in.

   The reason is worth getting exactly right, because the near-miss version of it gets repeated
   a lot. `sudo` does not look at the account's shell and form an opinion. It *runs* it, and
   `/usr/sbin/nologin` is a real program whose whole job is to print `This account is currently
   not available.` and exit non-zero (`man 8 nologin` — "politely refuse a login"). So the probe
   catches that account by walking straight into the refusal, not by checking anything. Nothing
   on that path consults an expiry date, and the other account has a perfectly ordinary
   `/bin/bash` that runs `true` and exits `0`.

   Put two tools side by side on an expired account and the difference is stark. (`su` is
   wrapped in `sudo` only so it does not stop to ask for a password nobody has; `-c true` keeps
   it from opening an interactive shell.)

   ```
   $ sudo -u <expired-user> -i true; echo $?
   0
   $ sudo su - <expired-user> -c true
   Your account has expired; please contact your system administrator.
   su: Authentication failure
   ```

   (`sudo -u ... -i` may also print some complaints about the home directory. Those are the
   *other* problem, below, and they do not change the exit status.) So: when the probe and the
   aging fields disagree, the aging fields are right.

2. **One of the two home directories has an owner that is not a person.** Run `ls -l /home` and
   look hard at the owner column: where every other row has a name, one row has a bare number.
   That is not a formatting quirk. Ownership on a Linux filesystem *is* a number — `/etc/passwd`
   is just the lookup table that turns it into a name, and there is no entry for this one.
   `ls -ln` prints every row as the number it really is, which makes the odd one out easier to
   compare; `stat -c '%U %u %n' /home/*` is blunter still and will print `UNKNOWN` next to it.
   The directory came off a backup from a machine whose users were numbered differently.

   Fixing it is `chown`, but read `man chown` for `--from=` before you reach for `-R`. On a real
   restored home directory there will be files in there that are legitimately owned by somebody
   else, and `--from=` is how you rewrite only the ownership that is actually wrong.

3. **Mira and Toby are operators; Nadia is not.** Operating the reporting service means reading
   its credentials, so both operators must be able to read `/etc/llwl-report/secrets.env` and
   Nadia must not. Look at who owns that file and what its mode is before you decide how. You are
   not being asked to change that file — lab 1 already got it right.

Then run `id` on each of them and on yourself, and remember lab 1's sting in the tail: a process
gets its group list when it starts and never updates it. If you add yourself to something today,
your current shell will go on not knowing about it until you log out and back in.

**Worth reading:** `man useradd` — `-r/--system` versus leaving it off, `-m/--create-home`,
`-s/--shell`, and above all the difference between `-g/--gid` (the account's *primary* group) and
`-G/--groups` (everything else). `man usermod` and its `-a/--append` flag, and what happens if you
forget the `-a`. `man chage`, especially `-l/--list` and `-E/--expiredate`. `man 5 passwd` for the
seven colon-separated fields you have been staring at, and `man 5 shadow` for the eighth field of
*that* file, which is described under "account expiration date" and is where your second problem
actually lives.

**Verify:** `./check.sh 1`

## Tier 2 — the project directories

Symptoms and requirements only from here on, like you would get from a colleague rather than from
a ticket with the answer in it.

`/srv/llwl-projects/alpha/` and `/srv/llwl-projects/beta/` are what you get when somebody ran
`mkdir` and walked away: owned by root, readable by the world, no structure at all. The
requirements:

1. **Mira's team can read and write in `alpha/`; Toby's team can read and write in `beta/`.**
2. **Neither team can get into the other's directory** — not list it, not walk through it.
3. **The `llwlreport` service account cannot get into either.** A daemon has no business in a
   human's project directory, and "nobody happened to give it access" is not the same as "it
   cannot".
4. **Every file created in one of those directories from now on belongs to the project's group,
   without anybody remembering to make it so.** This is the one that matters in six months. A
   directory that is correct today and relies on people being careful is a directory that will be
   a patchwork by spring.

Requirement 4 is lab 1's setgid bit, and you already know it — this is the tier where you *use*
what you learned rather than learn it again. `check.sh` proves it the only honest way: it creates
a real file as a real user and looks at what group it came out as. A one-off `chgrp -R` will not
pass, because it says nothing about tomorrow.

Two things stated plainly rather than left as puzzles:

- **Changing a directory's group does not change the group of the files already inside it.** Each
  of these directories was planted with a seed file in it. That file predates whatever you do to
  the directory and still carries the old group. When you think you are finished, run
  `sudo ls -l /srv/llwl-projects/alpha` and `sudo ls -l /srv/llwl-projects/beta`. It needs `sudo`,
  and it needs the full path rather than a `cd` first, because once tier 2 is right you are on
  neither team: you cannot enter those directories, so neither `cd` nor a plain `ls` will work.

  Nothing in `check.sh` looks at those two files. You can leave them wrong and still go green.
  I am telling you that rather than adding a check for it, because the more useful lesson is the
  one underneath: **a green checker means the things somebody thought to check are right, not
  that the system is.** Every monitoring dashboard you will ever be handed has this property. The
  thing that bites you in a year is the file nobody wrote a check for.
- **The parent, `/srv/llwl-projects/` itself, has to stay traversable** or nothing underneath it is
  reachable by anyone. Leaving it `0755` is a perfectly defensible choice: it means any user on the
  machine can list it and see that `alpha` and `beta` exist. That is a real disclosure and you
  should make it deliberately rather than by accident. The two directories' own permissions are
  what decide who gets *inside* them.

And a design question, which is the actual work of this tier: how many groups is this? One per
project? One for "everybody on a project"? Something cleverer? Whatever you choose, be able to
say in your notes what you rejected and why.

One preference of mine, offered as a preference and not as a rule: I like the design where
`getent group <name>` can answer "who is on alpha". That quietly rules something out. A group
that is somebody's **primary** group does not list them in the member field of `/etc/group` —
make `llwlalpha` Mira's primary group and `getent group llwlalpha` comes back with an empty
member list, while `id llwlmira` shows the membership plainly. Both designs can pass tier 2 —
every check asks what the accounts can *do*, not what anything is called — but neither of them
gets to skip the setgid bit. Make the team group Mira's primary group and leave the bit off, and
her new files come out with that group because it is *hers*, not because the directory said so;
the first colleague you add to the team gets none of it. The question the check is really asking
is what a *colleague's* file would inherit tomorrow, so in exactly that case it falls back to
looking for the bit.
But "who is on this project" is a question somebody will ask you at 4pm on a Friday, and a design
where the answer is one command is worth something.

**Worth reading:** `man chmod` — the section headed **SETUID AND SETGID BITS**, and what the `2`
in `2770` is doing that the `0` in `0770` is not. `man gpasswd` (`-a/--add`, `-d/--delete`) for
changing who is in a group without rewriting the whole membership list. `man newgrp` for the other
half of lab 1's group-list gotcha.

**Verify:** `./check.sh 2`

## Tier 3 — delegate one power

There is a rule in `/etc/sudoers.d/llwl-oncall`. Read it — reading it is safe, changing it is the
part that needs care. Re-read the three sudoers rules in **Before you start** before you touch
anything, and open that second root shell now.

Four beats, in order:

1. **Find out why it currently grants nobody anything.**

   ```bash
   sudo -l -U llwlnadia     # what does the policy say this account may run?
   sudo visudo -c           # does the configuration parse?
   ```

   `sudo -l -U <user>` is the instrument for this whole tier: it asks the policy a question and
   runs nothing at all. Note that its answer when the account does not exist at all is different
   from its answer when the account exists and is granted nothing — both are useful, and you will
   see the first of them if you run it before you have finished tier 1.

   `visudo -c` will tell you every file parsed OK, and that is the clue rather than the
   disappointment: **the planted rule is not broken, it is inert.** A syntax checker validates
   grammar, not meaning. A rule can name a group that does not exist on this machine and parse
   perfectly, because sudo has no opinion about whether the words in your policy refer to
   anything. There are two separate reasons nobody is getting anything from this rule today. Find
   both.

2. **Make it work for Nadia.** The rule names a group. You may create a group by that name, or
   rename the group in the rule to one of your own — the checker cares about what Nadia can do,
   not what anything is called. When you are done, `sudo -l -U llwlnadia` should list something,
   and Nadia should be able to restart `llwl-report` with no password.

   One fact about sudoers you need before you write any rule of your own: **it matches the command
   and its arguments as literal text, unless you use wildcards.** `systemctl restart llwl-report` and `systemctl restart
   llwl-report.service` are the same thing to systemd and two different commands to the policy. A
   rule that permits one does not permit the other. `check.sh` restarts the service as Nadia with
   the **short name**, `sudo -n systemctl restart llwl-report`, which is also what a person
   half-awake at 3am will type, so your rule has to permit that spelling (permitting the long one
   as well does no harm). I am dictating the invocation for the same reason I dictated the
   drop-in's path: so that you are not left guessing what is being tested, and so that the thing
   you learn is about sudo rather than about my checker.

3. **Read what it actually grants, and then prove it.** This is the beat that matters, so do not
   skip it on the grounds that the rule looks fine.

   Run `sudo -l -U llwlnadia` again and read the command it lists — really read it, out loud,
   including what is *not* written after it. Then, as Nadia:

   ```bash
   sudo -u llwlnadia sudo -n systemctl stop llwl-audit
   systemctl is-active llwl-audit
   ```

   Two `sudo`s, and they are doing different jobs: the first one is you becoming Nadia, and the
   second one is the power she has been granted. `-n` means "never prompt for a password", which
   is how you can tell the grant did the work rather than your own credentials.

   It works. `llwl-audit.service` has nothing to do with Nadia, nothing to do with the reporting
   service, and nothing to do with the comment at the top of the rule that says "so that whoever
   is on call can bounce the reporting service".

   Put it back:

   ```bash
   sudo -u llwlnadia sudo -n systemctl start llwl-audit
   systemctl is-active llwl-audit
   ```

   Do put it back. `check.sh` has a line that fails if `llwl-audit` is not running, precisely
   because the tier invites you to stop it, and an experiment you forgot to undo is a thing that
   makes every later result a lie.

   **`llwl-audit.service` exists for exactly this demonstration and does nothing else.** Its
   `ExecStart` is a `sleep`. The lab plants it so that you can watch an over-broad rule be
   over-broad without going anywhere near a service that matters. **Do not try any of this against
   `ssh`, `ufw`, `systemd-journald`, or anything else on the machine that is not `llwl-*`.** You
   would learn nothing you have not just learned, and you could take your network, your firewall
   or your logging down doing it.

   Now go back and read the rule a third time, and ask what *else* it permits. You can ask the
   policy directly without running anything, which is the safe way to explore the shape of a
   grant:

   ```bash
   sudo -l -U llwlnadia "$(command -v systemctl)" poweroff
   ```

   If the policy permits that, `sudo -l` echoes the command back and exits 0. If it does not, it
   prints nothing and exits non-zero — so check `echo $?` rather than reading silence as "it did
   nothing". Either way it does not run the command; nothing reboots. Try a few others and get a
   feel for the size of what you are looking at.

4. **Rewrite it to the minimum.** One power: restart the reporting service. Nothing else, for
   nobody else, on no other unit. Validate a copy first, install it `0440 root:root` at
   `/etc/sudoers.d/llwl-oncall`, then `sudo visudo -c` the whole configuration.

   When you are done, that same `stop llwl-audit` command from beat 3 must be refused. What a
   refusal looks like is `sudo: a password is required`, rather than anything as clear as
   "permission denied": the rule no longer matches, `sudo` falls back to asking who this is, and
   `-n` means it cannot ask. Nadia has no password, so that is a wall.

   `./check.sh 3` also asks the policy — not just the behaviour — whether Nadia could still run
   an arbitrary `systemctl` subcommand, using the same `sudo -l -U <user> <command>` form you
   just used. A rule that happens to behave today but still says "any arguments" does not pass.
   It asks about the unit as well as the verb. A rule that pins the subcommand and wildcards the
   unit — `systemctl restart *` — refuses `stop` and `poweroff` and still restarts anything on the
   machine, `ssh` included, so it does not pass either. (Careful with the other half of that: a
   rule ending `systemctl restart`, with nothing at all after the verb, is not "restart anything".
   Arguments were specified, so that is the only argument list it permits — the "any arguments"
   rule is the one with *no* arguments written, which is the planted one.)

The `0440 root:root` is not decoration, and `check.sh` asserts both halves of it. A sudoers file
is a file that decides who is root, so the rules about who may edit it are enforced by sudo
itself — and, usefully for you, they are enforced in two different places with two different
levels of strictness. Worth knowing which is which:

- **`sudo` at runtime skips a drop-in it does not trust** — one that is world-writable, or not
  owned by root — and warns about it on every single invocation (`sudo: /etc/sudoers.d/llwl-oncall
  is world writable`). Your rule does nothing, and the reason is right there in the noise above
  the prompt, which is exactly where people do not read.
- **`visudo -c` is stricter than that.** It insists on precisely `0440 root:root` and says so:
  `bad permissions, should be mode 0440`. A merely group-writable drop-in is one sudo will happily
  still obey — and one you should not have written, because the point of the mode is that the set
  of people who can rewrite your sudo policy is the set of people who are already root.

So `0440 root:root` is the setting that satisfies both, and "sudo would have accepted something
looser" is not a reason to write something looser.

**Worth reading:** `man 5 sudoers`, and specifically two things. First, `Cmnd_Alias`: you do not
strictly need one for a single command, but it gives the grant a name, and a named rule is one a
human can review in a year. Second, and this is the whole of beat 3, one sentence: go to
**SUDOERS FILE FORMAT** → **Aliases**, find the paragraph that begins "A `Cmnd_List` is a list of
one or more commands, directories, or aliases", and read it to the end. It contains this: *"If no
command line arguments are specified, the user may run the command with any arguments they
choose."* Read that twice and then look at the planted rule again. `man visudo` for `-c/--check`
and `-f/--file`. `man sudo` for `-l/--list` and `-U/--other-user`.

**Verify:** `./check.sh 3`, and then `./check.sh` for tiers 1 to 3 together.

## Tier 4 (optional) — when mode bits run out

**This tier is optional.** A bare `./check.sh` is green without it and you have finished the lab
without it. Come back to this one when you want it, or when you want something to argue about on
the pull request. It needs a package that may not be installed:

```bash
sudo apt install acl
./check.sh 4
```

`/srv/llwl-projects/shared/` is the handbook both teams work from. The requirement:

1. **Alpha's team can read and write in it.**
2. **Beta's team can read it and cannot write in it.**
3. **Nobody else gets in at all**, including the `llwlreport` service account.
4. **All three of those hold for files created tomorrow**, not just for what is in there today.

Try to express that with `chmod` and `chown` first. Genuinely try — five minutes with a pen is
worth more than being told. You have an owner, one group, and "other", and you have three parties
who each need something different. The wall you hit is the point of the tier.

Two things you should not have to discover by suffering:

- **`ls -l` shows a `+` after the mode when a file or directory carries an ACL**, and that plus
  sign is the entire warning. There is no other marker, no extra column, and no message. On a
  solved tier 4, `ls -l /srv/llwl-projects` shows the `+` on `shared` and not on `alpha` or
  `beta`. When you see one, `ls` has stopped being the whole truth and `getfacl` is where the
  rest of it is.

- **Once an ACL exists, the group digit of `chmod` — and the group column of `ls -l` — is no
  longer the owning group's permission. It is the ACL's *mask*.** The mask is a ceiling on every
  named entry and on the owning group's entry alike. So `chmod 2750 shared/` does not delete an
  ACL entry or edit one: it drops the mask to `r-x`, and from that moment every entry that asked
  for `w` is capped at what the mask allows. `getfacl` shows you this honestly with an
  `#effective:` comment, which is a thing `ls` will never tell you:

  ```
  group::rwx              #effective:r-x
  group:<your-beta-group>:r-x
  mask::r-x
  ```

  Alpha can no longer create files, and `ls -l` shows you a perfectly ordinary-looking
  `drwxr-s---+` that explains nothing. `chmod 2700` takes the mask to `---` and locks beta out
  too. The reassuring part: none of it is destructive. `chmod 2770` puts the mask back to `rwx`
  and every named entry comes back exactly as it was, because they were never altered — only
  capped. And the `default:` entries, including `default:mask`, are not touched by a `chmod` on
  the directory at all.

  The practical rule: after you `chmod` anything that has an ACL, run `getfacl` on it and look for
  `#effective:`. And be suspicious of any script that `chmod`s a whole tree.

The `check.sh 4` test for requirement 4 is the same shape as tier 2's: it creates a real file as
Mira and asks whether Toby can read it. It creates that file under a restrictive `umask` on
purpose, so a file that happens to be world-readable will not sneak past. The only thing that
makes that pass is inheritance.

**Worth reading:** `man setfacl` — `-m/--modify`, `-d/--default`, `-R/--recursive`, `-b`, and the
note on `-n/--no-mask` explaining that `setfacl` recalculates the mask for you unless you say
otherwise. `man getfacl` for how to read the output, including the `#effective:` comments.
`man 5 acl` for two sections worth the detour: **CORRESPONDENCE BETWEEN ACL ENTRIES AND FILE
PERMISSION BITS**, which is where the mask rule above is actually written down, and **OBJECT
CREATION AND DEFAULT ACLs**, which is requirement 4.

**Verify:** `./check.sh 4`

## Deliverables

Once `./check.sh` is all green:

1. **`solutions/luke.sh`** — your fix as a script that can be re-run from scratch. Prove it:

   ```bash
   sudo ./teardown.sh && sudo ./setup.sh
   sudo ./solutions/luke.sh
   ./check.sh                   # all green, from nothing, in one shot
   ```

   Getting a permission right by hand once is a shell command. Getting a machine into a
   known-good state with a script somebody else can run is the job.

2. **`../../notes/lab2-luke.md`** — in your own words:

   - The group structure you chose and why, including what you rejected.
   - Why the project directories are setgid, and what goes wrong over six months without it.
   - What the planted `sudo` rule actually permitted, in your own words, and the specific property
     of your replacement that stops it.
   - Why a `sudoers` drop-in is `0440` and not `0644`.
   - Why ownership being a number and not a name matters when you restore a backup.
   - What you would type first if someone said "the new hire can't log in."
   - *(if you did tier 4)* What the `+` in `ls -l` means, and why a default ACL rather than a
     script that re-runs `setfacl` every night.

3. Read `solutions/bennett.sh` afterwards and argue with it. The group design in there is one
   answer out of several reasonable ones, and disagreeing with it well is a better outcome than
   matching it.

Then commit, push, and open the PR — see `../README.md` for the flow.

## What's next

You have just built a project tree for two teams. Before you tear the lab down, ask the question
nobody asks until it is too late: **where does it actually live?**

```bash
df -h /srv/llwl-projects
sudo du -sh /srv/llwl-projects/*
```

(`sudo` on the second one, because you did tier 2 properly and you are not on either team.)

`df` answers with the filesystem the path is on, not the path. On a stock Ubuntu install that
answer is `/` — the same filesystem as `/var/log`, `/var/cache/apt`, and your own home directory.
One pool of space, and everything on this machine is drinking from it. Nothing whatsoever stops
project alpha writing until that pool is empty.

And a full `/` does not politely fail the thing that filled it. It takes the whole machine down:
the journal cannot write, `apt` cannot unpack, services that check-point to disk die on startup,
and depending on what got truncated on the way you may not be able to log in and clean up.
"The disk filled" is one of the most common serious outages there is, and the usual cause is one
directory nobody had drawn a boundary around.

Lab 3 draws the boundary. The projects get their own filesystem, with their own size, mounted
where they already live — so that alpha filling up is alpha's problem and nobody else's. `df`,
`du`, and the question "what happens when this fills" are the whole of what you need to carry
forward.

## When you're finished

```bash
sudo ./teardown.sh
```

That removes the accounts, the services, the project tree and the sudoers drop-in, and leaves the
machine as it was.

**It will not delete the groups you invented**, and that is deliberate: you made them, this lab
has no record of what you called them, and a script that deleted groups by guessing at a name
pattern, as root, on your machine, is exactly the class of thing this course is teaching you not
to write. `teardown.sh` prints the command to list what is left so you can clean up by hand.

Or leave the lab planted and break it on purpose to see what happens — `sudo ./setup.sh` resets it
whenever you want.
