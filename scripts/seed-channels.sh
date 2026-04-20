#!/usr/bin/env bash
# Seeds a Mattermost team with the channels used by this community.
# Idempotent: existing channels get their header/purpose refreshed; new ones
# are created. Called by setup-local.sh / setup-prod.sh after team creation.
#
# Inputs (required, via env):
#   MM_URL       e.g. http://localhost:8065 or https://chat.example.com
#   ADMIN_TOKEN  session token from POST /api/v4/users/login response header
#   TEAM_ID      id of the team to seed channels in
#
# Edit CHANNELS below to match your community. Each line is pipe-delimited:
#   name | display_name | header | purpose
#   - name:         URL slug, lowercase, hyphens OK
#   - display_name: shown in the sidebar
#   - header:       visible banner at top of the channel — standing info
#   - purpose:      longer description, shown in channel details
# Don't use '|' inside any field.

set -euo pipefail

: "${MM_URL:?MM_URL must be set}"
: "${ADMIN_TOKEN:?ADMIN_TOKEN must be set}"
: "${TEAM_ID:?TEAM_ID must be set}"

log()  { printf "==> %s\n" "$*"; }
ok()   { printf " ok  %s\n" "$*"; }
die()  { printf "  x  %s\n" "$*" >&2; exit 1; }

CHANNELS=(
  "saturday-7am|Saturday 7am|Weekly Saturday morning tennis, 7am at Main Courts. Weather call posted by 6:15am.|Standing Saturday morning game"
  "sunday-7am|Sunday 7am|Weekly Sunday morning tennis, 7am at Main Courts. Weather call posted by 6:15am.|Standing Sunday morning game"
  "pickup-games|Pickup Games|Ad-hoc midweek games. Start a thread per event — 🎾 reaction to RSVP.|Midweek pickup and ad-hoc events"
)

auth=(-H "Authorization: Bearer $ADMIN_TOKEN")

seed_channel() {
  local name="$1" display="$2" header="$3" purpose="$4"

  local lookup_status
  lookup_status=$(curl -sS "${auth[@]}" -o /tmp/mm-channel.json -w "%{http_code}" \
    "$MM_URL/api/v4/teams/$TEAM_ID/channels/name/$name")

  case "$lookup_status" in
    200)
      local channel_id patch
      channel_id=$(jq -r '.id' </tmp/mm-channel.json)
      patch=$(jq -n --arg h "$header" --arg p "$purpose" '{header:$h, purpose:$p}')
      curl -sS "${auth[@]}" -X PUT \
        -H "Content-Type: application/json" \
        -d "$patch" \
        "$MM_URL/api/v4/channels/$channel_id/patch" >/dev/null
      ok "#$name already exists — header/purpose refreshed"
      ;;
    404)
      local body create_status
      body=$(jq -n \
        --arg t "$TEAM_ID" \
        --arg n "$name" \
        --arg d "$display" \
        --arg h "$header" \
        --arg p "$purpose" \
        '{team_id:$t, name:$n, display_name:$d, header:$h, purpose:$p, type:"O"}')
      create_status=$(curl -sS "${auth[@]}" -o /tmp/mm-channel.json -w "%{http_code}" \
        -H "Content-Type: application/json" \
        -d "$body" \
        "$MM_URL/api/v4/channels")
      [[ "$create_status" == "201" ]] || { cat /tmp/mm-channel.json >&2; die "failed to create #$name (HTTP $create_status)"; }
      ok "#$name created"
      ;;
    *)
      cat /tmp/mm-channel.json >&2
      die "unexpected response checking #$name (HTTP $lookup_status)"
      ;;
  esac
}

log "Seeding channels in team $TEAM_ID"
for entry in "${CHANNELS[@]}"; do
  IFS='|' read -r name display header purpose <<< "$entry"
  seed_channel "$name" "$display" "$header" "$purpose"
done
