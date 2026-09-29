#!/usr/bin/env bash
#
# LLWL lab 2 -- setup
#
# Plants the state of a team that just grew: two services, two accounts that
# were created carelessly, a project directory nobody has organised, and a sudo
# rule the previous admin left behind.
#
#     sudo ./setup.sh
#
# Same two promises as lab 1:
#   1. It only ever CREATES new paths and accounts. It never modifies anything
#      that was already on your system -- in particular it never touches
#      /etc/sudoers or any drop-in it did not write.
#   2. Everything is recorded in /var/lib/llwl-labs/lab2.manifest and removed
#      completely by ./teardown.sh
#
# Idempotent: re-run it at any time, including from a fully solved lab, to put
# the machine back in its original broken state.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=../lib/common.sh
source "$HERE/../lib/common.sh"

REPORT_SVC=llwl-report
AUDIT_SVC=llwl-audit
REPORT_USER=llwlreport
OPS_GROUP=llwlops

APP_DIR=/srv/llwl-report
CONF_DIR=/etc/llwl-report
LOG_DIR=/var/log/llwl-report
PROJ_DIR=/srv/llwl-projects
REPORT_UNIT=/etc/systemd/system/$REPORT_SVC.service
AUDIT_UNIT=/etc/systemd/system/$AUDIT_SVC.service
SUDOERS_DROPIN=/etc/sudoers.d/llwl-oncall

LAB_STATE=/var/lib/llwl-labs
MANIFEST=$LAB_STATE/lab2.manifest

need_linux
need_root
# Everything below this line that is not a shell builtin. The whole list is
# asked for before the first change, because the alternative is a tool that
# turns out to be missing halfway through: under set -e that leaves a
# half-planted lab, and this script writes to /etc/sudoers.d. One line of
# refusal before anything is touched is worth a great deal more than that.
need_cmd systemctl
need_cmd useradd
need_cmd usermod
need_cmd userdel  # reached through delete_user, when Nadia is reset away
need_cmd groupadd
need_cmd gpasswd
need_cmd chage
need_cmd install
need_cmd visudo

# ---------------------------------------------------------------------------
# 0. Whose is the sudoers drop-in? Decided before anything is changed, and
#    before the manifest below is rewritten.
#
#    This lab promises never to modify a file it did not create, and
#    /etc/sudoers.d is the last place to break that promise. The filename is
#    fixed, but that is no licence to clobber somebody else's file. So: if the
#    manifest from a previous plant claims the drop-in, the lab made it and a
#    re-plant may replace it; if it does not exist, the lab will make it; if it
#    exists and nobody here claims it, stop and leave it exactly as it is.
#    (Same idea as the llwlops group in section 2, and it has to be settled
#    early for the same reason: the manifest is rewritten every run, and a
#    refusal that happened after that would leave a claim on somebody else's
#    file.)
# ---------------------------------------------------------------------------

if [[ -d $SUDOERS_DROPIN ]]; then
	# install would copy the rule INTO a directory and report success, planting
	# nothing, and the whole-config check would pass for want of a rule to break.
	die "$SUDOERS_DROPIN is a directory. Move it aside (sudo mv $SUDOERS_DROPIN $SUDOERS_DROPIN.orig) and run setup.sh again."
fi
if [[ -e $SUDOERS_DROPIN || -L $SUDOERS_DROPIN ]]; then
	if ! { [[ -f $MANIFEST ]] && grep --quiet --line-regexp --fixed-strings "path $SUDOERS_DROPIN" "$MANIFEST"; }; then
		die "$SUDOERS_DROPIN already exists and this lab did not create it. It will not overwrite a sudoers file it does not own. Move it aside (sudo mv $SUDOERS_DROPIN $SUDOERS_DROPIN.orig) and run setup.sh again."
	fi
fi

# ---------------------------------------------------------------------------
# 1. Stop anything from a previous planting, so a re-run is a true reset.
# ---------------------------------------------------------------------------

for u in "$REPORT_SVC" "$AUDIT_SVC"; do
	systemctl is-active --quiet "$u" 2>/dev/null && systemctl stop "$u"
done

# ---------------------------------------------------------------------------
# 2. Service identity. llwlops carries over from lab 1: the humans who operate
#    a service. In this lab it is the group allowed to read the credentials.
# ---------------------------------------------------------------------------

# llwlops may already exist because lab 1 (or the learner) made it. This lab
# only records it in the manifest, and so only lets teardown delete it, if this
# lab created it. On a re-plant the group exists because the FIRST plant made
# it, so the previous manifest is read before it is overwritten and its answer
# is carried forward; otherwise a re-run would quietly disown the group.
OWNS_OPS_GROUP=no
if [[ -f $MANIFEST ]] && grep --quiet --line-regexp --fixed-strings "group $OPS_GROUP" "$MANIFEST"; then
	OWNS_OPS_GROUP=yes
fi
if ! getent group "$OPS_GROUP" >/dev/null; then
	groupadd --system "$OPS_GROUP"
	OWNS_OPS_GROUP=yes
fi
getent passwd "$REPORT_USER" >/dev/null || useradd \
	--system \
	--no-create-home \
	--home-dir /nonexistent \
	--shell /usr/sbin/nologin \
	--comment "LLWL lab 2 reporting service account" \
	"$REPORT_USER"

# ---------------------------------------------------------------------------
# 3. The reporting service. Nothing is wrong with it -- this lab is not about
#    fixing a service, it is about who is allowed to restart one.
# ---------------------------------------------------------------------------

mkdir -p "$APP_DIR" "$CONF_DIR" "$LOG_DIR" "$LAB_STATE"

cat >"$CONF_DIR/report.conf" <<'CONF'
# /etc/llwl-report/report.conf -- runtime configuration for llwl-report.
SERVICE_NAME="llwl-report"
TICK_SECONDS=5
CONF

cat >"$CONF_DIR/secrets.env" <<'SECRETS'
# /etc/llwl-report/secrets.env -- credentials for llwl-report.
# Readable by root and by the operators group. Being on call is not the same
# thing as being trusted with these.
REPORT_TOKEN="llwl-7b21e0c4a9-DEMO-NOT-A-REAL-SECRET"
SECRETS

cat >"$APP_DIR/run.sh" <<'RUNSH'
#!/usr/bin/env bash
# /srv/llwl-report/run.sh -- the llwl-report "daemon". Ticks, and says so.
set -euo pipefail
. /etc/llwl-report/report.conf
LOG=/var/log/llwl-report/report.log
echo "llwl-report: starting as $(id -un)"
while :; do
	printf '%s %s tick\n' "$(date -Is)" "${SERVICE_NAME:-llwl-report}" >>"$LOG"
	sleep "${TICK_SECONDS:-5}"
done
RUNSH

cat >"$REPORT_UNIT" <<UNITFILE
[Unit]
Description=LLWL practice reporting service (lab 2)
After=network.target

[Service]
Type=simple
User=$REPORT_USER
Group=$REPORT_USER
ExecStart=$APP_DIR/run.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNITFILE

cat >"$AUDIT_UNIT" <<'UNITFILE'
[Unit]
Description=LLWL practice compliance agent (lab 2)

# This unit does nothing, on purpose. It exists so that the lab has a service
# that the on-call account is NOT supposed to be able to touch -- which means
# you can prove an over-broad sudo rule is over-broad without going anywhere
# near a service that matters.

[Service]
Type=simple
ExecStart=/usr/bin/sleep infinity
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNITFILE

chown root:root "$APP_DIR/run.sh" "$CONF_DIR/report.conf" "$CONF_DIR/secrets.env"
chmod 0755 "$APP_DIR" "$CONF_DIR"
chmod 0755 "$APP_DIR/run.sh"
chmod 0644 "$CONF_DIR/report.conf"
chown root:"$OPS_GROUP" "$CONF_DIR/secrets.env"
chmod 0640 "$CONF_DIR/secrets.env"
chown "$REPORT_USER:$REPORT_USER" "$LOG_DIR"
chmod 0750 "$LOG_DIR"
chown root:root "$REPORT_UNIT" "$AUDIT_UNIT"
chmod 0644 "$REPORT_UNIT" "$AUDIT_UNIT"

systemctl daemon-reload
systemctl enable --now "$REPORT_SVC" >/dev/null
systemctl enable --now "$AUDIT_SVC" >/dev/null

# ---------------------------------------------------------------------------
# 4. The two accounts the previous admin made. Both are wrong, in ways that are
#    invisible from `ls` and almost invisible from `getent passwd`.
#
#    Every line here also RESETS state, because this script must put a fully
#    solved lab back to broken: creating an account only if it is missing would
#    leave a solved one solved.
# ---------------------------------------------------------------------------

# An unused uid, so that Toby's home directory ends up belonging to a number
# with no name behind it -- what you get when somebody restores a backup from a
# machine whose users were numbered differently.
pick_unused_uid() {
	local lo=$1 hi=$2 candidate
	for ((candidate = lo; candidate <= hi; candidate++)); do
		getent passwd "$candidate" >/dev/null && continue
		getent group "$candidate" >/dev/null && continue
		printf '%s\n' "$candidate"
		return 0
	done
	die "no unused uid available in the range $lo-$hi"
}
ORPHAN_UID=$(pick_unused_uid 61000 61999)

# Remove a user from every group but their own. Both accounts start out in
# nothing else, and a solved lab has put them in llwlops (and perhaps more).
#
# Two ways a re-plant could otherwise die here, both from a learner who solved
# the lab their own way. `id --groups` lists the PRIMARY group too, and gpasswd
# refuses to remove somebody from a group they are only in as a primary ("is
# not a member"); so the primary group is put back to the user's own first,
# which is what it was when planted. And a failing gpasswd is a warning, never
# the end of the reset.
strip_supplementary_groups() {
	local u=$1 g
	[[ $(id --name --group "$u") == "$u" ]] || usermod --gid "$u" "$u"
	for g in $(id --name --groups "$u"); do
		if [[ $g != "$u" ]]; then
			gpasswd --delete "$u" "$g" >/dev/null || warn "could not remove $u from $g; check with: id $u"
		fi
	done
}

# Created as if she were a service account: a shell that refuses logins, and no
# groups beyond her own.
getent passwd llwlmira >/dev/null || useradd \
	--create-home \
	--shell /usr/sbin/nologin \
	--comment "Mira -- operator, project alpha" \
	llwlmira
[[ $(login_shell_of llwlmira) == /usr/sbin/nologin ]] || usermod --shell /usr/sbin/nologin llwlmira
strip_supplementary_groups llwlmira

# Created correctly, then expired -- and his home directory came off a backup.
getent passwd llwltoby >/dev/null || useradd \
	--create-home \
	--shell /bin/bash \
	--comment "Toby -- operator, project beta" \
	llwltoby
[[ $(login_shell_of llwltoby) == /bin/bash ]] || usermod --shell /bin/bash llwltoby
chage --expiredate 2020-01-01 llwltoby
strip_supplementary_groups llwltoby
# The learner may have deleted the home outright (the checker has a message for
# that), and useradd only makes one for an account it creates.
[[ -d /home/llwltoby ]] || mkdir --mode 0750 /home/llwltoby
chown -R "$ORPHAN_UID:$ORPHAN_UID" /home/llwltoby

# Nadia does not exist. Creating her is the learner's job. If a previous run
# of the checker (or a solution) made her, she has to go, and delete_user is
# what copes with the login session the checker's probe left behind. Do not
# swallow a failure: a Nadia who survives makes tier 1 pass for the wrong reason.
delete_user llwlnadia || die "could not remove llwlnadia; log out of any session as her and re-run"

# ---------------------------------------------------------------------------
# 5. The project tree. Somebody ran mkdir and walked away: root owns all of it,
#    world-readable, no group structure at all. Nothing here is subtle, and
#    that is the point -- tier 2 is where the learner has to invent structure
#    rather than repair it.
#
#    Like section 4, every line RESETS. A solved lab has group-owned, setgid
#    directories; mkdir -p and cat alone would leave all of that standing.
#
#    What it deliberately does NOT touch is the groups the learner made to
#    solve this. They are theirs: the learner named them, designed them, and this script
#    never created them. (teardown.sh refuses to delete them for the same
#    reason.) Once the directories are back to root:root they are simply unused.
# ---------------------------------------------------------------------------

mkdir -p "$PROJ_DIR/alpha" "$PROJ_DIR/beta" "$PROJ_DIR/shared"

cat >"$PROJ_DIR/alpha/README" <<'SEED'
Project alpha. Mira's team.
SEED
cat >"$PROJ_DIR/beta/README" <<'SEED'
Project beta. Toby's team.
SEED
cat >"$PROJ_DIR/shared/handbook.md" <<'SEED'
Shared between both project teams. Alpha maintains it; beta reads it.
SEED

# A learner who reached for setfacl leaves access lists that outlive chmod and
# chown. Not every machine has the tool, and a machine without it cannot have
# any, so its absence is not an error.
if command -v setfacl >/dev/null; then
	setfacl --remove-all --recursive "$PROJ_DIR" || warn "could not clear ACLs under $PROJ_DIR; check with: getfacl --recursive $PROJ_DIR"
fi

chown --recursive root:root "$PROJ_DIR"
# The a-st half matters: a numeric 0755 on a directory leaves a setgid bit that
# is already there, and the setgid bit is exactly what tier 2 is about.
chmod a-st,u=rwx,go=rx "$PROJ_DIR" "$PROJ_DIR/alpha" "$PROJ_DIR/beta" "$PROJ_DIR/shared"
# Those four are the only directories this script creates, and a learner may
# have made more inside the tree with setgid bits of their own. "Every line
# here RESETS" has to be true of those too, or a re-plant leaves directories
# standing that still hand their group to every file made in them, in a lab
# that is supposed to be back to broken. Only s and t are stripped: the modes
# of the learner's own directories are theirs, and are not what tier 2 asks about.
find "$PROJ_DIR" -type d -exec chmod a-st {} +
chmod 0644 "$PROJ_DIR/alpha/README" "$PROJ_DIR/beta/README" "$PROJ_DIR/shared/handbook.md"

# ---------------------------------------------------------------------------
# 6. Manifest. Everything this lab OWNS, whether setup.sh created it or the
#    learner is expected to. teardown.sh checks each entry for existence, so
#    listing llwlnadia here is how she gets cleaned up even though she is the
#    learner's to create.
# ---------------------------------------------------------------------------

write_manifest() {
	local group_line=""
	[[ $OWNS_OPS_GROUP == yes ]] && group_line="group $OPS_GROUP"
	cat >"$MANIFEST" <<MANIFESTEOF
# LLWL lab 2 manifest -- every object this lab owns, in creation order.
# teardown.sh removes these in reverse. Kinds: path, unit, user, group, home, note.
unit $REPORT_SVC.service
unit $AUDIT_SVC.service
path $REPORT_UNIT
path $AUDIT_UNIT
path $SUDOERS_DROPIN
path $APP_DIR
path $CONF_DIR
path $LOG_DIR
path $PROJ_DIR
home /home/llwlmira
home /home/llwltoby
home /home/llwlnadia
user llwlmira
user llwltoby
user llwlnadia
user $REPORT_USER
$group_line
note orphanuid $ORPHAN_UID
MANIFESTEOF
	chmod 0644 "$MANIFEST"
}
write_manifest

# ---------------------------------------------------------------------------
# 7. The rule the previous admin left behind.
#
# Read the installation dance below carefully, because it is the pattern for
# writing any sudoers file from a script: build it somewhere harmless, have
# visudo parse it, and only then move it into place. A file in /etc/sudoers.d
# that sudo cannot parse can cost you sudo on the whole machine, and this lab
# refuses to be the thing that does that to somebody.
#
# This is the one file in the lab that RESETS rather than only creates, and only
# because section 0 established that the lab made it (the manifest claims it):
# on a re-run from a solved lab the learner's tightened rule has to give way to
# the over-broad one. A file the lab did not make never reaches this point. What is deliberately left alone: the llwloncall group the
# learner may have made. Like the project groups, it is theirs.
# ---------------------------------------------------------------------------

# Note: the manifest above already claims this path; if a die below leaves it absent, teardown copes.
SYSTEMCTL=$(command -v systemctl)

dropin_tmp=$(mktemp)
# Whatever happens below, do not leave the scratch copy lying around.
trap 'rm -f "$dropin_tmp"' EXIT

cat >"$dropin_tmp" <<DROPIN
# /etc/sudoers.d/llwl-oncall
#
# So that whoever is on call can bounce the reporting service at 3am without
# having to wake anybody up.
#
#   -- the previous admin, who no longer works here
%llwloncall ALL=(ALL) NOPASSWD: $SYSTEMCTL
DROPIN

# 1. Does this one file parse, on its own? If not, it never goes near /etc.
if ! visudo --check --quiet --file="$dropin_tmp"; then
	die "refusing to install a sudoers drop-in that visudo will not accept"
fi

# 2. install sets owner and mode as it writes, so there is no moment when the
#    file exists with the wrong ones. It also replaces whatever was there.
install --owner=root --group=root --mode=0440 "$dropin_tmp" "$SUDOERS_DROPIN"

# 3. Does the whole configuration still parse with it in place? If not, take it
#    straight back out -- a planted lab must never cost the learner their sudo.
if ! visudo --check --quiet; then
	rm -f "$SUDOERS_DROPIN"
	die "installing the drop-in broke sudo's configuration; removed it again"
fi

# ---------------------------------------------------------------------------
# 8. Briefing. Last, so that it only ever prints after every step above has
#    succeeded -- set -e means a failure anywhere never reaches this point, and
#    "Lab 2 is planted" should never appear over a half-planted lab.
# ---------------------------------------------------------------------------

cat <<BRIEF

${C_BOLD}Lab 2 is planted.${C_OFF}

  The team grew. Three people need accounts on this machine, two of them
  already exist and were made carelessly, and the previous admin left a sudo
  rule behind that does not do what its comment says.

  Start here:
      ./check.sh 1
      getent passwd | grep llwl
      sudo -l -U llwlnadia

  Read ./README.md for the tiers and the ground rules -- especially the ones
  about editing sudoers files, which are the only way this lab can cost you
  an evening.

  Undo everything at any time with:  sudo ./teardown.sh

BRIEF
