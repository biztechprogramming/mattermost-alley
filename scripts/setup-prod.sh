#!/usr/bin/env bash
# Production bootstrap. The ONLY thing you need to run.
#
# Re-runnable. On first run it walks you through every .env value; on later
# runs it asks whether to revisit every setting or only those still unset.
# Boots the stack, initializes the restic repository, ensures host-side
# backup directories exist, and bootstraps the admin user + team.
#
# Prereqs (NOT done by this script):
#   - Docker + Docker Compose v2 installed.
#   - Upstream nginx on a different server already forwarding
#     https://$DOMAIN → this host:8065 (X-Forwarded-Proto + X-Forwarded-For
#     headers, WebSocket upgrade). See SETUP.md "Upstream nginx".
#
# Flags:
#   --skip-dns-check   Don't verify $DOMAIN resolves
#   --no-bootstrap     Boot the stack but skip admin/team creation
#   --non-interactive  Fail (instead of prompt) on any unset required .env value
#   -h | --help        Print this header

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

ENV_FILE="$PROJECT_DIR/.env"

# ---- helpers --------------------------------------------------------------
log()  { printf "==> %s\n" "$*"; }
ok()   { printf " ok  %s\n" "$*"; }
warn() { printf "  !  %s\n" "$*" >&2; }
die()  { printf "  x  %s\n" "$*" >&2; exit 1; }

SKIP_DNS=0
NO_BOOTSTRAP=0
NONINTERACTIVE=0
for arg in "$@"; do
  case "$arg" in
    --skip-dns-check) SKIP_DNS=1 ;;
    --no-bootstrap)   NO_BOOTSTRAP=1 ;;
    --non-interactive) NONINTERACTIVE=1 ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $arg (try --help)" ;;
  esac
done

# ---- preflight ------------------------------------------------------------
for bin in curl jq docker openssl; do
  command -v "$bin" >/dev/null 2>&1 || die "missing required binary: $bin"
done
docker compose version >/dev/null 2>&1 || die "docker compose v2 not available"
[[ -f ./docker-compose.yml ]] || die "docker-compose.yml not found — run from the project root"

# ---- env-var schema -------------------------------------------------------
# Each entry: KEY | prompt | default-when-empty | sensitive(0/1) | autogen-cmd-or-empty
#   sensitive=1 → input is hidden via `read -s`
#   autogen-cmd → if user presses Enter and current value is empty, run this
ENV_SCHEMA=(
  "DOMAIN|Public hostname users browse to|alley.fastlanedev.com|0|"
  "TZ|Container timezone|UTC|0|"
  "SITE_NAME|Branded site name (shown in tab + login page)|Rally|0|"
  "BIND_ADDR|Interface to bind :8065 on (use a private IP if 8065 is on a public net)|0.0.0.0|0|"
  "POSTGRES_PASSWORD|Postgres password (blank = auto-generate, URL-safe hex)||1|openssl rand -hex 24"
  "ADMIN_EMAIL|Email for the bootstrap admin user||0|"
  "ADMIN_PASSWORD|Bootstrap admin password (blank = auto-generate, persisted to .env)||1|openssl rand -base64 24 | tr -d '+/='"
  "SES_SMTP_HOST|AWS SES SMTP host|email-smtp.us-east-1.amazonaws.com|0|"
  "SES_SMTP_USERNAME|SES SMTP username (AKIA...)||0|"
  "SES_SMTP_PASSWORD|SES SMTP password||1|"
  "SES_FROM_ADDRESS|Envelope-from address (must be a verified SES identity)|noreply@alley.fastlanedev.com|0|"
  "S3_BACKUP_BUCKET|S3 bucket for backups|racecamp-db-backups|0|"
  "S3_BACKUP_REGION|S3 region|us-east-1|0|"
  "S3_BACKUP_KEY_ID|AWS access key ID for backup writes||0|"
  "S3_BACKUP_KEY_SECRET|AWS secret access key for backup writes||1|"
  "RESTIC_PASSWORD|Restic repo password (blank = auto-generate — SAVE IT IMMEDIATELY)||1|openssl rand -base64 48"
)

# Keys whose value being empty must block boot.
REQUIRED_KEYS=(DOMAIN POSTGRES_PASSWORD ADMIN_EMAIL ADMIN_PASSWORD S3_BACKUP_BUCKET S3_BACKUP_KEY_ID S3_BACKUP_KEY_SECRET RESTIC_PASSWORD SITE_NAME TZ BIND_ADDR)

# ---- load current .env if present (line-by-line, no sourcing yet) ---------
declare -A CURRENT=()
if [[ -f "$ENV_FILE" ]]; then
  while IFS= read -r line; do
    # skip blanks + comments
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    # KEY=value (strip optional surrounding quotes)
    if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      k="${BASH_REMATCH[1]}"
      v="${BASH_REMATCH[2]}"
      # trim trailing CR + surrounding single/double quotes
      v="${v%$'\r'}"
      [[ "$v" =~ ^\"(.*)\"$ ]] && v="${BASH_REMATCH[1]}"
      [[ "$v" =~ ^\'(.*)\'$ ]] && v="${BASH_REMATCH[1]}"
      CURRENT["$k"]="$v"
    fi
  done < "$ENV_FILE"
fi

# ---- pick prompt mode -----------------------------------------------------
# count unset (empty current value) entries from the schema
unset_count=0
for entry in "${ENV_SCHEMA[@]}"; do
  IFS='|' read -r key _ _ _ _ <<<"$entry"
  if [[ -z "${CURRENT[$key]:-}" ]]; then
    unset_count=$((unset_count + 1))
  fi
done

MODE=""
if [[ ! -f "$ENV_FILE" ]]; then
  log "No .env found — walking through every setting."
  MODE=all
elif [[ "$NONINTERACTIVE" -eq 1 ]]; then
  if [[ "$unset_count" -gt 0 ]]; then
    die "--non-interactive set but $unset_count required values are empty in .env"
  fi
  MODE=skip
elif [[ "$unset_count" -eq 0 ]]; then
  echo
  echo ".env is fully populated. Review settings anyway?"
  echo "  [a] review all settings"
  echo "  [n] skip — boot the stack with current values"
  read -r -p "Choice [a/N]: " choice
  case "${choice:-n}" in
    a|A) MODE=all ;;
    *)   MODE=skip ;;
  esac
else
  echo
  echo "$unset_count required value(s) in .env are empty."
  echo "  [a] review all settings"
  echo "  [u] prompt only for the $unset_count unset value(s) (default)"
  read -r -p "Choice [a/U]: " choice
  case "${choice:-u}" in
    a|A) MODE=all ;;
    *)   MODE=unset_only ;;
  esac
fi

# ---- interactive prompts --------------------------------------------------
prompt_var() {
  local key="$1" label="$2" default="$3" sensitive="$4" autogen="$5"
  local current="${CURRENT[$key]:-}"
  local show
  if [[ -n "$current" ]]; then
    show="$current"
  elif [[ -n "$default" ]]; then
    show="$default"
  else
    show=""
  fi

  local prompt_str
  if [[ "$sensitive" -eq 1 && -n "$current" ]]; then
    prompt_str="$label [keep existing]: "
  elif [[ -n "$show" ]]; then
    prompt_str="$label [$show]: "
  elif [[ -n "$autogen" ]]; then
    prompt_str="$label [Enter to auto-generate]: "
  else
    prompt_str="$label: "
  fi

  local input
  if [[ "$sensitive" -eq 1 ]]; then
    read -r -s -p "$prompt_str" input || true
    echo
  else
    read -r -p "$prompt_str" input || true
  fi

  if [[ -z "$input" ]]; then
    if [[ -n "$current" ]]; then
      CURRENT["$key"]="$current"
    elif [[ -n "$autogen" ]]; then
      local gen
      gen="$(eval "$autogen")"
      CURRENT["$key"]="$gen"
      if [[ "$key" == "RESTIC_PASSWORD" ]]; then
        echo
        echo "  ┌─────────────────────────────────────────────────────────────"
        echo "  │ RESTIC PASSWORD (generated). SAVE THIS NOW to your password"
        echo "  │ manager. Without it, every restic file backup in S3 becomes"
        echo "  │ unrecoverable scrap — there is no recovery."
        echo "  │"
        echo "  │   $gen"
        echo "  │"
        echo "  └─────────────────────────────────────────────────────────────"
        read -r -p "Type 'saved' once you've stored it: " confirm
        [[ "$confirm" == "saved" ]] || die "aborting — please re-run after saving the restic password"
      else
        echo "  (generated)"
      fi
    elif [[ -n "$default" ]]; then
      CURRENT["$key"]="$default"
    else
      CURRENT["$key"]=""
    fi
  else
    CURRENT["$key"]="$input"
  fi
}

if [[ "$MODE" != "skip" ]]; then
  echo
  log "Enter values (press Enter to keep the shown default)"
  for entry in "${ENV_SCHEMA[@]}"; do
    IFS='|' read -r key label default sensitive autogen <<<"$entry"
    if [[ "$MODE" == "unset_only" && -n "${CURRENT[$key]:-}" ]]; then
      continue
    fi
    prompt_var "$key" "$label" "$default" "$sensitive" "$autogen"
  done
fi

# ---- write .env -----------------------------------------------------------
# We rewrite the whole file from the schema (deterministic ordering + comments).
write_env() {
  local tmp
  tmp="$(mktemp "$ENV_FILE.XXXXXX")"
  {
    echo "# Generated by scripts/setup-prod.sh — safe to edit by hand."
    echo "# Re-run setup-prod.sh to add/update values interactively."
    echo
    for entry in "${ENV_SCHEMA[@]}"; do
      IFS='|' read -r key _ _ _ _ <<<"$entry"
      printf '%s=%s\n' "$key" "${CURRENT[$key]:-}"
    done
    # Preserve any vars in the existing .env that aren't in the schema
    # (e.g. LAN_IP for the dev compose, future extensions).
    for k in "${!CURRENT[@]}"; do
      local in_schema=0
      for entry in "${ENV_SCHEMA[@]}"; do
        IFS='|' read -r skey _ _ _ _ <<<"$entry"
        [[ "$skey" == "$k" ]] && { in_schema=1; break; }
      done
      [[ "$in_schema" -eq 0 ]] && printf '%s=%s\n' "$k" "${CURRENT[$k]}"
    done
  } > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$ENV_FILE"
}

write_env
ok ".env written (mode 0600)"

# ---- now safe to source .env ----------------------------------------------
set -a
# shellcheck disable=SC1091
. "$ENV_FILE"
set +a

# Validate required keys are now non-empty
for k in "${REQUIRED_KEYS[@]}"; do
  [[ -n "${!k:-}" ]] || die "$k is required but is empty in .env"
done

# ---- host-side prep: backup directories -----------------------------------
BACKUP_ROOT=/srv/backups/mattermost-alley
need_sudo_dirs=0
for d in "$BACKUP_ROOT" "$BACKUP_ROOT/daily" "$BACKUP_ROOT/weekly" "$BACKUP_ROOT/logs"; do
  if [[ ! -d "$d" ]]; then
    need_sudo_dirs=1
    break
  fi
done

if [[ "$need_sudo_dirs" -eq 1 ]]; then
  log "Creating backup directories under $BACKUP_ROOT (needs sudo)"
  sudo mkdir -p "$BACKUP_ROOT"/{daily,weekly,logs}
  sudo chown -R 10000:10000 "$BACKUP_ROOT"
  ok "Backup directories created and chowned to 10000:10000"
else
  # Re-chown defensively in case ownership drifted (volume mount issues etc.)
  current_owner=$(stat -c '%u' "$BACKUP_ROOT" 2>/dev/null || echo unknown)
  if [[ "$current_owner" != "10000" ]]; then
    warn "$BACKUP_ROOT is owned by uid=$current_owner, fixing to 10000"
    sudo chown -R 10000:10000 "$BACKUP_ROOT"
  fi
  ok "Backup directories present"
fi

# ---- detect & offer to stop a conflicting stack on :8065 ------------------
# If the dev compose (mattermost-alley-mattermost-1 from docker-compose.local.yml)
# is still bound to 8065, bringing prod up will fail. Offer to take it down.
conflicting_id=$(docker ps --filter "publish=8065" --format '{{.ID}} {{.Names}}' \
  | grep -v 'mattermost-alley_mattermost_1\|mattermost-alley-mattermost-1$' \
  | awk '{print $1}' | head -n1 || true)

# Simpler: if any non-prod-compose container holds 8065, list and ask.
holders=$(docker ps --filter "publish=8065" --format '{{.Names}}' || true)
if [[ -n "$holders" ]]; then
  # Filter out any container that is part of THIS compose project (would be replaced cleanly).
  project_name=$(basename "$PROJECT_DIR")
  external=$(echo "$holders" | grep -v "^${project_name}[-_]" || true)
  if [[ -n "$external" ]]; then
    warn "Port 8065 is currently held by container(s) outside this project:"
    echo "$external" | sed 's/^/      /' >&2
    read -r -p "Stop them now? [y/N]: " yn
    case "${yn:-N}" in
      y|Y)
        echo "$external" | while read -r name; do
          [[ -n "$name" ]] && docker stop "$name" >/dev/null && ok "stopped $name"
        done
        ;;
      *) die "aborting — free port 8065 and re-run" ;;
    esac
  fi
fi

# ---- initialize restic repository (idempotent) ----------------------------
log "Ensuring restic repository exists in S3"
restic_repo="s3:s3.${S3_BACKUP_REGION}.amazonaws.com/${S3_BACKUP_BUCKET}/mattermost-alley/files"
init_out=$(docker run --rm \
  -e RESTIC_PASSWORD \
  -e AWS_ACCESS_KEY_ID="$S3_BACKUP_KEY_ID" \
  -e AWS_SECRET_ACCESS_KEY="$S3_BACKUP_KEY_SECRET" \
  restic/restic:latest -r "$restic_repo" init 2>&1 || true)

if echo "$init_out" | grep -qi "created restic repository"; then
  ok "Restic repo created"
elif echo "$init_out" | grep -qi "config file already exists\|already initialized"; then
  ok "Restic repo already initialized (no-op)"
else
  warn "Restic init returned unexpected output:"
  echo "$init_out" | sed 's/^/      /' >&2
  read -r -p "Continue anyway? [y/N]: " yn
  [[ "${yn:-N}" =~ ^[yY]$ ]] || die "aborting — check S3 creds / bucket / network"
fi

# ---- DNS check ------------------------------------------------------------
if [[ "$SKIP_DNS" -eq 0 ]]; then
  log "Preflight: checking DNS for $DOMAIN"
  resolved=""
  if command -v dig >/dev/null 2>&1; then
    resolved=$(dig +short "$DOMAIN" | grep -E '^[0-9.]+$' | tail -n1 || true)
  elif command -v getent >/dev/null 2>&1; then
    resolved=$(getent hosts "$DOMAIN" | awk '{print $1}' | head -n1 || true)
  fi
  if [[ -z "$resolved" ]]; then
    die "$DOMAIN does not resolve. Point DNS at the upstream nginx server before running. (--skip-dns-check to override)"
  fi
  ok "DNS resolves to $resolved (upstream nginx)"
fi

# ---- boot the stack -------------------------------------------------------
compose() { docker compose "$@"; }

log "Building branded image + starting postgres, mattermost, db-backup, restic-backup"
compose up -d --build

MM_URL="https://$DOMAIN"
log "Waiting for $MM_URL/api/v4/system/ping (up to 2 min — via upstream nginx)"
for i in $(seq 1 120); do
  if curl -fsS --max-time 3 "$MM_URL/api/v4/system/ping" >/dev/null 2>&1; then
    ok "Stack is reachable at $MM_URL (after ${i}s)"
    break
  fi
  if [[ "$i" -eq 120 ]]; then
    warn "Timed out waiting for $MM_URL. Recent mattermost logs:"
    compose logs --tail=50 mattermost >&2
    warn "Check: (1) is :8065 listening on this host? (2) is the upstream nginx forwarding to it?"
    die "giving up — verify upstream nginx config and firewall"
  fi
  sleep 1
done

if [[ "$NO_BOOTSTRAP" -eq 1 ]]; then
  cat <<EOF

Stack is up at $MM_URL — bootstrap skipped (--no-bootstrap).
Visit $MM_URL to create the first account manually.
EOF
  exit 0
fi

# ---- admin user + team bootstrap ------------------------------------------
ADMIN_USERNAME=${ADMIN_USERNAME:-admin}
TEAM_NAME=${TEAM_NAME:-relay}
TEAM_DISPLAY=${TEAM_DISPLAY:-$SITE_NAME}

# ADMIN_PASSWORD comes from .env (validated by REQUIRED_KEYS earlier).
# Source of truth: .env. Mattermost's stored password is brought in line
# with .env below — so if you change ADMIN_PASSWORD in .env and re-run,
# the script will reset mattermost's stored password to match.

login_body=$(jq -n --arg u "$ADMIN_USERNAME" --arg p "$ADMIN_PASSWORD" '{login_id:$u, password:$p}')

attempt_login() {
  curl -sS -D /tmp/mm-login.headers -o /tmp/mm-login.json -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -d "$login_body" \
    "$MM_URL/api/v4/users/login"
}

log "Logging in as '$ADMIN_USERNAME'"
login_status=$(attempt_login)

if [[ "$login_status" == "401" ]]; then
  log "Login failed — checking whether admin exists"
  create_body=$(jq -n --arg e "$ADMIN_EMAIL" --arg u "$ADMIN_USERNAME" --arg p "$ADMIN_PASSWORD" \
    '{email:$e, username:$u, password:$p}')
  create_status=$(curl -sS -o /tmp/mm-create.json -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -d "$create_body" \
    "$MM_URL/api/v4/users")

  if [[ "$create_status" == "201" ]]; then
    ok "Admin user created"
  elif grep -q 'username_exists\|email_exists\|already exists' /tmp/mm-create.json 2>/dev/null; then
    log "Admin '$ADMIN_USERNAME' already exists — resetting password via mmctl to .env value"
    if compose exec -T mattermost mmctl user change-password "$ADMIN_USERNAME" --password "$ADMIN_PASSWORD" --local >/dev/null 2>&1; then
      ok "Admin password reset to .env value"
    else
      die "mmctl change-password failed — try: docker compose exec mattermost mmctl user search $ADMIN_USERNAME --local"
    fi
  else
    cat /tmp/mm-create.json >&2
    die "failed to create admin (HTTP $create_status)"
  fi

  # MM_EMAILSETTINGS_REQUIREEMAILVERIFICATION=true blocks login until the
  # email is verified. Idempotent — safe to run even if already verified.
  if compose exec -T mattermost mmctl user verify "$ADMIN_USERNAME" --local >/dev/null 2>&1; then
    ok "Admin email verified"
  else
    warn "mmctl user verify failed — bootstrap login will probably fail too"
  fi

  login_status=$(attempt_login)
fi

if [[ "$login_status" != "200" ]]; then
  cat /tmp/mm-login.json >&2
  die "login failed (HTTP $login_status) — check ADMIN_USERNAME / ADMIN_PASSWORD in .env"
fi

ADMIN_TOKEN=$(awk 'tolower($1)=="token:" {print $2}' /tmp/mm-login.headers | tr -d '\r\n')
[[ -n "$ADMIN_TOKEN" ]] || { cat /tmp/mm-login.json >&2; die "login did not return a Token header"; }
ADMIN_USER_ID=$(jq -r '.id' </tmp/mm-login.json)
ok "Logged in (user_id=$ADMIN_USER_ID)"

auth=(-H "Authorization: Bearer $ADMIN_TOKEN")

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

member_body=$(jq -n --arg t "$TEAM_ID" --arg u "$ADMIN_USER_ID" '{team_id:$t, user_id:$u}')
curl -sS "${auth[@]}" -H "Content-Type: application/json" \
  -d "$member_body" \
  "$MM_URL/api/v4/teams/$TEAM_ID/members" >/dev/null || true

# ---- verify backup services running ---------------------------------------
log "Verifying backup services"
for svc in db-backup restic-backup; do
  state=$(compose ps --format json "$svc" 2>/dev/null | jq -r '.State // empty' 2>/dev/null | head -n1)
  if [[ "$state" == "running" ]]; then
    ok "$svc is running"
  else
    warn "$svc state: ${state:-not running} — check 'docker compose logs $svc'"
  fi
done

# ---- done -----------------------------------------------------------------
cat <<EOF

Production setup complete.

  Site:         $MM_URL
  Site name:    $SITE_NAME
  Team:         $TEAM_NAME
  Admin login:  $ADMIN_USERNAME / $ADMIN_PASSWORD
  (password is persisted in .env — recover any time with: grep ^ADMIN_PASSWORD= .env)

Backups:
  Hourly postgres → s3://$S3_BACKUP_BUCKET/mattermost-alley/database-backups/hourly
  Daily postgres  → $BACKUP_ROOT/daily
  Weekly postgres → $BACKUP_ROOT/weekly
  Daily files     → s3://$S3_BACKUP_BUCKET/mattermost-alley/files (restic, encrypted)

  Tail backup logs:  docker compose logs -f db-backup restic-backup
  Verify S3 lands:   aws s3 ls s3://$S3_BACKUP_BUCKET/mattermost-alley/ --recursive

Tail logs:    docker compose logs -f
Upgrade:      docker compose pull && docker compose up -d --build
Re-run me:    ./scripts/setup-prod.sh   (idempotent)
EOF
