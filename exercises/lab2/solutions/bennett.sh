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
