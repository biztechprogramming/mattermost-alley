# Mattermost Relay

Self-hosted group chat for ~30 people, replacing the Twilio SMS relay.
Mattermost handles everything — channels, message delivery, mute, roster,
file uploads — so this repo is just the thin deployment layer around it.

## Stack

```
Internet ──► Upstream nginx (TLS, 443) ──► this host :8065 ──► Mattermost ──► Postgres
                  (separate server)                                   │
                                                                      ├─► db-backup   (postgres → S3 + local FS)
                                                                      └─► restic-backup (uploads → S3, encrypted)
```

TLS termination lives on a different server you already run. This host
just listens on `:8065` and trusts the upstream's `X-Forwarded-*` headers.
Postgres and the two backup sidecars are on an internal Docker network.

## Layout

```
.
├── docker-compose.yml         # Postgres + Mattermost + db-backup + restic-backup (production)
├── docker-compose.local.yml   # Postgres + Mattermost only, on localhost:8066 (dev)
├── Dockerfile.branded         # Rebrands the Mattermost image at build time
├── branding/                  # Drop-in favicon + icon PNG overrides
├── .env.example               # Reference; setup-prod.sh generates the real .env interactively
├── scripts/
│   ├── setup-prod.sh          # One-shot: prompts for .env, boots stack, inits restic, bootstraps admin
│   ├── setup-local.sh         # Dev equivalent (no prompts, hardcoded creds)
│   ├── seed-channels.sh       # Idempotent channel seeding
│   ├── secrets-push.sh        # Upload .env to S3 with keys-only audit log
│   ├── secrets-pull.sh        # Download .env from S3 (latest or specific version)
│   └── secrets-diff.sh        # Preview what push would do
├── SETUP.md                   # End-to-end production deployment walkthrough
└── LOCAL_DEV.md               # Rehearse the setup on your workstation
```

## Rebranding

Set `SITE_NAME=Rally` (or whatever) in `.env` and `docker compose up -d --build`.
That rewrites every user-visible occurrence of "Mattermost" to your chosen
name inside the container at build time — translation files + the HTML page
title — and sets the in-app site name via `MM_TEAMSETTINGS_SITENAME`. Drop
favicon.ico and icon PNGs into `branding/` to replace the default art; see
`branding/README.md` for the full file list. The base image is upstream
Mattermost Team Edition, so monthly upgrades are still just
`docker compose pull && docker compose up -d --build`.

## Prerequisites

- A Linux box with Docker + Docker Compose v2.
- An **upstream nginx** on a different server that already terminates TLS
  for `$DOMAIN` and forwards to this host on `:8065` with
  `X-Forwarded-Proto: https`, `X-Forwarded-For`, and WebSocket upgrade
  headers. See SETUP.md → "Upstream nginx" for the exact `location` block.
- DNS for `$DOMAIN` already pointing at the upstream nginx server.
- An **S3 bucket + IAM credentials** for backups (reuses
  `racecamp-db-backups` under a `mattermost-alley/` prefix).
- A way to restrict inbound `:8065` on this host to the nginx server only —
  either via a private interface (`BIND_ADDR=<tailnet-ip>` in `.env`) or a
  firewall ACL. Do NOT expose `:8065` to the public internet without one.

This host does NOT need ports 80 or 443 open; TLS is the upstream's job.

## Quick start

```bash
cd mattermost-alley
./scripts/setup-prod.sh
```

The script walks you through every `.env` value on first run (just the
unset ones on re-runs), creates host-side backup directories, initializes
the restic repo, boots the stack, waits for the upstream nginx to reach
`https://$DOMAIN`, and bootstraps the admin account + team. Re-runnable.

Full walkthrough: **SETUP.md**. To rehearse locally with no TLS / no
domain on `:8066`: **LOCAL_DEV.md**.

## Why no custom bot?

The SMS relay needed a service to fan out one inbound SMS to 30 outbound
SMS. Mattermost delivers messages natively — post in a channel, members
are notified — so the fan-out problem disappears. `/mute` (channel
notifications), `/status` (user presence), and the member list are all
Mattermost built-ins; writing a bot to reimplement them would just be
code to maintain for no gain.

If later you need the server to *originate* messages (scheduled reminders,
an inbound SMS bridge for holdouts who won't install the app), add a bot
service then — driven by a concrete requirement, not speculation.

## Upgrades

```bash
docker compose pull
docker compose up -d
```

Mattermost releases roughly monthly. The hourly postgres backup gives you
a free rollback point if an upgrade misbehaves — verify in
`s3://racecamp-db-backups/mattermost-alley/database-backups/hourly/`
before pulling.

## Secrets sync

`.env` contains every secret the stack needs. To avoid losing it (or
retyping it on a new machine), three scripts push/pull/diff it to S3:

```bash
./scripts/secrets-push.sh        # diff + audit log entry + upload
./scripts/secrets-pull.sh        # download latest to local .env
./scripts/secrets-diff.sh        # preview what push would do
```

Stored at `s3://racecamp-db-backups/mattermost-alley/secrets/.env` with
S3 versioning (full history) + a keys-only audit log. Old values are
recoverable via `aws s3api list-object-versions`. Full walkthrough in
SETUP.md → "Secrets sync".

## Backups

All automated by the compose stack — no host cron needed.

| What | Where | When | Retention |
|---|---|---|---|
| Postgres (hourly) | `s3://racecamp-db-backups/mattermost-alley/database-backups/hourly/` | every 60 min | 2 days |
| Postgres (daily) | `/srv/backups/mattermost-alley/daily/` on host | 01:30 | 30 days |
| Postgres (weekly) | `/srv/backups/mattermost-alley/weekly/` on host | Sun 02:30 | ~12 weeks |
| Uploaded files | `s3://racecamp-db-backups/mattermost-alley/files/` (restic, encrypted) | 03:30 | 7 daily / 4 weekly / 6 monthly |

Restore procedures and the quarterly drill checklist live in SETUP.md →
"Backups". The restic repo password is set during `setup-prod.sh`; **lose
it and the file backups become unrecoverable** — store it in a password
manager the moment it's generated.

## Troubleshooting

- **502 / connection refused at `https://$DOMAIN`** — the upstream nginx
  isn't reaching this host. Check from the nginx box:
  `curl -v http://<this-host>:8065/api/v4/system/ping`. If that fails,
  `:8065` either isn't listening or is firewalled. If it succeeds but the
  browser still 502s, the nginx `location` block is wrong — recheck
  SETUP.md → "Upstream nginx".
- **Login redirects to `http://...` and breaks** — upstream nginx isn't
  sending `X-Forwarded-Proto: https`. Mattermost defaults to constructing
  redirect URLs from the request scheme.
- **WebSocket disconnects / "Cannot connect to the server" banner** —
  nginx isn't upgrading the connection. Add the `Upgrade` / `Connection`
  headers to the `location` block.
- **Mattermost logs show Postgres connection errors** — `POSTGRES_PASSWORD`
  in `.env` must match what's baked into the `postgres-data` volume. If
  you changed the password after first boot, either set it back or
  `docker compose down -v` to wipe the volume (destroys all data — take a
  dump first).
- **`db-backup` / `restic-backup` crash-looping** — `docker compose logs
  db-backup` (or `restic-backup`). Most common cause: S3 credentials
  rejected. Test with `aws s3 ls s3://racecamp-db-backups/` using the
  same `S3_BACKUP_KEY_ID/SECRET` from `.env`.
- **First-run restic backup says "no such repository"** — the one-time
  init didn't happen. Re-run `./scripts/setup-prod.sh`; the init step is
  idempotent and will recover.
