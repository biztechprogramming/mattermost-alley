# Branding assets

Drop-in replacements for Mattermost's default brand assets. Anything in this
directory gets baked into the container at build time by `Dockerfile.branded`
(the `COPY branding/ ...` step). **Missing files are silently skipped** — you
only need to provide the ones you want to override.

The string rename (`Mattermost` → whatever `SITE_NAME` is set to in `.env`)
happens separately inside the Dockerfile and doesn't need any files here.

## Files that get overlaid (all optional)

| File | Where it ends up | Notes |
|---|---|---|
| `favicon.ico` | `/mattermost/client/favicon.ico` | Browser tab icon. `.ico` with 16/32/48 px frames is safest. |
| `favicon-16x16.png` | same dir | Modern browser fallback. |
| `favicon-32x32.png` | same dir | Modern browser fallback. |
| `icon_96x96.png` | same dir | PWA / web app manifest. Mattermost ships a set of these (see below). |
| `icon_76x76.png` | same dir | iOS home-screen (iPad). |
| `icon_72x72.png` | same dir | Android home-screen. |
| `icon_60x60.png` | same dir | iOS home-screen (small). |
| `icon_57x57.png` | same dir | iOS legacy. |
| `icon_40x40.png` | same dir | iOS Spotlight. |
| `apple-touch-icon-120x120.png` | same dir | iPhone home-screen. |
| `apple-touch-icon-152x152.png` | same dir | iPad home-screen. |

## Recommended minimum

- `favicon.ico` (browser tab)
- `icon_96x96.png` (everywhere else — Mattermost uses this as a generic app
  icon in many places)

Everything else is nice-to-have.

## Extracting the defaults as a starting point

If you want to see what Mattermost ships by default before replacing it:

```bash
docker run --rm mattermost/mattermost-team-edition:latest \
  tar -C /mattermost/client -cf - favicon.ico icon_96x96.png \
  | tar -xf - -C branding/
```

Edit those in your image editor of choice and commit.

## In-app branding (logo / background on the login page)

`Dockerfile.branded` handles **static** assets only. Mattermost also supports
an **admin-uploaded custom brand image** (shown on the login page next to
your site description) via System Console → Site Configuration → Customization.
That's the easiest path for the login-page visuals — upload once, stored in
the `mattermost-data` volume.
