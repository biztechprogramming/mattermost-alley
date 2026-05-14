#!/bin/sh
# Install or upgrade the upload-policy plugin from the baked-in tarball.
#
# The tarball is built into the image by Dockerfile.branded at
# /mattermost/baked-plugins/upload-policy.tar.gz. This script tells the
# running Mattermost instance to install it (or upgrade, if a previous
# version is already installed) and enables it.
#
# Idempotent. Safe to run after every `docker compose build && docker
# compose up -d`. Plugin state (installed + enabled) persists in the
# mattermost-plugins volume and the config DB.

set -eu

CONTAINER="${MM_CONTAINER:-mattermost-alley-mattermost-1}"
TARBALL="${MM_PLUGIN_TARBALL:-/mattermost/baked-plugins/upload-policy.tar.gz}"
PLUGIN_ID="${MM_PLUGIN_ID:-com.biztechprogramming.upload-policy}"

echo "Installing/upgrading $PLUGIN_ID from $TARBALL inside $CONTAINER..."
docker exec "$CONTAINER" mmctl --local plugin add --force "$TARBALL"

echo "Enabling $PLUGIN_ID..."
docker exec "$CONTAINER" mmctl --local plugin enable "$PLUGIN_ID"

echo
echo "Done. Plugin status:"
docker exec "$CONTAINER" mmctl --local plugin list | grep -E "($PLUGIN_ID|There are)" || true
