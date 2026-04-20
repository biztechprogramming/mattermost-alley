# Setup Walkthrough

End-to-end deployment guide for the Mattermost relay stack
(Postgres + Mattermost + Caddy) on a Linux server you control.

See `README.md` for the project overview and architecture.

---

## Pre-flight — what you need before starting

1. **A Linux server** — cloud VPS with a public IP, or a box at home with
   ports 80/443 forwarded through your router.
2. **A domain** (e.g. `chat.yourdomain.com`) whose DNS you control.
3. **Docker + Docker Compose v2.** `docker compose version` should print
   something. If it says "not found," Phase 1 installs it.
4. **Shell access** to the server as a user who can run `sudo` (for initial
   Docker install + firewall changes) or who's already in the `docker` group.

Defaults assumed below: Ubuntu 22.04+, project deployed to
`/srv/mattermost-relay`. Adjust paths if you prefer `/opt/...` or your home
directory.

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

### 1b. Open ports 80 and 443

On the server itself (UFW is the Ubuntu/Debian default):

```bash
sudo ufw allow 22/tcp        # keep SSH reachable before enabling
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
```

- **Port 80** is required — Let's Encrypt uses HTTP-01 challenges over
  plain HTTP to prove domain ownership.
- **Port 443** is where all real traffic lives once TLS is issued.

If the server is behind a home router / NAT, also forward 80 and 443 on the
router to this box's LAN IP. Residential ISPs occasionally block port 80
inbound — test with `curl http://your-domain` from a mobile hotspot once DNS
is pointed (Phase 1c) to confirm.

### 1c. Point DNS at the server

Create an A record at your DNS provider:

```
chat.yourdomain.com.   A   <your-public-IP>
```

Verify from **a different network** (phone on mobile data works):

```bash
dig +short chat.yourdomain.com
# should print your public IP
```

Wait ~5–10 minutes for the record to propagate before proceeding. Caddy will
fail noisily on first boot if DNS isn't resolving yet.

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

## Phase 3 — Configure and boot (~5 min)

```bash
cd /srv/mattermost-relay
cp .env.example .env
```

Edit `.env`:

```
DOMAIN=chat.yourdomain.com
ACME_EMAIL=you@yourdomain.com
TZ=America/New_York                # or your timezone
POSTGRES_PASSWORD=<strong random>
```

Generate and inject a strong Postgres password in one step:

```bash
sed -i "s|POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$(openssl rand -base64 32)|" .env
```

### Fast path — one script does the rest

```bash
./scripts/setup-prod.sh
```

That builds the branded image, boots postgres + mattermost + caddy, waits
for Caddy to issue a Let's Encrypt cert, then creates the admin user and
team via the Mattermost API. Auto-generates and prints an admin password
if you don't provide `ADMIN_PASSWORD`. Safe to re-run — if the admin or
team already exist, it logs in and moves on.

Flags worth knowing:

- `--skip-dns-check` — bypass the DNS-vs-public-IP preflight (useful
  behind split-horizon DNS or when running from the server itself).
- `--no-bootstrap` — boot the stack but skip admin/team creation; leaves
  you to do it in the browser.

If that worked, skip to Phase 5. Everything below is the manual
equivalent, kept for when you want to understand or debug what the script
is doing.

> Note: the stack will boot fine without the `SES_*` variables in `.env`,
> but Mattermost will surface a "Preview Mode: Email notifications have not
> been configured" banner and email invites won't send. Phase 5 fixes both.

### Manual equivalent

```bash
docker compose up -d --build
docker compose logs -f caddy mattermost
```

What to look for in the logs within ~60 seconds:

- Caddy: `certificate obtained successfully` for your domain
- Mattermost: `Server is listening on :8065`

If Caddy emits `could not get certificate`, stop and fix DNS / port 80
reachability before continuing — nothing else will work until TLS is issued.

Visit `https://chat.yourdomain.com` in a browser. You should see
Mattermost's "Create Account" screen with a valid green-padlock TLS cert.

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

Two volumes to back up:

| Volume | Contents | How often |
|---|---|---|
| `postgres-data` | All messages, channels, users | Daily |
| `mattermost-data` | Uploaded files / attachments | Weekly |

Nightly Postgres dump to a local file:

```bash
mkdir -p /srv/mattermost-relay/backups
docker compose exec -T postgres pg_dump -U mattermost mattermost \
  | gzip > /srv/mattermost-relay/backups/mm-$(date +%F).sql.gz
```

Wrap that in cron (e.g. `0 3 * * *`) and copy the output off-box
(Backblaze B2 / S3 / a second server). Without off-box backups, a disk
failure loses your whole chat history.

### Monitoring (lightweight)

If you want a cheap uptime ping:
- [UptimeRobot](https://uptimerobot.com/) free tier monitors
  `https://chat.yourdomain.com/api/v4/system/ping` and emails you on
  failure.
- Mattermost itself exposes `/metrics` (Prometheus format) if you
  enable it in System Console → Environment → Performance Monitoring.
