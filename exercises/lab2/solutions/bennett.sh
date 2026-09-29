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

# ... tiers appended by later tasks ...

info "lab 2 solved. Run ./check.sh as yourself."
