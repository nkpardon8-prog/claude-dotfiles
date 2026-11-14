#!/bin/bash
# rd-rrfs: put the rd user's ~/rr on a reflink-capable XFS volume - a loop-mounted image file, no
# repartitioning - so the runner's package clone (`cp -a --reflink=auto`, rr_runner.pl clone_cmd) and the
# store save share blocks instead of copying them. ext4 has no reflink: there every "clone" copied the
# whole node_modules (hundreds of thousands of small files).
# Measured 2026-11-13, one real store entry (655-788 MB, 24-35k files), file data cold:
#   hp (SSD, ext4)    7.4-9.0 s + 3.2 s writeback   ->  XFS reflink 0.84 s + 0.26 s
#   laptop (WSL2)     33 s                          ->  XFS reflink 5.8-7.8 s (metadata-bound in the VM;
#                                                       live dentall store clones 6.1-10.4 s for 24-49k files)
#   mini-a (HDD)      24-27 s + 7.3 s writeback     ->  XFS reflink 2.9 s + 0.7 s
#
#   rd-rrfs status              one line: rr=<path> fs=<type> reflink=0|1 img=<path> img_gb=<n> staged=0|1 old=0|1
#   rd-rrfs create --gb N       xfsprogs, the image (sparse; refused when N could overcommit the disk, see
#                               max_gb), mkfs.xfs -m reflink=1, the rd-rrfs.service unit (enabled). Idempotent.
#   rd-rrfs presync             mount the image at STAGE and copy ~/rr into it while the worker runs (no locks).
#                               Repeatable: each pass is a delta. Never touches ~/rr.
#   rd-rrfs cutover             only when no slot is held: hold every slot lock, stop the timers that write
#                               ~/rr, final pass, move ~/rr to ~/rr.pre-xfs, mount the image at ~/rr, verify (xfs,
#                               a reflink probe, the rd user can write ~/rr and every dir in it), restart. A failed
#                               verify rolls back.
#   rd-rrfs mount               (rd-rrfs.service, at boot) attach + mount the image at ~/rr
#   rd-rrfs rollback            undo a cutover: unmount, put ~/rr.pre-xfs back (data written since is lost)
#   rd-rrfs drop-old            delete ~/rr.pre-xfs once ~/rr is the XFS mount (frees the old copy's disk)
#   rd-rrfs restore-nm          after a cutover by an older rd-rrfs: put back the node_modules it left out
#
# What the copy keeps (store / mirror names: rr_runner.pl deps_key, prepare_mirror):
#   * everything under ~/rr, exactly (rsync -aH) - never .trash (what rd-tune's prune is deleting);
#   * a mirror's npm node_modules (one with .rr-deps-stamp) whose stamp has a store entry is reflinked from
#     the store first, so only what runs wrote into it since is new data (see sync_mirrors);
#   * store entries (deps/<key>, written whole and never changed) are reflinked from the most recent copied
#     entry of the same package name, then made exact with `rsync --checksum` (npm stamps every package
#     file with one fixed 1985 mtime, so size+mtime cannot tell two installs apart). Only new entries are
#     copied on a later pass.
#   * on a later pass, a copied node_modules whose .rr-deps-stamp changed since is copied again from scratch
#     (the same 1985-mtime reason).
#   Each store entry / mirror starts only while the disk holding the image keeps RESERVE_GB free.
#
# The mountpoint under the volume is left empty, root-owned and immutable (chattr +i): when the volume is not
# mounted nothing can write there, so a missing mount fails runs loudly (runner `error rc=70`, which rd-doctor
# counts toward its drain) instead of silently filling the root disk with a cold ~/rr. rd-doctor also watches
# the disk under the image (a sparse image needs room to allocate).
# Rollback by hand: `rd-rrfs rollback` (before drop-old), or: systemctl disable --now rd-rrfs; chattr -i ~rd/rr.
# Env: RD_RRFS_USER (else tune.conf's RD_USER, else rd); RD_DU_CMD (prints what `du -sxk ~/rr` does: an operator
# who already knows ~/rr's size can skip a slow du on create). Test hooks (env): RD_CONF, RD_RRFS_ROOT,
# RD_RRFS_IMG, RD_RRFS_STAGE, RD_RRFS_UNIT_DIR, RD_RRFS_RESERVE_GB, RD_RRFS_LOCK, RD_RRFS_CLONE (the reflink copy
# argv), RD_RRFS_RSYNC (the rsync argv), RD_RRFS_OTHER_IMGS, RD_DF_CMD, RD_NO_SERVICES=1, RD_RRFS_SELF (this
# script's path for the unit). `rd-rrfs --source` only defines the functions.
set -u
CONF="${RD_CONF:-/etc/rdocker/tune.conf}"
RD_USER=${RD_RRFS_USER:-rd}   # provision passes it (tune.conf comes later there)
[ -z "${RD_RRFS_USER:-}" ] && [ -r "$CONF" ] && { _u=$(sed -n 's/^RD_USER=//p' "$CONF" | head -1); [ -n "$_u" ] && RD_USER=$_u; }
RR="${RD_RRFS_ROOT:-$(getent passwd "$RD_USER" 2>/dev/null | cut -d: -f6)/rr}"
IMG="${RD_RRFS_IMG:-/var/lib/rdocker-rr.xfs}"
STAGE="${RD_RRFS_STAGE:-/var/lib/rdocker-rr.stage}"
OLD="$RR.pre-xfs"
RESERVE_GB=${RD_RRFS_RESERVE_GB:-15}
UNIT="${RD_RRFS_UNIT_DIR:-/etc/systemd/system}/rd-rrfs.service"
SELF="${RD_RRFS_SELF:-/usr/local/bin/rd-rrfs}"
# shellcheck disable=SC2206  # word-split on purpose: an argv
CLONE=(${RD_RRFS_CLONE:-cp -a --reflink=always})
OTHER_IMGS=${RD_RRFS_OTHER_IMGS:-/var/lib/rdocker-docker.img}   # sparse images on the same disk (provision's docker disk)
# shellcheck disable=SC2206  # word-split on purpose: an argv
RSYNC_BIN=(${RD_RRFS_RSYNC:-rsync})
# rsync -aH; exit 24 ("some files vanished") is a success: a live pass races rd-tune's prune and the runs,
# and the final pass runs under every slot lock. The vanished-file lines are dropped from the output.
rs() {
  local rc
  "${RSYNC_BIN[@]}" -aH --numeric-ids "$@" 2> >(grep -v -e '^file has vanished' -e '^directory has vanished' \
                                                       -e 'some files vanished before' >&2)
  rc=$?
  [ "$rc" = 24 ] && rc=0
  return "$rc"
}

say() { echo "rd-rrfs: $*"; }
LOCKD="${RD_RRFS_LOCK:-/run/rd-rrfs.lock}"
# one copy / switch at a time: two passes into one stage race each other's temp files (a mkdir lock with
# the holder's pid; a dead holder's lock is taken over). Released on exit.
take_lock() {
  if ! mkdir "$LOCKD" 2>/dev/null; then
    local pid; pid=$(cat "$LOCKD/pid" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then die "busy: another rd-rrfs (pid $pid) is running"; fi
    rm -rf "$LOCKD"; mkdir "$LOCKD" || die "cannot take $LOCKD"
  fi
  echo $$ > "$LOCKD/pid"
  trap 'rm -rf "$LOCKD"' EXIT
}
die() { echo "rd-rrfs: $*" >&2; exit 1; }

# ------------------------------------------------------------------------------------------- facts
fs_of() { findmnt -no FSTYPE -T "$1" 2>/dev/null | head -1; }
is_mount() { mountpoint -q "$1" 2>/dev/null; }
rr_is_xfs() { is_mount "$RR" && [ "$(fs_of "$RR")" = xfs ]; }
avail_gb() { ${RD_DF_CMD:-df -Pk} "$1" 2>/dev/null | awk 'NR == 2 { printf "%d\n", $4 / 1048576 }'; }
used_kb() { ${RD_DU_CMD:-du -sxk} "$1" 2>/dev/null | awk '{ print $1; exit }'; }
unalloc_kb() {   # $1 file -> logical size minus the blocks it holds (what a sparse image may still claim), KB
  perl -e 'my @s = stat $ARGV[0] or do { print "0\n"; exit }; my $u = $s[7] - $s[12] * 512; print int(($u > 0 ? $u : 0) / 1024), "\n"' "$1"
}

# A dir this script makes in the stage (deps/, w/, w2/: their own attributes are never in a copy pass) takes
# its owner and mode from ~/rr's: made by root, they would lock the runner out of new mirrors / store entries.
copy_attr() {   # $1 source dir, $2 dest dir
  [ -d "$1" ] && [ -d "$2" ] || return 0
  perl -e 'my @s = stat $ARGV[0] or exit 1; chown $s[4], $s[5], $ARGV[1]; chmod $s[2] & 07777, $ARGV[1] or exit 1' "$1" "$2"
}
as_rd() { if [ "$(id -u)" = 0 ]; then runuser -u "$RD_USER" -- "$@"; else "$@"; fi; }
# true when the rd user can create an entry in ~/rr and in each dir right under it (.trash is rd-tune's, root)
rd_can_write() {
  local d bad=""
  for d in "$1" "$1"/*/; do
    d=${d%/}
    as_rd sh -c 't=$(mktemp -d "$1/.rd-rrfs-probe.XXXXXX") && rmdir "$t"' _ "$d" 2>/dev/null || bad="$bad ${d#"$1"/}"
  done
  [ -z "$bad" ] || { echo "rd-rrfs: $RD_USER cannot write:$bad" >&2; return 1; }
}

reflink_ok() {   # $1 dir -> true when a reflink copy works there
  local p
  p=$(mktemp "$1/.rd-rrfs-probe.XXXXXX" 2>/dev/null) || return 1
  echo probe > "$p"
  "${CLONE[@]}" "$p" "$p.c" 2>/dev/null && [ "$(cat "$p.c" 2>/dev/null)" = probe ]
  local rc=$?
  rm -f "$p" "$p.c"
  return $rc
}

# max_gb: the largest image that can never overfill the disk under it. Once ~/rr lives in the image and the
# old copy is gone, the disk holds (used - rr) + image + what the other sparse images may still claim, so
#   N <= avail + rr_used - other_unalloc - RESERVE_GB     (rr_used counts only when ~/rr is on that disk)
max_gb() {
  local dir rr_kb=0 other_kb=0 f
  dir=$(dirname "$IMG")
  if [ -d "$RR" ] && ! rr_is_xfs && [ "$(df -P "$RR" 2>/dev/null | awk 'NR==2{print $1}')" = "$(df -P "$dir" 2>/dev/null | awk 'NR==2{print $1}')" ]; then
    rr_kb=$(used_kb "$RR"); rr_kb=${rr_kb:-0}
  fi
  for f in $OTHER_IMGS; do [ -f "$f" ] && other_kb=$(( other_kb + $(unalloc_kb "$f") )); done
  echo $(( $(avail_gb "$dir") + rr_kb / 1048576 - other_kb / 1048576 - RESERVE_GB ))
}

status() {
  local gb=0
  [ -f "$IMG" ] && gb=$(( $(perl -e 'print +(stat shift)[7]' "$IMG") / 1073741824 ))
  printf 'rd-rrfs: rr=%s fs=%s reflink=%s img=%s img_gb=%s staged=%s old=%s\n' "$RR" "$(fs_of "$RR")" \
    "$( [ -d "$RR" ] && reflink_ok "$RR" && echo 1 || echo 0)" "$IMG" "$gb" \
    "$(is_mount "$STAGE" && echo 1 || echo 0)" "$( [ -e "$OLD" ] && echo 1 || echo 0)"
}

# ------------------------------------------------------------------------------------------- create
unit_text() {
  cat <<UNIT
[Unit]
Description=rdocker: ~$RD_USER/rr on its reflink XFS image ($IMG)
DefaultDependencies=no
After=local-fs.target
Before=ssh.service sshd.service docker.service rd-tune.service rd-doctor.service systemd-user-sessions.service
ConditionPathExists=$IMG

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SELF mount

[Install]
WantedBy=multi-user.target
UNIT
}

create() {
  local gb=$1 max
  [[ "$gb" =~ ^[0-9]+$ ]] && [ "$gb" -ge 8 ] || die "--gb N (>= 8) is required"
  command -v mkfs.xfs >/dev/null 2>&1 || {
    say "installing xfsprogs"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q xfsprogs >/dev/null || die "apt-get install xfsprogs failed"
  }
  if [ ! -f "$IMG" ]; then
    max=$(max_gb)
    [ "$gb" -le "$max" ] || die "--gb $gb could overfill $(dirname "$IMG"): at most $max GB (keeps ${RESERVE_GB} GB free once the old ~/rr is dropped)"
    truncate -s "${gb}G" "$IMG" || die "cannot create $IMG"
    chmod 600 "$IMG"
    say "created $IMG (${gb} GB, sparse; max was $max GB)"
  fi
  if ! blkid -p -s TYPE -o value "$IMG" 2>/dev/null | grep -qx xfs; then
    # 4096-byte sectors: the loop device runs with direct I/O (no second page cache of the image file)
    mkfs.xfs -q -m reflink=1 -s size=4096 -L rdrr "$IMG" || die "mkfs.xfs failed"
    say "formatted $IMG (xfs, reflink=1)"
  fi
  local tmp; tmp=$(mktemp)
  unit_text > "$tmp"
  if ! cmp -s "$tmp" "$UNIT"; then
    mkdir -p "$(dirname "$UNIT")"; install -m 644 "$tmp" "$UNIT"
    [ -n "${RD_NO_SERVICES:-}" ] || systemctl daemon-reload
    say "wrote $UNIT"
  fi
  rm -f "$tmp"
  [ -n "${RD_NO_SERVICES:-}" ] || systemctl enable rd-rrfs.service >/dev/null 2>&1
}

# ------------------------------------------------------------------------------------------- mount
attach() {   # -> the loop device holding IMG (attached once, direct I/O)
  local dev
  dev=$(losetup -j "$IMG" -nO NAME 2>/dev/null | head -1)
  [ -n "$dev" ] || dev=$(losetup --find --show --direct-io=on --sector-size 4096 "$IMG") || return 1
  echo "$dev"
}

mount_at() {   # $1 dir
  local dev
  is_mount "$1" && [ "$(fs_of "$1")" = xfs ] && return 0
  dev=$(attach) || die "cannot attach $IMG"
  mkdir -p "$1"
  mount -o noatime "$dev" "$1" || die "cannot mount $dev at $1"
  # a fresh volume's root (root-owned after mkfs) goes to the rd user; a copy pass then takes ~/rr's own mode
  [ "$(perl -e 'print scalar getpwuid((stat shift)[4])' "$1")" = "$RD_USER" ] || { chown "$RD_USER": "$1"; chmod 755 "$1"; }
}

do_mount() {
  rr_is_xfs && { say "$RR already mounted"; return 0; }
  # at boot the mountpoint is the empty immutable dir cutover left; anything else means no cutover yet
  # (a fresh box's ~/rr is empty too: it gets the same immutable mountpoint)
  if [ -n "$(ls -A "$RR" 2>/dev/null)" ]; then die "$RR is not empty: run rd-rrfs presync + cutover first"; fi
  is_mount "$STAGE" && umount "$STAGE"
  if [ ! -d "$RR" ] || [ "$(perl -e 'print scalar getpwuid((stat shift)[4])' "$RR")" != root ]; then
    mkdir -p "$RR" && chown root: "$RR" && chmod 755 "$RR"
    chattr +i "$RR" 2>/dev/null || true
  fi
  mount_at "$RR"
  say "mounted $IMG at $RR"
}

# ------------------------------------------------------------------------------------------- copy
# The top-level "name" of an npm install (node_modules/.package-lock.json), "" when none.
nm_name() { sed -n 's/^  "name": "\(.*\)",$/\1/p' "$1/.package-lock.json" 2>/dev/null | head -1; }
room_ok() {
  local a; a=$(avail_gb "$(dirname "$IMG")")
  [ -n "$a" ] && [ "$a" -ge "$RESERVE_GB" ] || { echo "rd-rrfs: stopping: $(dirname "$IMG") has ${a:-?} GB free (< ${RESERVE_GB} GB)" >&2; return 1; }
}

# store entries: new ones only (they never change); base = the newest copied entry of the same package name.
# The bases are "<name>\t<path>" lines in a file (no associative arrays: the tests run under macOS bash 3.2).
sync_store() {
  local src="$RR/deps" dst="$STAGE/deps" e name base n=0 copied=0 b seen
  mkdir -p "$dst"; copy_attr "$src" "$dst"
  for e in "$dst"/*; do [ -d "$e" ] && [ ! -e "$src/$(basename "$e")" ] && rm -rf "$e"; done
  rm -rf "$dst"/.part-*
  [ -d "$src" ] || return 0
  seen=$(mktemp) || return 1
  for e in "$dst"/*; do   # bases from an earlier pass
    [ -d "$e/node_modules" ] || continue
    name=$(nm_name "$e/node_modules"); [ -n "$name" ] && printf '%s\t%s\n' "$name" "$e" >> "$seen"
  done
  # newest first (store_clone touches an entry on use): the most used land first if the disk runs short
  while IFS= read -r e; do
    b=$(basename "$e")
    case "$b" in .*) continue ;; esac
    n=$((n + 1))
    [ -d "$dst/$b" ] && continue
    room_ok || { rm -f "$seen"; return 1; }
    name=$(nm_name "$e/node_modules"); base=""
    [ -n "$name" ] && base=$(awk -F '\t' -v n="$name" '$1 == n { p = $2 } END { print p }' "$seen")
    mkdir -p "$dst/.part-$b"
    if [ -n "$base" ] && [ -d "$base/node_modules" ]; then "${CLONE[@]}" "$base/node_modules" "$dst/.part-$b/node_modules" 2>/dev/null; fi
    rs --checksum --delete "$e/" "$dst/.part-$b/" || { rm -rf "$dst/.part-$b" "$seen"; return 1; }
    touch -r "$e" "$dst/.part-$b"
    mv "$dst/.part-$b" "$dst/$b"
    [ -n "$name" ] && printf '%s\t%s\n' "$name" "$dst/$b" >> "$seen"
    copied=$((copied + 1))
  done < <(ls -dt "$src"/*/ 2>/dev/null | sed 's#/$##')
  rm -f "$seen"
  say "store: $copied new of $n entries"
}

# rr_runner.pl deps_key: the store entry a mirror's deps dir would clone from
deps_key() {   # $1 repo slug, $2 rel ('' = the repo root), $3 stamp
  perl -MDigest::SHA=sha256_hex -e 'print substr(sha256_hex("$ARGV[0]\0$ARGV[1]\0$ARGV[2]"), 0, 32), "\n"' -- "$1" "$2" "$3"
}
# The npm node_modules dirs of a mirror: <dir>/node_modules holding .rr-deps-stamp (the repo root or a package
# dir, never inside a node_modules), one path per line.
mirror_nms() { find "$1" -maxdepth 4 -name node_modules -prune -type d -exec sh -c 'test -f "$1/.rr-deps-stamp"' _ {} \; -print 2>/dev/null; }
# $1 mirror, $2 its node_modules -> the store entry's node_modules with the same stamp under $3 (a deps dir),
# or nothing. Same stamp = same lockfile, package.json, .npmrc, node and npm args = the same install.
store_nm_for() {
  local b slug rel st key
  b=$(basename "$1"); slug=${b%-*}
  rel=${2#"$1"}; rel=${rel#/}; rel=${rel%node_modules}; rel=${rel%/}
  st=$(cat "$2/.rr-deps-stamp" 2>/dev/null) || return 0
  key=$(deps_key "$slug" "$rel" "$st")
  [ -d "$3/$key/node_modules" ] && [ "$(cat "$3/$key/node_modules/.rr-deps-stamp" 2>/dev/null)" = "$st" ] \
    && echo "$3/$key/node_modules"
}
# Mirrors, exact (sources, git state, every node_modules). A node_modules whose stamp has a store entry is
# first reflinked from the stage's copy of that entry: the same install, so the size+mtime pass after it only
# rewrites what the runs wrote since (prisma client, caches) and the copy costs next to no space. Without a
# store entry, a node_modules whose stamp changed since the last pass is dropped and copied whole again (npm's
# fixed 1985 mtime: a quick pass could keep a file of the old install).
sync_mirrors() {
  local kind m b nm rel dnm base n=0 based=0
  for kind in w w2; do
    [ -d "$RR/$kind" ] || continue
    mkdir -p "$STAGE/$kind"; copy_attr "$RR/$kind" "$STAGE/$kind"
    for m in "$STAGE/$kind"/*; do [ -e "$m" ] && [ ! -e "$RR/$kind/$(basename "$m")" ] && rm -rf "$m"; done
    for m in "$RR/$kind"/*; do
      [ -d "$m" ] && [ ! -L "$m" ] || continue
      b=$(basename "$m"); n=$((n + 1))
      room_ok || return 1
      while IFS= read -r nm; do
        [ -n "$nm" ] || continue
        rel=${nm#"$m"/}; dnm="$STAGE/$kind/$b/$rel"
        [ -d "$dnm" ] && cmp -s "$nm/.rr-deps-stamp" "$dnm/.rr-deps-stamp" && continue
        rm -rf "${dnm:?}"
        base=$(store_nm_for "$m" "$nm" "$STAGE/deps")
        [ -n "$base" ] || continue
        mkdir -p "$(dirname "$dnm")"
        "${CLONE[@]}" "$base" "$dnm" 2>/dev/null && based=$((based + 1))
      done < <(mirror_nms "$m")
      rs --delete "$m/" "$STAGE/$kind/$b/" || return 1
    done
  done
  say "mirrors: $n copied, $based node_modules reflinked from the store first"
}

# After a cutover made by an older rd-rrfs (which left store-covered node_modules out of the mirrors): put
# each one back from the store + the old copy, exactly as the mirror had it. Only a node_modules the mirror
# still lacks, and only while holding the mirror's lock (rr_runner.pl lock_mirror: w*/.<mirror>.lock), so a
# run never sees one half-made; a busy mirror is skipped (run it again). Never touches anything else.
# shellcheck disable=SC2016  # Perl, expanded by perl
MLOCK_PL='
use strict; use warnings; use Fcntl qw(:flock O_RDWR O_NOFOLLOW);
my ($lock, @cmd) = @ARGV;
sysopen(my $fh, $lock, O_RDWR | O_NOFOLLOW) or exit 75;
flock($fh, LOCK_EX | LOCK_NB) or exit 75;
exit(system(@cmd) == 0 ? 0 : 1);
'
restore_one() {   # $1 old node_modules, $2 new node_modules, $3 store node_modules (runs under the mirror lock)
  [ -e "$2" ] && return 0
  local t; t="$(dirname "$2")/.rd-rrfs-nm.$$"
  rm -rf "$t"
  "${CLONE[@]}" "$3" "$t" && rs --delete "$1/" "$t/" && mv "$t" "$2" || { rm -rf "$t"; return 1; }
}
restore_nm() {
  rr_is_xfs || die "$RR is not the XFS volume"
  [ -d "$OLD" ] || die "no $OLD to restore from"
  local kind m b nm rel new base lock rc put=0 busy=0 gone=0
  for kind in w w2; do
    for m in "$OLD/$kind"/*; do
      [ -d "$m" ] && [ ! -L "$m" ] || continue
      b=$(basename "$m")
      [ -d "$RR/$kind/$b" ] || { gone=$((gone + 1)); continue; }   # pruned since: nothing to put back
      while IFS= read -r nm; do
        [ -n "$nm" ] || continue
        rel=${nm#"$m"/}; new="$RR/$kind/$b/$rel"
        [ -e "$new" ] && continue
        [ -d "$(dirname "$new")" ] || continue
        base=$(store_nm_for "$m" "$nm" "$RR/deps")
        [ -n "$base" ] || continue
        lock="$RR/$kind/.$b.lock"
        # the runner opens this lock O_RDWR as rd: it must never be made by root
        [ -e "$lock" ] || as_rd sh -c 'umask 077; : >> "$1"' _ "$lock"
        perl -e "$MLOCK_PL" "$lock" /bin/bash "$0" _restore_one "$nm" "$new" "$base"; rc=$?
        case $rc in 0) [ -e "$new" ] && put=$((put + 1)) ;; 75) busy=$((busy + 1)) ;; *) echo "rd-rrfs: could not restore $new" >&2 ;; esac
      done < <(mirror_nms "$m")
    done
  done
  say "restore-nm: $put node_modules put back, $busy skipped (mirror in use), $gone mirrors gone"
}

sync_rest() {   # everything else under ~/rr (small: git, logs, state, slots, tools, pnpm-store, ...); never
                # .trash (what rd-tune's prune is still deleting)
  rs --delete --exclude=/deps --exclude=/w --exclude=/w2 --exclude=/.trash "$RR/" "$STAGE/"
}

presync() {
  [ -f "$IMG" ] || die "no image: run rd-rrfs create --gb N first"
  rr_is_xfs && die "$RR is already the XFS volume"
  [ -d "$RR" ] || die "no $RR"
  mount_at "$STAGE"
  reflink_ok "$STAGE" || die "no reflink on $STAGE"
  local t0; t0=$(date +%s)
  sync_rest || die "copy failed (the rest of ~/rr)"
  sync_store || die "copy failed (store)"
  sync_mirrors || die "copy failed (mirrors)"
  say "presync done in $(( $(date +%s) - t0 )) s; image $(df -Pk "$STAGE" | awk 'NR==2 { printf "%d GB used", $3 / 1048576 }')"
}

# ------------------------------------------------------------------------------------------- cutover
# Holds every slot lock (numeric and heavy-*, the runner's flock(2)) while it runs the switch, so no run can
# start; refuses (exit 75) when one is held. The runner takes its slot before it touches its mirror or makes
# its tmp dir (rr_runner.pl main / take_slot), so no lock held = nothing in use. Runners still waiting for a
# slot (a busy box always has some: each polls up to rr_slot_wait_s) are no obstacle: they resolve every
# path afresh and take a slot in the new ~/rr once it is mounted; one that polls in the moment between the
# move and the mount fails before its start (the client places it again).
# shellcheck disable=SC2016  # Perl, expanded by perl
LOCK_PL='
use strict; use warnings; use Fcntl qw(:flock O_RDWR O_CREAT O_NOFOLLOW);
my ($dir, $user, @cmd) = @ARGV;
my @held;
opendir(my $d, $dir) or die "rd-rrfs: no $dir\n";
for my $n (sort readdir $d) {
    next unless $n =~ /^(\d+|heavy-\d+)$/;
    sysopen(my $fh, "$dir/$n", O_RDWR | O_NOFOLLOW) or next;
    flock($fh, LOCK_EX | LOCK_NB) or do { print STDERR "rd-rrfs: busy: slot $n is held\n"; exit 75 };
    push @held, $fh;
}
my @p = `pgrep -u $user -f "^rrun-runner" 2>/dev/null` =~ /(\d+)/g;
print "rd-rrfs: all slots free; ", scalar(@p), " runner(s) waiting for a slot\n";
exit(system(@cmd) == 0 ? 0 : 1);
'

SERVICES_STOPPED=()
stop_writers() {
  [ -n "${RD_NO_SERVICES:-}" ] && return 0
  local u
  for u in rd-tune.timer rd-doctor.timer rd-reclaim.timer; do
    systemctl is-active --quiet "$u" && { systemctl stop "$u"; SERVICES_STOPPED+=("$u"); }
  done
  # the reporter tails runs.log by inode: a new file would look rotated and resend it all; restart it after
  systemctl --user -M "$RD_USER@" is-active --quiet rd-reporter 2>/dev/null \
    && { systemctl --user -M "$RD_USER@" stop rd-reporter; SERVICES_STOPPED+=(reporter); }
}
start_writers() {
  local u
  for u in ${SERVICES_STOPPED[@]+"${SERVICES_STOPPED[@]}"}; do
    if [ "$u" = reporter ]; then systemctl --user -M "$RD_USER@" start rd-reporter; else systemctl start "$u"; fi
  done
}

switch() {   # runs under LOCK_PL
  local t0; t0=$(date +%s)
  stop_writers
  sync_rest && sync_store && sync_mirrors || { start_writers; die "final pass failed; ~/rr untouched"; }
  umount "$STAGE" || { start_writers; die "cannot unmount $STAGE"; }
  mv "$RR" "$OLD" || { start_writers; die "cannot move $RR aside"; }
  mkdir "$RR" && chown root: "$RR" && chmod 755 "$RR"
  chattr +i "$RR" 2>/dev/null || say "note: chattr +i $RR failed (the mountpoint stays writable when unmounted)"
  if [ -n "${RD_NO_SERVICES:-}" ]; then mount_at "$RR"; else systemctl start rd-rrfs.service; fi
  if ! rr_is_xfs || ! reflink_ok "$RR" || [ ! -d "$RR/slots" ] || ! rd_can_write "$RR"; then
    echo "rd-rrfs: verify failed after the switch: rolling back" >&2
    undo; start_writers; exit 1
  fi
  start_writers
  say "cutover done in $(( $(date +%s) - t0 )) s: $RR is xfs (reflink); old copy at $OLD (rd-rrfs drop-old frees it)"
}

cutover() {
  rr_is_xfs && { say "$RR is already the XFS volume"; return 0; }
  is_mount "$STAGE" || die "nothing staged: run rd-rrfs presync first"
  [ -e "$OLD" ] && die "$OLD exists (an earlier cutover?): resolve it first"
  [ -d "$RR/slots" ] || mkdir -p "$RR/slots"
  perl -e "$LOCK_PL" "$RR/slots" "$RD_USER" /bin/bash "$0" _switch
}

undo() {
  is_mount "$RR" && umount "$RR"
  chattr -i "$RR" 2>/dev/null
  rmdir "$RR" 2>/dev/null || { echo "rd-rrfs: $RR is not an empty dir; leaving it" >&2; return 1; }
  mv "$OLD" "$RR"
}

rollback() {
  [ -d "$OLD" ] || die "no $OLD to go back to"
  stop_writers
  [ -n "${RD_NO_SERVICES:-}" ] || systemctl disable --now rd-rrfs.service >/dev/null 2>&1
  undo || { start_writers; die "rollback failed"; }
  start_writers
  say "rolled back: $RR is the old copy again; the image $IMG is kept (rm it by hand)"
}

drop_old() {
  rr_is_xfs || die "$RR is not the XFS volume: nothing dropped"
  [ -d "$OLD" ] || { say "no $OLD"; return 0; }
  rm -rf "$OLD" && say "removed $OLD"
}

case "${1:-}" in
  --source) ;;
  status) status ;;
  create) [ "${2:-}" = --gb ] || die "usage: rd-rrfs create --gb N"; create "${3:-}" ;;
  presync) take_lock; presync ;;
  cutover) take_lock; cutover ;;
  _switch) switch ;;
  restore-nm) take_lock; restore_nm ;;
  _restore_one) restore_one "$2" "$3" "$4" ;;
  mount) do_mount ;;
  rollback) rollback ;;
  drop-old) drop_old ;;
  max-gb) max_gb ;;
  *) die "usage: rd-rrfs status|create --gb N|presync|cutover|mount|rollback|drop-old|restore-nm|max-gb" ;;
esac
