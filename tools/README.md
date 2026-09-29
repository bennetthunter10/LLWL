# tools/

Development tooling for people *writing* labs. Learners never need anything in here.

## vmtest.sh

The repo's test suite. Labs are Ubuntu and systemd; development is usually not, so every lab is
verified inside a disposable Ubuntu machine rather than on your laptop.

    tools/vmtest.sh lab1            # assert lab1 is well-formed
    tools/vmtest.sh lab2 --keep     # ... and leave the synced repo in the machine to poke at

A lab is well-formed when it plants cleanly, fails its own checker afterwards, goes green under
`solutions/bennett.sh`, breaks again when re-planted from the solved state, and tears down without
a trace. Run it before opening a PR that adds or changes a lab.

The machine is created on demand and named `llwl-test`. Delete it with `orb delete llwl-test`.

Get a shell in it with `orb -m llwl-test`. Run root-requiring lab scripts the way a learner does,
with `sudo`, not `orb -u root`: the latter leaves `SUDO_USER` unset, which some labs read.

## shellcheck

Every script in the repo is expected to be clean. Run it from the repo root, with the source path
set so the `source "$HERE/../lib/common.sh"` lines can be followed:

    shellcheck -x --source-path=SCRIPTDIR \
        exercises/lab*/*.sh exercises/lab*/solutions/*.sh exercises/lib/common.sh tools/*.sh

Do not disable a warning to make it pass. If one is genuinely wrong for a line, disable that line
only, with a comment saying why (see step 0 of `vmtest.sh`).

## test-common.sh

Unit tests for `exercises/lib/common.sh`. Run inside the machine:

    orb -m llwl-test sudo /tmp/llwl/tools/test-common.sh
