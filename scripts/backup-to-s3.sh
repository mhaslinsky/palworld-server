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
MIN_BYTES=${BACKUP_MIN_BYTES:-10000000}   # 10 MB floor; a real world is ~75 MB
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
BEFORE=$(stat -c %Y "$LEVEL")
curl -fsS --max-time 30 -u "admin:$ADMIN_PASSWORD" -X POST -H 'Content-Length: 0' \
  "http://127.0.0.1:${REST_PORT}/v1/api/save" >/dev/null 2>&1 \
  || logger -t palworld-backup "force-save request failed; backing up on-disk state anyway"
sleep 5
AFTER=$(stat -c %Y "$LEVEL")
if [ "$AFTER" -le "$BEFORE" ]; then
  # Not fatal: the on-disk world is still worth capturing, and the server may be
  # mid-shutdown. But say so - a stale capture must not look like a fresh one.
  logger -t palworld-backup "WARNING: Level.sav mtime did not advance; archiving possibly stale state"
fi

# --- archive + integrity gates -----------------------------------------------
tar czf "$ARCHIVE" -C "$SAVEDIR" . || fail "tar failed"
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
logger -t palworld-backup "ok ${KEY} ${SIZE}B"
echo "BACKUP_VERIFIED ${KEY} ${SIZE}"
