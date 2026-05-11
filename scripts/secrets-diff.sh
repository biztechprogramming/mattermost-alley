#!/usr/bin/env bash
# Show what would change if you ran secrets-push.sh, without uploading.
# Delegates to secrets-push.sh with internal --dry-run handling.
#
# Flags:
#   --show-values   Show full values instead of fingerprints
#   -h | --help     Print this header

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

ENV_FILE="$PROJECT_DIR/.env"

log()  { printf "==> %s\n" "$*"; }
ok()   { printf " ok  %s\n" "$*"; }
die()  { printf "  x  %s\n" "$*" >&2; exit 1; }

SHOW_VALUES=0
for arg in "$@"; do
  case "$arg" in
    --show-values) SHOW_VALUES=1 ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $arg (try --help)" ;;
  esac
done

command -v aws >/dev/null 2>&1 || die "missing required binary: aws"
[[ -f "$ENV_FILE" ]] || die ".env not found at $ENV_FILE"

# shellcheck disable=SC1091
set -a; . "$ENV_FILE"; set +a
[[ -n "${S3_BACKUP_BUCKET:-}" ]] || die "S3_BACKUP_BUCKET is not set in .env"
[[ -n "${S3_BACKUP_REGION:-}" ]] || S3_BACKUP_REGION=us-east-1

# Use the project's backup creds for aws CLI calls in this script.
if [[ -n "${S3_BACKUP_KEY_ID:-}" && -n "${S3_BACKUP_KEY_SECRET:-}" ]]; then
  export AWS_ACCESS_KEY_ID="$S3_BACKUP_KEY_ID"
  export AWS_SECRET_ACCESS_KEY="$S3_BACKUP_KEY_SECRET"
  export AWS_DEFAULT_REGION="$S3_BACKUP_REGION"
fi

REMOTE_ENV="s3://${S3_BACKUP_BUCKET}/mattermost-alley/secrets/.env"

parse_env() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      printf '%s=%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    fi
  done < "$f"
}

fingerprint() {
  local v="$1"
  local n=${#v}
  if [[ "$SHOW_VALUES" -eq 1 ]]; then
    printf '%s' "$v"
  elif [[ $n -le 8 ]]; then
    printf '***'
  else
    printf '%s…%s' "${v:0:4}" "${v: -4}"
  fi
}

REMOTE_LOCAL=$(mktemp /tmp/secrets-remote.XXXXXX)
trap 'rm -f "$REMOTE_LOCAL"' EXIT

if ! aws s3 cp "$REMOTE_ENV" "$REMOTE_LOCAL" \
     --region "$S3_BACKUP_REGION" --only-show-errors 2>/dev/null; then
  log "No remote .env exists at $REMOTE_ENV — every local key would be 'added'"
  : > "$REMOTE_LOCAL"
fi

declare -A LOCAL_KV REMOTE_KV
while IFS= read -r kv; do k="${kv%%=*}"; LOCAL_KV["$k"]="${kv#*=}"; done < <(parse_env "$ENV_FILE")
while IFS= read -r kv; do k="${kv%%=*}"; REMOTE_KV["$k"]="${kv#*=}"; done < <(parse_env "$REMOTE_LOCAL")

added=() removed=() changed=()
for k in "${!LOCAL_KV[@]}"; do
  if [[ -z "${REMOTE_KV[$k]+x}" ]]; then
    added+=("$k")
  elif [[ "${LOCAL_KV[$k]}" != "${REMOTE_KV[$k]}" ]]; then
    changed+=("$k")
  fi
done
for k in "${!REMOTE_KV[@]}"; do
  [[ -z "${LOCAL_KV[$k]+x}" ]] && removed+=("$k")
done

total=$((${#added[@]} + ${#removed[@]} + ${#changed[@]}))
if [[ "$total" -eq 0 ]]; then
  ok "No changes — local .env is identical to remote"
  exit 0
fi

echo
echo "Local .env vs $REMOTE_ENV:"
echo
if [[ ${#added[@]} -gt 0 ]]; then
  echo "  added (would create on push):"
  for k in "${added[@]}"; do printf '    + %s  =  %s\n' "$k" "$(fingerprint "${LOCAL_KV[$k]}")"; done
fi
if [[ ${#removed[@]} -gt 0 ]]; then
  echo "  removed (would disappear on push):"
  for k in "${removed[@]}"; do printf '    - %s  (was: %s)\n' "$k" "$(fingerprint "${REMOTE_KV[$k]}")"; done
fi
if [[ ${#changed[@]} -gt 0 ]]; then
  echo "  changed:"
  for k in "${changed[@]}"; do
    printf '    ~ %s\n' "$k"
    printf '        remote:  %s\n' "$(fingerprint "${REMOTE_KV[$k]}")"
    printf '        local:   %s\n' "$(fingerprint "${LOCAL_KV[$k]}")"
  done
fi
echo
echo "Run ./scripts/secrets-push.sh to apply these changes to S3."
