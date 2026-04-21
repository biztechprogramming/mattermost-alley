#!/usr/bin/env bash
# Local bootstrap: boot Postgres + Mattermost, create the sysadmin account
# and a team via the Mattermost API, so you land on a logged-in-ready stack
# in one command instead of clicking through the first-run wizard.
#
# Safe to re-run. Pass --reset to wipe volumes and start from scratch.
#
# Config via env vars (defaults shown):
#   ADMIN_EMAIL=admin@localhost
#   ADMIN_USERNAME=admin
#   ADMIN_PASSWORD=LocalAdmin!234
#   TEAM_NAME=relay
#   TEAM_DISPLAY="Relay"
#   MM_URL=http://localhost:8065
#   BUILD_FROM_SOURCE=1  — build from local mattermost source tree (auto-detected)
#   BUILD_FROM_SOURCE=0  — force upstream image even when source is present
#   MATTERMOST_SOURCE=../mattermost  — path to local mattermost checkout

set -euo pipefail

ADMIN_EMAIL=${ADMIN_EMAIL:-admin@localhost}
ADMIN_USERNAME=${ADMIN_USERNAME:-admin}
ADMIN_PASSWORD=${ADMIN_PASSWORD:-LocalAdmin!234}
TEAM_NAME=${TEAM_NAME:-relay}
TEAM_DISPLAY=${TEAM_DISPLAY:-Relay}
MM_URL=${MM_URL:-http://localhost:8065}

MATTERMOST_SOURCE=${MATTERMOST_SOURCE:-../mattermost}

# Auto-detect: build from source when the local checkout exists, unless
# explicitly overridden with BUILD_FROM_SOURCE=0.
if [[ -z "${BUILD_FROM_SOURCE:-}" ]]; then
  if [[ -d "$MATTERMOST_SOURCE/server" && -d "$MATTERMOST_SOURCE/webapp" ]]; then
    BUILD_FROM_SOURCE=1
  else
    BUILD_FROM_SOURCE=0
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

log()  { printf "==> %s\n" "$*"; }
ok()   { printf " ok  %s\n" "$*"; }
warn() { printf "  !  %s\n" "$*" >&2; }
die()  { printf "  x  %s\n" "$*" >&2; exit 1; }

COMPOSE_FILES=(-f docker-compose.local.yml)
if [[ "$BUILD_FROM_SOURCE" == "1" ]]; then
  [[ -d "$MATTERMOST_SOURCE/server" && -d "$MATTERMOST_SOURCE/webapp" ]] || \
    die "MATTERMOST_SOURCE=$MATTERMOST_SOURCE not found (need server/ and webapp/ dirs)"
  # Resolve to a path relative to the compose build context (parent of project dir).
  MATTERMOST_SOURCE=$(realpath "$MATTERMOST_SOURCE")
  MATTERMOST_SOURCE=$(realpath --relative-to="$(dirname "$PROJECT_DIR")" "$MATTERMOST_SOURCE")
  export MATTERMOST_SOURCE
  COMPOSE_FILES+=(-f docker-compose.local-source.yml)
fi

RESET=0
for arg in "$@"; do
  case "$arg" in
    --reset) RESET=1 ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $arg (try --help)" ;;
  esac
done

for bin in curl jq docker; do
  command -v "$bin" >/dev/null 2>&1 || die "missing required binary: $bin"
done
docker compose version >/dev/null 2>&1 || die "docker compose v2 not available"
for cf in "${COMPOSE_FILES[@]}"; do
  [[ "$cf" == "-f" ]] && continue
  [[ -f "$cf" ]] || die "$cf not found"
done

compose() { docker compose "${COMPOSE_FILES[@]}" "$@"; }

if [[ "$RESET" -eq 1 ]]; then
  log "Resetting: tearing down containers and wiping *-local-* volumes"
  compose down -v
fi

if [[ "$BUILD_FROM_SOURCE" == "1" ]]; then
  log "Building from local source ($MATTERMOST_SOURCE) + starting postgres + mattermost"
else
  log "Using upstream image + starting postgres + mattermost"
fi
compose up -d --build

log "Waiting for Mattermost API at $MM_URL (up to 2 min)"
for i in $(seq 1 120); do
  if curl -fsS "$MM_URL/api/v4/system/ping" >/dev/null 2>&1; then
    ok "Mattermost is up (after ${i}s)"
    break
  fi
  if [[ "$i" -eq 120 ]]; then
    compose logs --tail=50 mattermost >&2
    die "Mattermost didn't come up in 2 minutes — see logs above"
  fi
  sleep 1
done

# Login-first flow. Once any user exists, Mattermost blocks public POSTs to
# /api/v4/users (EnableOpenServer=false by default), so we can't tell
# "first-run / no admin yet" from "admin exists" via create alone. Easier to
# just try login; fall back to create only on 401.
#
# Session token on successful login is returned in the "Token:" response
# header, not the body.
login_body=$(jq -n --arg u "$ADMIN_USERNAME" --arg p "$ADMIN_PASSWORD" \
  '{login_id:$u, password:$p}')

attempt_login() {
  curl -sS -D /tmp/mm-login.headers -o /tmp/mm-login.json -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -d "$login_body" \
    "$MM_URL/api/v4/users/login"
}

log "Logging in as '$ADMIN_USERNAME'"
login_status=$(attempt_login)

if [[ "$login_status" == "401" ]]; then
  warn "Login failed — assuming first run. Creating admin user '$ADMIN_USERNAME' ($ADMIN_EMAIL)"
  create_body=$(jq -n --arg e "$ADMIN_EMAIL" --arg u "$ADMIN_USERNAME" --arg p "$ADMIN_PASSWORD" \
    '{email:$e, username:$u, password:$p}')
  create_status=$(curl -sS -o /tmp/mm-create.json -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -d "$create_body" \
    "$MM_URL/api/v4/users")
  if [[ "$create_status" != "201" ]]; then
    cat /tmp/mm-create.json >&2
    die "failed to create admin (HTTP $create_status)"
  fi
  ok "Admin user created"
  login_status=$(attempt_login)
fi

if [[ "$login_status" != "200" ]]; then
  cat /tmp/mm-login.json >&2
  die "login failed (HTTP $login_status) — check ADMIN_USERNAME / ADMIN_PASSWORD"
fi

ADMIN_TOKEN=$(awk 'tolower($1)=="token:" {print $2}' /tmp/mm-login.headers | tr -d '\r\n')
[[ -n "$ADMIN_TOKEN" ]] || { cat /tmp/mm-login.json >&2; die "login did not return a Token header"; }
ADMIN_USER_ID=$(jq -r '.id' </tmp/mm-login.json)
ok "Logged in (user_id=$ADMIN_USER_ID)"

auth=(-H "Authorization: Bearer $ADMIN_TOKEN")

# The GET-by-name endpoint returns a JSON error object on 404 with its own
# .id field ("app.team.get_by_name.missing.app_error"), so we must key off
# the HTTP status code, not the shape of the JSON, to decide what to do.
log "Ensuring team '$TEAM_NAME' exists"
team_status=$(curl -sS "${auth[@]}" -o /tmp/mm-team.json -w "%{http_code}" \
  "$MM_URL/api/v4/teams/name/$TEAM_NAME")
case "$team_status" in
  200)
    TEAM_ID=$(jq -r '.id' </tmp/mm-team.json)
    ok "Team already exists (id=$TEAM_ID)"
    ;;
  404)
    team_body=$(jq -n --arg n "$TEAM_NAME" --arg d "$TEAM_DISPLAY" \
      '{name:$n, display_name:$d, type:"O"}')
    create_team_status=$(curl -sS "${auth[@]}" -o /tmp/mm-team.json -w "%{http_code}" \
      -H "Content-Type: application/json" \
      -d "$team_body" "$MM_URL/api/v4/teams")
    [[ "$create_team_status" == "201" ]] || { cat /tmp/mm-team.json >&2; die "failed to create team (HTTP $create_team_status)"; }
    TEAM_ID=$(jq -r '.id' </tmp/mm-team.json)
    ok "Team created (id=$TEAM_ID)"
    ;;
  *)
    cat /tmp/mm-team.json >&2
    die "unexpected response looking up team (HTTP $team_status)"
    ;;
esac

# Idempotent — Mattermost returns 201 the first time, 4xx if already a member.
member_body=$(jq -n --arg t "$TEAM_ID" --arg u "$ADMIN_USER_ID" \
  '{team_id:$t, user_id:$u}')
curl -sS "${auth[@]}" -H "Content-Type: application/json" \
  -d "$member_body" \
  "$MM_URL/api/v4/teams/$TEAM_ID/members" >/dev/null || true

# Seed channels. Idempotent: refreshes header/purpose on existing, creates missing.
MM_URL="$MM_URL" ADMIN_TOKEN="$ADMIN_TOKEN" TEAM_ID="$TEAM_ID" \
  "$SCRIPT_DIR/seed-channels.sh"

cat <<EOF

Local setup complete.

  Mattermost:   $MM_URL
  Admin login:  $ADMIN_USERNAME / $ADMIN_PASSWORD
  Team:         $TEAM_NAME

Open $MM_URL, log in, and you're done.

Tail logs:
  docker compose ${COMPOSE_FILES[*]} logs -f

Reset everything:
  $0 --reset
EOF
