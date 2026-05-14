# upload-policy

Server-side upload pipeline for this Mattermost deployment. Lives inside
`mattermost-alley` because it is specific to this deployment's policy — every
commit of `mattermost-alley` pins the exact plugin source it was built with.

Runs as a Mattermost server plugin via the `FileWillBeUploaded` hook, so it
applies uniformly to every client: web, iOS, Android, desktop.

## What it does

| Input | Outcome |
|-------|---------|
| Video (`video/*` or `.mp4` `.mov` `.mkv` `.webm` `.avi` `.wmv` `.flv` `.m4v` `.mpg` `.mpeg` `.3gp` `.ogv` `.ts`) | **Rejected** with the configured reject message. |
| PDF (`application/pdf` or `.pdf`) | **Rejected.** |
| JPEG, longest edge ≤ MaxDimension | passthrough |
| JPEG, longest edge > MaxDimension | resize, re-encode JPEG @ JpegQuality |
| PNG, longest edge ≤ MaxDimension | passthrough (transparency preserved) |
| PNG, longest edge > MaxDimension | flatten on white, resize, encode JPEG |
| GIF, longest edge ≤ MaxDimension | passthrough (animation preserved) |
| GIF, longest edge > MaxDimension | first frame, resize, encode JPEG |
| Anything else (audio, archives, docs, etc.) | passthrough |

## Settings

| Key | Default | Notes |
|-----|---------|-------|
| `Enabled` | `true` | Master switch. |
| `MaxDimension` | `1280` | Pixels, long edge. |
| `JpegQuality` | `80` | 1–100. |
| `RejectVideosAndPDFs` | `true` | Master switch for the reject list. |
| `RejectMessage` | (long) | Shown to the uploader on reject. |

Runtime-tunable in **System Console → Plugins → Upload Policy** without
rebuilding the image.

## How it gets into the running server

`Dockerfile.branded` has a `plugin-builder` stage that compiles this
directory and bakes the resulting tarball into the final image at
`/mattermost/baked-plugins/upload-policy.tar.gz`. So every alley image
build embeds exactly one known plugin version — `git checkout`-ing an
older alley commit and rebuilding gives you the older plugin.

We don't use Mattermost's `prepackaged_plugins/` directory because the
server hardcodes a GPG signature requirement for that path. Setting up
trusted-key signing just to ship our own in-repo plugin is overkill, so
instead we install it via mmctl after the container is healthy:

```sh
./scripts/install-upload-policy.sh
```

Run that once after `docker compose build && docker compose up -d`. It
is idempotent — safe to re-run, and `--force` upgrades an installed
older version. After the first install the plugin's enabled state
persists in the config DB and the plugin binary persists in the
`mattermost-plugins` volume, so `docker compose up -d` alone (without a
rebuild) needs nothing.
