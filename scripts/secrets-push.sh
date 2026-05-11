#!/usr/bin/env bash
# Push the local .env to S3 with audit logging.
#
# What it does:
#   1. Downloads the current remote .env to /tmp.
#   2. Diffs local vs remote; prints a fingerprinted summary.
#   3. If different and confirmed, appends a keys-only entry to the audit log
#      and uploads the new .env to S3. Bucket versioning preserves history.
#   4. Old values are NEVER written to the audit log — recover them via
#      `aws s3api list-object-versions` (see SETUP.md → "Secrets").
#
# Flags:
#   --yes              Skip the confirmation prompt
#   --show-values      Show full values instead of fingerprints (terminal only;
#                      audit log never contains values regardless)
#   --first-push       Allow uploading even if there's no remote (first run)
#   -h | --help        Print this header

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

ENV_FILE="$PROJECT_DIR/.env"

log()  { printf "==> %s\n" "$*"; }
ok()   { printf " ok  %s\n" "$*"; }
warn() { printf "  !  %s\n" "$*" >&2; }
die()  { printf "  x  %s\n" "$*" >&2; exit 1; }

YES=0
SHOW_VALUES=0
FIRST_PUSH=0
for arg in "$@"; do
  case "$arg" in
    --yes)         YES=1 ;;
    --show-values) SHOW_VALUES=1 ;;
    --first-push)  FIRST_PUSH=1 ;;
    -h|--help)     sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $arg (try --help)" ;;
  esac
done

# ---- preflight ------------------------------------------------------------
for bin in aws; do
  command -v "$bin" >/dev/null 2>&1 || die "missing required binary: $bin"
done
[[ -f "$ENV_FILE" ]] || die ".env not found at $ENV_FILE"

# ---- read S3 destination + creds from .env --------------------------------
# We need BUCKET + REGION + creds to talk to S3. They live in .env (set by setup-prod.sh).
# shellcheck disable=SC1091
set -a; . "$ENV_FILE"; set +a
[[ -n "${S3_BACKUP_BUCKET:-}" ]] || die "S3_BACKUP_BUCKET is not set in .env"
[[ -n "${S3_BACKUP_REGION:-}" ]] || S3_BACKUP_REGION=us-east-1

# Translate the project's S3_BACKUP_* keys into the standard AWS CLI env
# var names so aws CLI calls in this script authenticate without touching
# ~/.aws/credentials. Overrides any ambient AWS_* vars for this script only.
if [[ -n "${S3_BACKUP_KEY_ID:-}" && -n "${S3_BACKUP_KEY_SECRET:-}" ]]; then
  export AWS_ACCESS_KEY_ID="$S3_BACKUP_KEY_ID"
  export AWS_SECRET_ACCESS_KEY="$S3_BACKUP_KEY_SECRET"
  export AWS_DEFAULT_REGION="$S3_BACKUP_REGION"
fi

S3_PREFIX="s3://${S3_BACKUP_BUCKET}/mattermost-alley/secrets"
REMOTE_ENV="${S3_PREFIX}/.env"
AUDIT_LOG="${S3_PREFIX}/secrets-audit.log"

# ---- check bucket versioning (informational only) -------------------------
# Enabling versioning is a one-time admin operation — the backup IAM user
# deliberately doesn't have s3:PutBucketVersioning, so we don't try here.
# We try to read the status, but if the user lacks GetBucketVersioning too,
# we just warn once and continue. Pushes still work without versioning;
# they just don't get history.
versioning=$(aws s3api get-bucket-versioning --bucket "$S3_BACKUP_BUCKET" \
  --region "$S3_BACKUP_REGION" --query Status --output text 2>/dev/null || echo "unknown")
case "$versioning" in
  Enabled)
    ;;
  unknown)
    warn "Could not check bucket versioning status (IAM user lacks GetBucketVersioning)"
    warn "Make sure versioning is enabled — AWS console → S3 → racecamp-db-backups → Properties → Bucket Versioning"
    ;;
  *)
    warn "Bucket versioning is NOT enabled on $S3_BACKUP_BUCKET — pushes will overwrite history."
    warn "Enable: AWS console → S3 → $S3_BACKUP_BUCKET → Properties → Bucket Versioning → Edit → Enable"
    read -r -p "Continue anyway? [y/N]: " yn
    [[ "${yn:-N}" =~ ^[yY]$ ]] || die "aborting — enable versioning then re-run"
    ;;
esac

# ---- env parsing helper ---------------------------------------------------
# Read a .env file into name=value pairs on stdout, one per line.
# Skips blanks and comment lines. Doesn't expand or quote-strip beyond trivial.
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

# Look up a key's value in a parsed-env stream (from stdin).
value_of() {
  local key="$1"
  awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); print; exit }'
}

# Fingerprint a value: first 4 + last 4 chars with … in middle.
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

# ---- pull current remote --------------------------------------------------
REMOTE_LOCAL=$(mktemp /tmp/secrets-remote.XXXXXX)
trap 'rm -f "$REMOTE_LOCAL" "$AUDIT_LOCAL" 2>/dev/null' EXIT

remote_exists=1
if ! aws s3 cp "$REMOTE_ENV" "$REMOTE_LOCAL" \
     --region "$S3_BACKUP_REGION" --only-show-errors 2>/dev/null; then
  remote_exists=0
  : > "$REMOTE_LOCAL"
fi

if [[ "$remote_exists" -eq 0 && "$FIRST_PUSH" -eq 0 ]]; then
  warn "No remote .env exists at $REMOTE_ENV"
  warn "If this is the first push for this project, re-run with --first-push"
  exit 1
fi

# ---- diff ------------------------------------------------------------------
declare -A LOCAL_KV REMOTE_KV
while IFS= read -r kv; do
  k="${kv%%=*}"; v="${kv#*=}"
  LOCAL_KV["$k"]="$v"
done < <(parse_env "$ENV_FILE")

while IFS= read -r kv; do
  k="${kv%%=*}"; v="${kv#*=}"
  REMOTE_KV["$k"]="$v"
done < <(parse_env "$REMOTE_LOCAL")

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

# ---- present diff to user --------------------------------------------------
echo
echo "Changes vs $REMOTE_ENV:"
echo
if [[ ${#added[@]} -gt 0 ]]; then
  echo "  added:"
  for k in "${added[@]}"; do
    printf '    + %s  =  %s\n' "$k" "$(fingerprint "${LOCAL_KV[$k]}")"
  done
fi
if [[ ${#removed[@]} -gt 0 ]]; then
  echo "  removed:"
  for k in "${removed[@]}"; do
    printf '    - %s  (was: %s)\n' "$k" "$(fingerprint "${REMOTE_KV[$k]}")"
  done
fi
if [[ ${#changed[@]} -gt 0 ]]; then
  echo "  changed:"
  for k in "${changed[@]}"; do
    printf '    ~ %s\n' "$k"
    printf '        was:  %s\n' "$(fingerprint "${REMOTE_KV[$k]}")"
    printf '        new:  %s\n' "$(fingerprint "${LOCAL_KV[$k]}")"
  done
fi
echo

if [[ "$YES" -ne 1 ]]; then
  read -r -p "Push these changes? [Y/n]: " yn
  [[ "${yn:-Y}" =~ ^[nN]$ ]] && { log "aborted"; exit 0; }
fi

# ---- append audit entry ---------------------------------------------------
AUDIT_LOCAL=$(mktemp /tmp/secrets-audit.XXXXXX)

if ! aws s3 cp "$AUDIT_LOG" "$AUDIT_LOCAL" \
     --region "$S3_BACKUP_REGION" --only-show-errors 2>/dev/null; then
  : > "$AUDIT_LOCAL"   # no existing log → start fresh
fi

actor="$(whoami)@$(hostname -s 2>/dev/null || hostname)"
ts="$(date -u +%Y-%m-%dT%H:%MZ)"
{
  printf '\n%s  %s  pushed\n' "$ts" "$actor"
  [[ ${#added[@]}   -gt 0 ]] && printf '  added:    %s\n'   "$(IFS=,; echo "${added[*]}")"
  [[ ${#changed[@]} -gt 0 ]] && printf '  changed:  %s\n'   "$(IFS=,; echo "${changed[*]}")"
  [[ ${#removed[@]} -gt 0 ]] && printf '  removed:  %s\n'   "$(IFS=,; echo "${removed[*]}")"
} >> "$AUDIT_LOCAL"

# ---- upload ---------------------------------------------------------------
log "Uploading new .env to $REMOTE_ENV"
aws s3 cp "$ENV_FILE" "$REMOTE_ENV" --region "$S3_BACKUP_REGION" --only-show-errors

log "Uploading updated audit log to $AUDIT_LOG"
aws s3 cp "$AUDIT_LOCAL" "$AUDIT_LOG" --region "$S3_BACKUP_REGION" --only-show-errors

ok "Push complete (+${#added[@]} -${#removed[@]} ~${#changed[@]})"
echo
echo "Recover a previous value:"
echo "  aws s3api list-object-versions --bucket $S3_BACKUP_BUCKET \\"
echo "    --prefix mattermost-alley/secrets/.env --region $S3_BACKUP_REGION"
