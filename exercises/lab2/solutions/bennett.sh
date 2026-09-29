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
# does not have to be listable by strangers.
chown root:root /srv/llwl-projects
chmod 0755 /srv/llwl-projects

# ... tiers appended by later tasks ...

info "lab 2 solved. Run ./check.sh as yourself."
