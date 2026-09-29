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
chgrp --recursive llwlalpha /srv/llwl-projects/alpha
chgrp --recursive llwlbeta /srv/llwl-projects/beta
chmod 0660 /srv/llwl-projects/alpha/README /srv/llwl-projects/beta/README

# The parent has to be traversable or nothing below it is reachable, but it
# holds nothing secret, so 0755 is fine: anybody can see that alpha and beta
# exist, and the two directories' own modes decide who can get inside them.
chown root:root /srv/llwl-projects
chmod 0755 /srv/llwl-projects

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

# The rule names a group, and nobody was in it. Nadia goes in.
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
	{ rm -f "$dropin_tmp"; die "my replacement rule does not parse; leaving the old one alone"; }
install --owner=root --group=root --mode=0440 "$dropin_tmp" /etc/sudoers.d/llwl-oncall
rm -f "$dropin_tmp"

# And the whole configuration, with the new file in it. If this fails, the
# root shell you kept open is how you get back in.
visudo --check --quiet || die "sudo configuration broke; fix it from the root shell you kept open"

# ... tiers appended by later tasks ...

info "lab 2 solved. Run ./check.sh as yourself."
