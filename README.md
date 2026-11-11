# Space

Local development services on your Mac, without Docker. Space runs Postgres, MongoDB, Redis, Mailpit,
S3 storage and Langfuse in Apple's lightweight `container` VMs. You control everything from a SwiftUI
menu-bar app, from a CLI (`spaced`), or through an MCP server for coding agents.

- **Services:** turn them on and off, watch CPU and memory, stream logs, and edit their config.
  Stopping, restarting or updating warns you when clients are connected.
- **Manage:** create databases, users and buckets, and copy their connection strings.
  Mailpit (search and clear mail) and Redis (keys, flush) have action buttons.
- **Projects:** a project is an app you're building. Give each part of it (an `api`, a `portal`) a port and a
  hostname, and link the databases, buckets or Redis it uses. Links are plain references: they feed one
  **Copy .env** and let agents see what an app uses, but deleting a project never deletes data.
- **Hostnames:** each project endpoint gets `http://<name>.localhost` (default `<endpoint>.<project>.localhost`).
  Browsers resolve `*.localhost` on their own, so there's no DNS, certificate or password setup. Only this
  Mac can use them.
- **Other Macs:** sign in to Tailscale once, inside Space; no Tailscale app needed. You can then share
  services, use another Mac's services on `localhost`, or switch the panel to control another Mac.
  Only devices signed in with your Tailscale account can connect.
- **Agents:** the MCP server exposes 39 tools: services, logs, databases, buckets, projects (endpoints and resource
  links), mail, hostnames and sharing.
- **Maintenance:** set the image for each app, update all apps, see disk usage, and reclaim space.

## Requirements

- macOS 26 or later on Apple silicon
- Apple `container` 1.x: `brew install container`, then `container system start`
- To build Space: Xcode 26 or later, and Go (`brew install go`) for the one-time TailscaleKit build

## Build and run

```sh
scripts/build-tailscalekit.sh   # once: builds Tailscale's official TailscaleKit into Vendor/
scripts/bundle-app.sh           # builds build/Space.app (app + spaced + TailscaleKit)
open build/Space.app
```

When the app starts, it installs `spaced` as a per-user LaunchAgent
(`~/Library/LaunchAgents/dev.space.spaced.plist`). Services keep running when the app is closed.
After a rebuild, open the app again and it reloads the background service.

## Install and update

Download `Space-<version>.zip` from the latest [release](../../releases/latest), unzip it, and drag **Space.app** into
`/Applications`. Updates then arrive by themselves: Space checks every few hours, installs new versions in the
background and starts them the next time it opens (Settings → General → Updates has the switches and a manual
**Check for Updates…**). Your services keep running while it updates.

Until the app is notarized (see below) macOS blocks the first launch of a downloaded copy. Right-click the app,
choose **Open**, or run `xattr -dr com.apple.quarantine /Applications/Space.app` once. Updates that Space installs
itself don't have this problem.

## Releasing

Releases are built by GitHub Actions (`.github/workflows/release.yml`) on a macOS runner. Pushing a tag does it all:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

The workflow tests, builds `Space.app`, signs it, zips it, signs the update with Space's EdDSA key and publishes a
GitHub release with `Space-0.2.0.zip` and `appcast.xml`. Installed copies read
`releases/latest/download/appcast.xml`, so the newest release is always what they update to.
`.github/workflows/ci.yml` builds and tests every push and pull request.

**One-time setup**

1. Export the update-signing key and store it as a repository secret (the matching public key is already in
   `scripts/bundle-app.sh`):

   ```sh
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account space-app -x /tmp/space-sparkle.key
   gh secret set SPARKLE_PRIVATE_KEY < /tmp/space-sparkle.key && rm /tmp/space-sparkle.key
   ```

   Keep a backup of that key somewhere safe. If it's lost, installed copies can't verify new updates, and everyone
   has to reinstall by hand.

2. *(Optional, recommended)* **Developer ID signing and notarization**, so the app opens without a Gatekeeper
   warning. It needs a paid Apple Developer account. Add these secrets and the workflow uses them automatically:
   `DEVELOPER_ID_P12_BASE64` (base64 of the exported *Developer ID Application* certificate), `DEVELOPER_ID_P12_PASSWORD`,
   `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID` and `NOTARY_PASSWORD` (an app-specific password). Without them the app is
   ad-hoc signed, which still updates correctly but needs the first-launch step above.

**Version numbers:** the tag is the marketing version. The build number Sparkle compares is
`major*10000 + minor*100 + patch` (v1.2.3 → 10203), so it always grows with the tag.

**Local builds** (`scripts/bundle-app.sh`) have updates turned off. To test packaging, set `VERSION`, `BUILD` and
`FEED_URL`, then run `scripts/package-release.sh`.

## Use it from agents (MCP)

```sh
claude mcp add space -- /path/to/Space.app/Contents/MacOS/spaced mcp      # stdio
claude mcp add --transport http space http://127.0.0.1:7777/mcp           # HTTP
```

## CLI

```sh
spaced status | start <svc> | stop <svc> | logs <svc> -f | stats
spaced action postgres create_db name=shop
spaced project create shop --endpoint api:3100 --endpoint portal:3101 \
    --uses postgres/databases/shop+ --uses redis       # a trailing + creates it first
spaced project add-endpoint shop admin:3102            # http://admin.shop.localhost → localhost:3102
spaced project env shop > .env
spaced net login | share postgres | mount <peer> postgres
spaced system disk | reclaim | update-all
```

## Default credentials (local development only)

| Service | Connection |
|---|---|
| Postgres | `postgres://space:space@localhost:5432/postgres`. A "database + user" pair uses `<name>:<name>`. |
| MongoDB | `mongodb://space:space@localhost:27017/?authSource=admin` |
| Redis | `redis://localhost:6379` |
| Mailpit | SMTP `localhost:1025`, UI at http://mailpit.localhost |
| S3 Storage | `http://localhost:9000`, access key and secret `spaceadmin`, region `us-east-1`, path-style. No web console: manage buckets in Space. |
| Langfuse | http://langfuse.localhost (`dev@space.test` / `spacespace`), keys `pk-lf-space` / `sk-lf-space` |

Containers reach shared services at `192.168.64.1:<port>`. `spaced` relays that address to localhost.

## Adding a service

Each service is a YAML recipe in `Sources/SpaceCore/Recipes/`. To override a built-in recipe or add
your own, put a file in `~/.config/space/recipes/` (Config tab → **Edit…**). A recipe declares:

- image, ports, volumes, env and health check
- actions, which run inside the container, in a throwaway container, or as HTTP calls
- resources
- the `.env` variables a project gets when it links this service or one of its resource kinds
- `dependsOn` and `parts` for multi-container stacks like Langfuse

## Layout

| Path | What it is |
|---|---|
| `Sources/SpaceCore` | Recipes, the `container` CLI wrapper, service manager, API models and API client |
| `Sources/SpaceNet` | Tailscale (TailscaleKit), sharing and tunnels, `*.localhost` router, gateway relay, projects |
| `Sources/SpaceServer` | Hummingbird HTTP API and the MCP HTTP endpoint |
| `Sources/SpaceMCP` | MCP tools |
| `Sources/spaced` | Daemon and CLI |
| `Sources/SpaceApp` | SwiftUI menu-bar app |
