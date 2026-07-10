#!/usr/bin/env bash
# palworld idle-shutdown watcher + Discord notifier + roster publisher.
#
# Runs locally on the server on a systemd timer. Polls the Palworld REST API on
# localhost for the connected players and:
#   - publishes the roster to an SSM Parameter (so /palworld-status can read it
#     without the REST port ever leaving localhost),
#   - announces "server up" once per boot,
#   - warns the channel WARN_BEFORE_MIN before the idle shutdown fires,
#   - shuts the box down after THRESHOLD_MIN minutes of zero players (OS shutdown
#     -> AWS stops the instance; the world save survives on the root EBS).
#
# Design notes (from the crucible critique panel):
#  - localhost-only: the REST API and its admin password never cross the network,
#    so the security group opens neither 8212 (REST) nor 25575 (RCON). The roster
#    reaches the Lambda via SSM, pushed from here — never pulled from outside.
#  - The Discord webhook is read from SSM at runtime, NOT baked into user_data:
#    user_data_replace_on_change=true means baking it in would make rotating the
#    webhook rebuild the instance.
#  - Idle/announce state lives in /run (tmpfs), cleared on every boot. A fresh boot
#    therefore always starts the idle clock from scratch and re-announces "up".
#  - Fail-safe: any error reaching or parsing the API is treated as "players
#    present" (timer reset), so the server is never stopped on a transient blip.

set -euo pipefail

CONF=/etc/palworld/idle.conf
[ -r "$CONF" ] || { logger -t palworld "idle: no config at $CONF"; exit 0; }
# shellcheck disable=SC1090
. "$CONF"

: "${REST_PORT:=8212}"
: "${THRESHOLD_MIN:=25}"
: "${WARN_BEFORE_MIN:=5}"
: "${SERVER_LABEL:=Palworld}"
: "${SERVER_ADDRESS:=}"
: "${AWS_REGION:=us-east-1}"
: "${WEBHOOK_PARAM:=}"
: "${ROSTER_PARAM:=}"
: "${ADMIN_PASSWORD:?idle.conf must set ADMIN_PASSWORD}"

STATE_DIR=/run/palworld
IDLE_SINCE="$STATE_DIR/idle_since"
WARNED="$STATE_DIR/warned"
ANNOUNCED_UP="$STATE_DIR/announced_up"
mkdir -p "$STATE_DIR"

now="$(date +%s)"

# --- Discord ------------------------------------------------------------------
# Webhook is optional: with no parameter set, every notify() is a silent no-op and
# the shutdown logic still works. Cached for this invocation only.
webhook_url() {
  [ -n "$WEBHOOK_PARAM" ] || return 0
  aws ssm get-parameter --name "$WEBHOOK_PARAM" --with-decryption \
    --region "$AWS_REGION" --query 'Parameter.Value' --output text 2>/dev/null || true
}

notify() {
  local content="$1" url
  url="$(webhook_url)"
  # An unset SSM parameter comes back as the literal string "None" via --output text.
  [ -n "$url" ] && [ "$url" != "None" ] || return 0
  # jq -Rs builds a correctly escaped JSON string; hand-rolled quoting breaks on
  # player names containing quotes or backslashes.
  printf '%s' "$content" | jq -Rs '{content: .}' \
    | curl -fsS --max-time 5 -H 'Content-Type: application/json' -d @- "$url" >/dev/null 2>&1 || true
}

# --- Poll ---------------------------------------------------------------------
# --fail => non-2xx is an error; empty/err => assume active (fail safe).
resp="$(curl -fsS --max-time 5 -u "admin:$ADMIN_PASSWORD" \
  "http://127.0.0.1:$REST_PORT/v1/api/players" 2>/dev/null || true)"

if [ -z "$resp" ]; then
  rm -f "$IDLE_SINCE" # server not up yet / API unreachable -> active
  exit 0
fi

count="$(printf '%s' "$resp" | jq '.players | length' 2>/dev/null || echo -1)"
if [ "$count" -lt 0 ]; then
  rm -f "$IDLE_SINCE" # couldn't parse -> fail safe, assume active
  exit 0
fi

names="$(printf '%s' "$resp" | jq -r '[.players[].name] | join(", ")' 2>/dev/null || echo "")"

# --- Publish the roster for /palworld-status ----------------------------------
# Best-effort: a failure here must never keep the box alive or kill the watcher.
if [ -n "$ROSTER_PARAM" ]; then
  roster="$(jq -nc --argjson count "$count" --arg names "$names" --argjson ts "$now" \
    '{count: $count, names: $names, updated: $ts}')"
  aws ssm put-parameter --name "$ROSTER_PARAM" --type String --overwrite \
    --value "$roster" --region "$AWS_REGION" >/dev/null 2>&1 || true
fi

# --- Announce "up" once per boot ----------------------------------------------
# Reaching here means the REST API answered, so the server is genuinely accepting
# players — a better signal than systemd's "active".
if [ ! -f "$ANNOUNCED_UP" ]; then
  : >"$ANNOUNCED_UP"
  notify "🟢 **$SERVER_LABEL** is up — join at \`$SERVER_ADDRESS\`"
fi

# --- Players online: reset the idle clock -------------------------------------
if [ "$count" -gt 0 ]; then
  rm -f "$IDLE_SINCE" "$WARNED"
  exit 0
fi

# --- Zero players -------------------------------------------------------------
if [ ! -f "$IDLE_SINCE" ]; then
  printf '%s' "$now" >"$IDLE_SINCE" # first zero observation this session -> start the clock
  exit 0
fi

since="$(cat "$IDLE_SINCE" 2>/dev/null || echo "$now")"
elapsed_min=$(( (now - since) / 60 ))
warn_at_min=$(( THRESHOLD_MIN - WARN_BEFORE_MIN ))

if [ "$elapsed_min" -ge "$THRESHOLD_MIN" ]; then
  notify "🛑 **$SERVER_LABEL** has been empty for ${THRESHOLD_MIN} min — shutting down to save money. Start it again with \`/palworld-start\`."
  logger -t palworld "idle ${elapsed_min}m >= ${THRESHOLD_MIN}m — shutting down"
  /sbin/shutdown -h now "palworld idle shutdown"
  exit 0
fi

# Warn once, WARN_BEFORE_MIN minutes ahead of the shutdown.
if [ "$elapsed_min" -ge "$warn_at_min" ] && [ ! -f "$WARNED" ]; then
  : >"$WARNED"
  remaining=$(( THRESHOLD_MIN - elapsed_min ))
  notify "⏰ **$SERVER_LABEL** is empty — shutting down in about ${remaining} min. Join now to keep it alive."
fi
