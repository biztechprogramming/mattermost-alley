#!/usr/bin/env bash
# Pull the .env from S3 to local. Backs up any existing local .env first
# so a bad pull doesn't lose unsaved edits.
#
# Flags:
#   --version-id <id>   Pull a specific S3 version instead of the latest
#                       (find via 'aws s3api list-object-versions')
#   --yes               Skip the "overwrite local?" confirmation
#   -h | --help         Print this header

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

ENV_FILE="$PROJECT_DIR/.env"

log()  { printf "==> %s\n" "$*"; }
ok()   { printf " ok  %s\n" "$*"; }
warn() { printf "  !  %s\n" "$*" >&2; }
die()  { printf "  x  %s\n" "$*" >&2; exit 1; }

VERSION_ID=""
YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version-id) VERSION_ID="$2"; shift 2 ;;
    --yes)        YES=1; shift ;;
    -h|--help)    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

command -v aws >/dev/null 2>&1 || die "missing required binary: aws"

# S3 destination — pulled from .env if it exists, prompted otherwise (so a
# fresh machine with no .env can still recover one).
S3_BACKUP_BUCKET=""
S3_BACKUP_REGION=""
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1091
  set -a; . "$ENV_FILE"; set +a
fi

if [[ -z "${S3_BACKUP_BUCKET:-}" ]]; then
  read -r -p "S3 bucket [racecamp-db-backups]: " S3_BACKUP_BUCKET
  S3_BACKUP_BUCKET="${S3_BACKUP_BUCKET:-racecamp-db-backups}"
fi
[[ -n "${S3_BACKUP_REGION:-}" ]] || S3_BACKUP_REGION=us-east-1

# Use the project's backup creds if .env had them. On a fresh machine
# with no .env yet, fall back to whatever aws CLI has configured.
if [[ -n "${S3_BACKUP_KEY_ID:-}" && -n "${S3_BACKUP_KEY_SECRET:-}" ]]; then
  export AWS_ACCESS_KEY_ID="$S3_BACKUP_KEY_ID"
  export AWS_SECRET_ACCESS_KEY="$S3_BACKUP_KEY_SECRET"
  export AWS_DEFAULT_REGION="$S3_BACKUP_REGION"
fi

REMOTE_ENV="s3://${S3_BACKUP_BUCKET}/mattermost-alley/secrets/.env"

# ---- back up existing local .env ------------------------------------------
if [[ -f "$ENV_FILE" ]]; then
  if [[ "$YES" -ne 1 ]]; then
    echo "Local .env already exists. It will be backed up to:"
    echo "  $ENV_FILE.bak.$(date +%Y%m%d-%H%M%S)"
    read -r -p "Continue? [Y/n]: " yn
    [[ "${yn:-Y}" =~ ^[nN]$ ]] && { log "aborted"; exit 0; }
  fi
  bak="$ENV_FILE.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "$ENV_FILE" "$bak"
  ok "Backed up existing .env → $bak"
fi

# ---- download -------------------------------------------------------------
if [[ -n "$VERSION_ID" ]]; then
  log "Downloading version $VERSION_ID from $REMOTE_ENV"
  aws s3api get-object \
    --bucket "$S3_BACKUP_BUCKET" \
    --key "mattermost-alley/secrets/.env" \
    --version-id "$VERSION_ID" \
    --region "$S3_BACKUP_REGION" \
    "$ENV_FILE" >/dev/null
else
  log "Downloading latest $REMOTE_ENV"
  aws s3 cp "$REMOTE_ENV" "$ENV_FILE" \
    --region "$S3_BACKUP_REGION" --only-show-errors
fi

chmod 600 "$ENV_FILE"
ok "Pulled to $ENV_FILE (mode 0600)"
