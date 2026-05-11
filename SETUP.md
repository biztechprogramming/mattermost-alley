# Setup Walkthrough

End-to-end deployment guide for the Mattermost relay stack
(Postgres + Mattermost + automated backups) on a Linux server you control.
TLS termination is delegated to an upstream nginx on a separate server.

See `README.md` for the project overview and architecture.

---

## Pre-flight — what you need before starting

1. **A Linux server** with Docker installed. This host does NOT need to be
   internet-reachable on 80/443; only the upstream nginx server does.
2. **An upstream nginx server** (different host) already terminating TLS for
   `alley.fastlanedev.com` and able to reach this host on port 8065. See the
   "Upstream nginx" section below for the expected config.
3. **A domain** (e.g. `alley.fastlanedev.com`) whose DNS already points at
   the upstream nginx server.
4. **Docker + Docker Compose v2.** `docker compose version` should print
   something. If not, Phase 1 installs it.
5. **An S3 bucket + IAM credentials** for backups. Reuses the existing
   `racecamp-db-backups` bucket under a new `mattermost-alley/` prefix.

Defaults assumed below: Ubuntu 22.04+, project deployed to
`/srv/environments/dev/mattermost-alley`. Adjust paths to taste.

---

## Phase 1 — Server prep (~5 min)

### 1a. Install Docker and the Compose plugin

Skip if `docker compose version` already works.

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
newgrp docker        # refresh group in the current shell
docker compose version
```

### 1b. Make port 8065 reachable from the upstream nginx

This host needs to accept connections on `:8065` from the upstream nginx
server only. Two common patterns:

- **Tailscale / private network:** set `BIND_ADDR=<this-host's-tailnet-ip>`
  in `.env` so 8065 is only listening on the private interface. Nothing
  else to do — public internet can't reach it.
- **Public network with firewall ACL:** keep `BIND_ADDR=0.0.0.0` (default)
  and restrict in UFW:

  ```bash
  sudo ufw allow from <nginx-server-ip> to any port 8065 proto tcp
  sudo ufw deny  8065/tcp        # deny everything else
  ```

Do NOT expose 8065 to the public internet without an ACL — Mattermost on
plain HTTP behind your TLS proxy is fine, but plain HTTP on the open
internet leaks session tokens.

### 1c. Confirm DNS already resolves

DNS for `$DOMAIN` should already point at the upstream nginx server, not
this host. Sanity check from this server:

```bash
dig +short alley.fastlanedev.com
# should print the upstream nginx server's public IP
```

If it doesn't resolve at all, fix that before continuing — `setup-prod.sh`
bootstraps the admin user via `https://$DOMAIN`, which won't work until
the full path (DNS → nginx → this host → mattermost) is wired up.

### 1d. Create the backup host directories

The `db-backup` container writes daily + weekly dumps to a host bind. The
emailpipeline backup container runs as UID 10000, and `tiredofit/db-backup`
does the same:

```bash
sudo mkdir -p /srv/backups/mattermost-alley/{daily,weekly,logs}
sudo chown -R 10000:10000 /srv/backups/mattermost-alley
```

---

## Phase 2 — Get the code onto the server (~2 min)

Two reasonable paths.

### Option A — push to a git host first (recommended)

On your local workstation, from the project root:

```bash
git init
git add .
git commit -m "Initial Mattermost relay scaffold"
gh repo create mattermost-relay --private --source=. --push
```

Then on the server:

```bash
sudo mkdir -p /srv && cd /srv
sudo git clone git@github.com:YOUR_USER/mattermost-relay.git
sudo chown -R $USER:$USER /srv/mattermost-relay
cd /srv/mattermost-relay
```

### Option B — copy directly with rsync

```bash
rsync -av ./mattermost-relay/ user@your-server:/srv/mattermost-relay/
```

SSH to the server afterward and `cd /srv/mattermost-relay`.

---

## Phase 3 — Configure and boot

```bash
cd /srv/environments/dev/mattermost-alley
./scripts/setup-prod.sh
```

That's the whole phase. If you've already set up this stack on another
machine and pushed `.env` to S3, you can pull it first instead of
re-walking every prompt:

```bash
./scripts/secrets-pull.sh   # downloads .env from S3 (see "Secrets sync" below)
./scripts/setup-prod.sh --non-interactive
```

The script:

1. Prompts you for every value in `.env`. On first run it walks all of
   them; on re-runs it asks whether to **review all** settings or only
   prompt for the ones still **unset**.
2. Auto-generates strong values for `POSTGRES_PASSWORD` and
   `RESTIC_PASSWORD` if you press Enter. For `RESTIC_PASSWORD` it prints
   the generated value once and refuses to continue until you type
   `saved` to confirm you've stored it. **Lose this password and every
   restic file backup is unrecoverable.**
3. Creates `/srv/backups/mattermost-alley/{daily,weekly,logs}` and
   chowns them to UID 10000 (will use `sudo`).
4. Detects whether anything else is bound to port 8065 (e.g. the dev
   compose) and offers to stop it.
5. Initializes the restic repository in S3 (idempotent — no-op if it
   already exists).
6. Resolves `$DOMAIN` to confirm DNS is wired up.
7. `docker compose up -d --build` for postgres + mattermost + the two
   backup services.
8. Waits for `https://$DOMAIN/api/v4/system/ping` to respond through
   the upstream nginx (up to 2 minutes).
9. Logs in as the admin (creating the account on first run); creates
   the team if needed.
10. Verifies both backup containers are in `running` state.
11. Prints a summary with the admin password (auto-generated if not
    provided via `ADMIN_PASSWORD=` env).

Safe to re-run. If the admin or team already exist, it logs in and moves
on. Editing `.env` by hand between runs is also fine — the script picks
up your edits.

Flags worth knowing:

- `--skip-dns-check` — bypass the DNS resolution preflight (useful with
  Tailnet-only or split-horizon DNS).
- `--no-bootstrap` — boot the stack but skip admin/team creation.
- `--non-interactive` — fail instead of prompting if any required value
  is empty (for CI / Ansible / etc).

> Note: the stack will boot fine without the `SES_*` variables, but
> Mattermost will surface a "Preview Mode: Email notifications have not
> been configured" banner and email invites won't send. Phase 5 fixes both.

If you get a 502 or connection refused when the script polls `$DOMAIN`,
the upstream nginx isn't reaching this host on 8065 — see the "Upstream
nginx" section below.

---

## Phase 4 — First-time Mattermost setup (~5 min)

Skip this phase if you used `./scripts/setup-prod.sh` — the admin and team
are already created.

1. **Create the admin account.** The first account registered is
   automatically sysadmin. Use a real email and a strong password — this is
   the root-level admin for the whole server.
2. **Create a team** (any URL slug — your subscribers will join this team).
3. **Create a channel** (or use the default Town Square) — this is where
   your 30 subscribers will post.
4. (Optional) In **System Console → Site Configuration → Customization**
   you can set the site name, description, and help link shown to users.

---

## Phase 5 — Email (AWS SES)

This stack is wired for SES SMTP via env vars in `docker-compose.yml`. You
just need to (a) verify your sending domain in SES, (b) create SMTP
credentials, and (c) drop the values into `.env`. Three actions, all in
the AWS console.

### 5a. Verify the sending domain

SES console → **Verified identities → Create identity → Domain**.

- **Identity type:** Domain
- **Domain:** the host you'll send from (e.g. `alley.fastlanedev.com`).
  Use the same host you'll use for `SES_FROM_ADDRESS` — verifying the
  parent zone (`fastlanedev.com`) also works and covers any subdomain.
- **DKIM:** leave "Easy DKIM" with RSA 2048-bit selected.
- **Use a custom MAIL FROM domain:** optional but recommended — improves
  SPF alignment. Set it to e.g. `mail.alley.fastlanedev.com`.

SES generates **3 CNAME records** (DKIM) plus, if you opted in, an MX +
TXT pair for the MAIL FROM domain. Publish them in your DNS host. SES
re-checks every few minutes; status flips to **Verified** within ~15 min
once DNS propagates.

### 5b. Create SMTP credentials

SES console → **SMTP settings → Create SMTP credentials**. This creates a
dedicated IAM user (default name `ses-smtp-user.YYYYMMDD-...`) with the
`AmazonSesSendingAccess` managed policy, and shows you a **one-time**
SMTP username and password. They look like AWS credentials but are *not*
your normal access key — they're transformed via SigV4 into SMTP-AUTH
creds. **Save them now**; the password can't be retrieved later, only
rotated.

### 5c. Wire them into `.env`

```
SES_SMTP_HOST=email-smtp.us-east-1.amazonaws.com
SES_SMTP_USERNAME=AKIA...                    # from step 5b
SES_SMTP_PASSWORD=BNz...                     # from step 5b
SES_FROM_ADDRESS=noreply@alley.fastlanedev.com
```

Then restart Mattermost so it picks up the new env:

```bash
docker compose up -d mattermost
```

### 5d. Sandbox-mode caveat

New SES accounts are in the **sandbox**: you can only send to addresses
you've explicitly verified, and you're capped at 200 messages/day, 1/sec.
For a private group of ~30 known invitees this is usually fine — verify
each invitee's email under **Verified identities → Create identity →
Email address** before sending them an invite. Each one gets a one-click
verification link.

When the group outgrows that workflow, **Account dashboard → Request
production access** opens up unrestricted sending after a short
questionnaire (typical turnaround: 24h).

### 5e. Smoke test

In the Mattermost web UI: **System Console → Environment → SMTP → Test
Connection**. Should report success within a couple seconds. If it fails:

- `535 Authentication Credentials Invalid` → wrong SMTP user/pass (step 5b).
- `554 Email address is not verified` → you're in sandbox and the *FROM*
  address (`SES_FROM_ADDRESS`) isn't on a verified identity. Re-check 5a.
- Connection timeout → outbound port 587 blocked at your firewall/VPC.

---

## Phase 6 — Invite your subscribers

**Main Menu → Invite People**. Two options:

1. **Email invites** (recommended now that Phase 5 is done) — Mattermost
   sends each invitee a single-use link tied to their address. No
   forwarding shenanigans, and combined with `EnableOpenServer=false`
   (the default) this is "only people I invite" in the strict sense.
   *In SES sandbox:* verify each invitee's email in SES first (Phase 5d).
2. **Invite link** — generate a team-scoped URL, share it however
   (text/DM/email). Recipients open it, create an account, they're in.
   Looser than email invites — anyone the link is forwarded to can join.

For tighter control, after everyone's joined you can flip
`MM_TEAMSETTINGS_ENABLEUSERCREATION=false` (set it on the `mattermost`
service in `docker-compose.yml` and restart) to refuse all further new
accounts until you flip it back.

---

## Upstream nginx

This stack does NOT terminate TLS. The upstream nginx (on a different
server) needs to forward `https://alley.fastlanedev.com` to this host on
port 8065 with the right headers. A working `location` block looks like:

```nginx
location / {
    proxy_pass http://<this-host>:8065;
    proxy_http_version 1.1;

    # Critical: without these, Mattermost thinks every request is plain
    # http on the nginx server, breaks redirects, and logs the wrong IP.
    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;

    # Mattermost uses websockets for real-time delivery.
    proxy_set_header Upgrade           $http_upgrade;
    proxy_set_header Connection        "upgrade";

    proxy_read_timeout                 600s;
    proxy_send_timeout                 600s;
    client_max_body_size               50M;     # match MM_FILESETTINGS_MAXFILESIZE
}
```

If WebSockets aren't upgraded, the UI silently falls back to long-polling
and feels sluggish. If `X-Forwarded-Proto` is missing, OAuth callbacks and
"reset password" links generate `http://` URLs and break.

---

## Secrets sync (S3)

`.env` contains every secret the stack needs (postgres password, SES creds,
S3 keys, restic password, admin password). To avoid retyping it on each
machine you operate this from, the repo includes three scripts that
sync `.env` to S3 with full version history and a keys-only audit log.

| Script | Purpose |
|---|---|
| `./scripts/secrets-push.sh` | Diff local `.env` vs S3, append audit entry, upload |
| `./scripts/secrets-pull.sh` | Download latest (or `--version-id <id>`) to local |
| `./scripts/secrets-diff.sh` | Preview what `push` would do, no upload |

**Storage layout** (under your existing `racecamp-db-backups` bucket):

```
s3://racecamp-db-backups/mattermost-alley/secrets/
├── .env                  # latest; S3 versioning keeps every previous push
└── secrets-audit.log     # append-only "who changed which keys when"
```

**Security model:**

- Encryption at rest via the bucket's default SSE-KMS (free, AWS-managed key).
- Bucket versioning is enabled automatically by `secrets-push.sh` on first run.
- The audit log records **only the keys that changed** — never values.
  Previous values are recoverable via S3 versioning, not via the log.
  This keeps the log safe to share / non-honeypot if someone gains read access.
- Diff output in the terminal shows fingerprinted values (`a3f9…c8d2`).
  Pass `--show-values` for full reveal when you really need it.

**First time, on the machine where `.env` is correct:**

```bash
./scripts/secrets-push.sh --first-push
```

Before that works, **enable bucket versioning once** (the backup IAM user
intentionally doesn't have permission to flip this — it's an admin action):

> AWS console → S3 → `racecamp-db-backups` → Properties tab →
> Bucket Versioning → Edit → Enable → Save.

Five clicks, one time. If you skip this, pushes still work but you lose
the version history that makes recovery possible.

**On a fresh machine after `git clone`:**

```bash
./scripts/secrets-pull.sh
./scripts/setup-prod.sh --non-interactive
```

**After editing `.env`:**

```bash
./scripts/secrets-diff.sh           # preview
./scripts/secrets-push.sh           # confirm + upload
```

**Recover a previous version** (e.g. you pushed a bad edit):

```bash
aws s3api list-object-versions \
  --bucket racecamp-db-backups \
  --prefix mattermost-alley/secrets/.env \
  --query 'Versions[].[VersionId,LastModified]' --output table

./scripts/secrets-pull.sh --version-id <chosen-VersionId>
```

**Read the audit log:**

```bash
aws s3 cp s3://racecamp-db-backups/mattermost-alley/secrets/secrets-audit.log -
```

**Cost:** effectively $0/month at this usage. ~1 KB per version + a handful
of KMS API calls per push.

---

## Ongoing operations

### Routine commands

| Task | Command |
|---|---|
| Tail all logs | `docker compose logs -f` |
| Tail one service | `docker compose logs -f mattermost` |
| Stop everything (preserves data) | `docker compose down` |
| Wipe everything (destroys data) | `docker compose down -v` |
| Check service health | `docker compose ps` |
| Shell into Mattermost | `docker compose exec mattermost bash` |

### Upgrades

Mattermost releases roughly monthly.

```bash
cd /srv/mattermost-relay
docker compose pull
docker compose up -d
```

Always take a Postgres backup first (below) — a bad upgrade is rare, but
restoring is much nicer with a recent dump on hand.

### Backups

Backups run automatically inside the compose stack — no host cron needed.

**Postgres** (`db-backup` service, image `tiredofit/db-backup`):

| Tier | Cadence | Destination | Retention |
|---|---|---|---|
| Hourly | every 60 min | `s3://racecamp-db-backups/mattermost-alley/database-backups/hourly` | 2 days |
| Daily | 01:30 | host `/srv/backups/mattermost-alley/daily` | 30 days |
| Weekly | Sun 02:30 | host `/srv/backups/mattermost-alley/weekly` | ~12 weeks |

**Uploaded files** (`restic-backup` service, image `mazzolino/restic`):

| Cadence | Destination | Retention |
|---|---|---|
| Daily 03:30 | `s3://racecamp-db-backups/mattermost-alley/files` (encrypted) | 7 daily / 4 weekly / 6 monthly |

Health-check after first boot:

```bash
docker compose logs -f db-backup restic-backup
aws s3 ls s3://racecamp-db-backups/mattermost-alley/ --recursive | tail -20
```

#### Restoring postgres

From the hourly S3 tier:

```bash
aws s3 cp s3://racecamp-db-backups/mattermost-alley/database-backups/hourly/<file>.sql.gz .
gunzip -c <file>.sql.gz | docker compose exec -T postgres psql -U mattermost mattermost
```

From the local daily/weekly tier:

```bash
ls /srv/backups/mattermost-alley/daily/
gunzip -c /srv/backups/mattermost-alley/daily/<file>.sql.gz \
  | docker compose exec -T postgres psql -U mattermost mattermost
```

#### Restoring uploaded files

```bash
# List available snapshots
docker compose run --rm -e RESTIC_PASSWORD --env-file .env restic-backup \
  restic snapshots

# Restore the latest snapshot into a scratch dir
docker compose run --rm -v /tmp/mm-restore:/restore restic-backup \
  restic restore latest --target /restore

# Copy back into the live volume (stop mattermost first)
docker compose stop mattermost
docker run --rm -v mattermost-alley_mattermost-data:/dst -v /tmp/mm-restore:/src alpine \
  sh -c "rm -rf /dst/* && cp -a /src/data/mattermost-data/. /dst/"
docker compose start mattermost
```

#### Quarterly restore drill

The backup is worthless if you've never restored from it. Once a quarter:

1. Pick a recent hourly S3 dump and restore it into a scratch postgres
   container — confirm row counts look reasonable.
2. Run `restic check` against the file-uploads repo to verify integrity.
3. Note the date in a calendar / ops log.

### Monitoring (lightweight)

If you want a cheap uptime ping:
- [UptimeRobot](https://uptimerobot.com/) free tier monitors
  `https://chat.yourdomain.com/api/v4/system/ping` and emails you on
  failure.
- Mattermost itself exposes `/metrics` (Prometheus format) if you
  enable it in System Console → Environment → Performance Monitoring.
