# Mattermost Relay

Self-hosted group chat for ~30 people, replacing the Twilio SMS relay.
Mattermost handles everything — channels, message delivery, mute, roster,
file uploads — so this repo is just the thin deployment layer around it.

## Stack

```
Internet ──► Caddy (TLS, 443) ──► Mattermost ──► Postgres
```

One network, Caddy is the only public face, everything else lives on an
internal Docker network.

## Layout

```
.
├── docker-compose.yml         # Postgres + Mattermost + Caddy (production)
├── docker-compose.local.yml   # Postgres + Mattermost only, on localhost:8065
├── Dockerfile.branded         # Rebrands the Mattermost image at build time
├── Caddyfile                  # TLS + reverse proxy for Mattermost
├── branding/                  # Drop-in favicon + icon PNG overrides
├── .env.example               # Copy to .env and fill in
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
- A domain (e.g. `chat.example.com`) whose A record points at the box.
  DNS must resolve before first boot — Caddy tries to fetch a Let's Encrypt
  cert on startup and fails noisily otherwise.
- Ports `80` and `443` reachable from the public internet (port 80 is
  required for the Let's Encrypt HTTP-01 challenge).

## Quick start

```bash
cp .env.example .env
# edit DOMAIN, ACME_EMAIL, POSTGRES_PASSWORD
docker compose up -d
```

Wait ~30s, then open `https://${DOMAIN}`. Create the first account (it's
auto-promoted to sysadmin), create a team, invite your people.

Full walkthrough: **SETUP.md**. To rehearse locally with no TLS / no
domain: **LOCAL_DEV.md**.

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

Mattermost releases roughly monthly. Take a Postgres dump first — see
SETUP.md for the command.

## Backups

The two volumes that matter:

| Volume | Contents |
|---|---|
| `postgres-data` | All messages, channels, users, ACLs |
| `mattermost-data` | Uploaded files (images, attachments) |

Nightly `pg_dump` + off-box copy is the baseline. Attachments are just a
directory — tar them weekly.

## Troubleshooting

- **Caddy logs say `obtaining certificate`, page is `ERR_CONNECTION_REFUSED`**:
  DNS isn't pointing at the box yet, or port 80 isn't reachable from the
  outside. Check `dig ${DOMAIN}` and try `curl http://${DOMAIN}` from a
  different network (mobile hotspot works).
- **Mattermost logs show Postgres connection errors**:
  `POSTGRES_PASSWORD` in `.env` must match what's baked into the
  `postgres-data` volume. If you changed the password after first boot,
  either set it back or `docker compose down -v` to wipe the volume (destroys
  all data — take a dump first).
