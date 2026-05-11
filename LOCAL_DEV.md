# Local Development

Run Postgres + Mattermost on your workstation — no domain, no TLS, no
public reverse proxy. Useful for rehearsing the admin-setup flow before
deploying, or poking at Mattermost's System Console in a throwaway
environment. The dev stack runs on `:8066` so it can coexist with a prod
stack on `:8065` on the same host.

## Prerequisites

- Docker + Docker Compose v2.
- `curl` and `jq` on your PATH (the bootstrap script uses both).
- A free port 8066.

## Fast path — one script does everything (~1 min)

```bash
cd mattermost-relay
./scripts/setup-local.sh
```

Boots Postgres + Mattermost, creates the admin account (`admin` /
`LocalAdmin!234` by default), creates a team, adds the admin to it, and
prints the login URL. Re-runnable — it detects an existing admin/team and
skips creation. Override defaults with env vars:

```bash
ADMIN_PASSWORD='stronger' TEAM_NAME=testing ./scripts/setup-local.sh
```

Wipe volumes and start over:

```bash
./scripts/setup-local.sh --reset
```

## Manual boot (if the script doesn't fit your needs)

```bash
docker compose -f docker-compose.local.yml up -d
docker compose -f docker-compose.local.yml logs -f mattermost
```

Wait ~30 seconds for `Server is listening on :8065` (the container's
internal port — published on the host as `:8066`), then Ctrl-C the tail
and visit `http://localhost:8066`. Create an admin account (the first user
registered is auto-promoted to sysadmin), create a team, invite or add a
second test account in an incognito window.

## How this differs from production

- No TLS — Mattermost is exposed directly on `:8066` (all interfaces, so
  phones on the same wifi can connect when `LAN_IP` is set in `.env`).
  Prod terminates TLS at an upstream nginx and forwards to `:8065`.
- Postgres password is hardcoded (`local-dev-password`) — the container
  is only reachable on the internal Docker network.
- No `db-backup` / `restic-backup` services — dev data is disposable.
- Volumes are prefixed `*-local-*`, so prod and dev coexist on one host
  without colliding.

## Stop / reset

```bash
docker compose -f docker-compose.local.yml down       # stop, keep data
docker compose -f docker-compose.local.yml down -v    # wipe volumes
```

## Moving to production

Nothing local carries over — different volumes, different password,
different site URL, fresh admin account. When ready, run
`./scripts/setup-prod.sh` (see `SETUP.md`). If you want to carry message
history over:

```bash
# locally
docker compose -f docker-compose.local.yml exec -T postgres \
  pg_dump -U mattermost mattermost | gzip > local-dump.sql.gz

# on the server (after Phase 3, before creating the admin account)
gunzip -c local-dump.sql.gz | \
  docker compose exec -T postgres psql -U mattermost mattermost
```

For fresh-start deployments, skip the dump — it's usually cleaner to not
bring test data into prod.
