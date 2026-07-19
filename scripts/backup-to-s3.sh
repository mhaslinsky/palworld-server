#!/usr/bin/env bash
# Rolling off-box world backup. Runs on a systemd timer every 30 min while the
# server is up (the box stops itself when empty, so "no backups while stopped" is
# correct, not a fault - the off-box freshness check keys off instance state).
#
# Why this exists: on 2026-07-18 an instance replacement deleted the root volume
# and the world with it. The only surviving copy was one pulled OFF the box by
# hand that morning; the backup written to /tmp died with the volume. A backup
# that lives inside the failure domain is not a backup.
#
# Every step that could fail silently fails LOUDLY instead:
#  - force-save is verified by Level.sav mtime, not by the HTTP code alone
#  - the archive is integrity-checked (tar -tzf) before it is trusted
#  - a size floor rejects the empty/near-empty world class (the restore that
#    night nearly served an empty world; size is what catches that)
#  - the S3 object is re-read after upload and its size compared to the local
#    archive, because an upload exit code is not proof an object exists
# A run that cannot do its job exits non-zero. Nonzero work + zero output would
# otherwise read as "backed up fine".

set -uo pipefail

CONF=/etc/palworld/idle.conf
[ -r "$CONF" ] || { logger -t palworld-backup "no config at $CONF"; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

: "${REST_PORT:=8212}"
: "${AWS_REGION:=us-east-1}"
: "${BACKUP_BUCKET:?idle.conf must set BACKUP_BUCKET}"
: "${ADMIN_PASSWORD:?idle.conf must set ADMIN_PASSWORD}"

SAVEDIR=/home/steam/palworld/Pal/Saved/SaveGames
MIN_BYTES=${BACKUP_MIN_BYTES:-1000000}   # 1 MB floor. The live world is ~3 MB once
# the game's own rolling backups are excluded (they were ~96% of the old 78 MB
# archives). A freshly generated EMPTY world is ~120 KB, so this cleanly separates
# "real world" from "restored shell" - which is the case the floor exists to catch.
TS=$(date -u +%Y%m%dT%H%M%SZ)
KEY="world/linux/${TS}.tgz"
ARCHIVE="/tmp/palworld-backup-${TS}.tgz"

fail() {
  logger -t palworld-backup "FAILED: $1"
  echo "BACKUP_FAILED: $1" >&2
  rm -f "$ARCHIVE"
  exit 1
}

LEVEL=$(find "$SAVEDIR" -name Level.sav 2>/dev/null | head -1)
[ -n "$LEVEL" ] || fail "no Level.sav under $SAVEDIR"

# --- force-save, and PROVE it happened ---------------------------------------
# The Content-Length header is required: a bare POST returns HTTP 411.
#
# A capture whose save could not be proven is still worth KEEPING (the server may
# be stopped or crashed, and on-disk state beats nothing) - but it must not be
# allowed to look HEALTHY. Publishing it under the normal prefix would make the
# freshness monitor report OK while every "fresh" backup silently held older
# state, which is the same silent-success shape this whole system exists to stop.
# So: keep the data, publish it under a DEGRADED prefix the monitor does not
# watch, and exit non-zero. The monitor then goes STALE and someone finds out.
DEGRADED=""
BEFORE=$(stat -c %Y "$LEVEL" 2>/dev/null) || fail "cannot stat $LEVEL"

# Retry before concluding anything is wrong. The endpoint answers non-2xx while a
# save is already in flight, and this job runs on a timer that will periodically
# collide with the idle watcher's own save - treating that as a failure would cry
# wolf on a healthy server, and an alarm that fires on normal operation is one
# people learn to ignore.
SAVE_OK=0
for save_attempt in 1 2 3; do
  if curl -fsS --max-time 30 -u "admin:$ADMIN_PASSWORD" -X POST -H 'Content-Length: 0' \
       "http://127.0.0.1:${REST_PORT}/v1/api/save" >/dev/null 2>&1; then
    SAVE_OK=1
    break
  fi
  [ "$save_attempt" -lt 3 ] && sleep 10
done

if [ "$SAVE_OK" -eq 1 ]; then
  sleep 5
  AFTER=$(stat -c %Y "$LEVEL" 2>/dev/null) || fail "cannot stat $LEVEL after save"
  if [ "$AFTER" -le "$BEFORE" ]; then
    # A save that another process already completed moments ago is fine - the
    # world on disk is current either way. Only treat it as degraded if the file
    # is genuinely old, which is what "nothing is writing this world" looks like.
    NOW=$(date +%s)
    if [ $(( NOW - AFTER )) -gt 300 ]; then
      DEGRADED="save reported success but Level.sav has not changed in over 5 minutes"
    fi
  fi
else
  DEGRADED="force-save failed on 3 attempts (server down or REST unreachable)"
fi

if [ -n "$DEGRADED" ]; then
  logger -t palworld-backup "DEGRADED: $DEGRADED - publishing under world/linux-degraded/"
  KEY="world/linux-degraded/${TS}.tgz"
fi

# --- archive + integrity gates -----------------------------------------------
# Exclude the game's OWN rolling backups: they are the churniest files in the tree
# (rewritten while we read them) and are redundant here - every S3 object is
# already a point-in-time copy, and the bucket is versioned. Excluding them makes
# the archive smaller and far less likely to be written mid-read.
#
# tar's exit codes matter: 1 means "some files changed while reading" - a WARNING
# on a live server whose world is being written continuously - while 2 means a
# real error. Treating 1 as fatal would fail perfectly good backups at random,
# whenever the archive happened to overlap a game write. The integrity check and
# size floor below are what actually decide whether the result is usable.
set +e
tar czf "$ARCHIVE" -C "$SAVEDIR" --exclude='./*/*/backup' . 2>/dev/null
TAR_RC=$?
set -e
[ "$TAR_RC" -le 1 ] || fail "tar failed with exit $TAR_RC"
SIZE=$(stat -c %s "$ARCHIVE" 2>/dev/null) || fail "archive missing after tar"
tar tzf "$ARCHIVE" >/dev/null 2>&1 || fail "archive fails integrity check (truncated?)"
[ "$SIZE" -ge "$MIN_BYTES" ] || fail "archive only ${SIZE}B, below ${MIN_BYTES}B floor - refusing to publish a suspect backup"

# --- upload, then PROVE the object exists ------------------------------------
aws s3 cp "$ARCHIVE" "s3://${BACKUP_BUCKET}/${KEY}" --region "$AWS_REGION" --only-show-errors \
  || fail "s3 upload failed"

# Verified via ListBucket (which the instance role has) rather than HeadObject
# (which it deliberately does not - the role can write and list its backups but
# not read or delete them).
REMOTE_SIZE=$(aws s3api list-objects-v2 --bucket "$BACKUP_BUCKET" --prefix "$KEY" \
  --region "$AWS_REGION" --query 'Contents[0].Size' --output text 2>/dev/null)
[ "$REMOTE_SIZE" = "$SIZE" ] || fail "size mismatch after upload: local=${SIZE} remote=${REMOTE_SIZE}"

rm -f "$ARCHIVE"

# A degraded capture is stored, not blessed. Exiting non-zero makes the systemd
# unit fail (visible in `systemctl --failed`), and because the object went to the
# degraded prefix the freshness monitor will also go STALE - two independent
# signals rather than a green run hiding an unproven save.
if [ -n "$DEGRADED" ]; then
  logger -t palworld-backup "stored-degraded ${KEY} ${SIZE}B ($DEGRADED)"
  echo "BACKUP_DEGRADED ${KEY} ${SIZE} - ${DEGRADED}" >&2
  exit 1
fi

logger -t palworld-backup "ok ${KEY} ${SIZE}B"
echo "BACKUP_VERIFIED ${KEY} ${SIZE}"
