# Space

Local development services on your Mac, without Docker. Space runs Postgres, MongoDB, Redis, Mailpit,
RustFS (S3) and Langfuse in Apple's lightweight `container` VMs. You control everything from a SwiftUI
menu-bar app, from a CLI (`spaced`), or through an MCP server for coding agents.

- **Services:** turn them on and off, watch CPU and memory, stream logs, and edit their config.
  Stopping, restarting or updating warns you when clients are connected.
- **Manage:** create projects, databases, users and buckets, and copy their connection strings.
  Mailpit (search and clear mail) and Redis (keys, flush) have action buttons.
- **Projects:** one click creates ports, `http://<name>.localhost` hostnames, and a database or bucket
  in each service you choose. **Copy .env** gives you every connection string at once.
- **Hostnames:** `http://<name>.localhost` maps to any local port. Browsers resolve `*.localhost`
  on their own, so there's no DNS, certificate or password setup. Only this Mac can use them.
- **Other Macs:** sign in to Tailscale once, inside Space; no Tailscale app needed. You can then share
  services, use another Mac's services on `localhost`, or switch the panel to control another Mac.
  Only devices signed in with your Tailscale account can connect.
- **Agents:** the MCP server exposes 36 tools: services, logs, databases, buckets, projects, mail,
  hostnames and sharing.
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

## Use it from agents (MCP)

```sh
claude mcp add space -- /path/to/Space.app/Contents/MacOS/spaced mcp      # stdio
claude mcp add --transport http space http://127.0.0.1:7777/mcp           # HTTP
```

## CLI

```sh
spaced status | start <svc> | stop <svc> | logs <svc> -f | stats
spaced action postgres create_project name=shop
spaced project create shop --services postgres,rustfs,mailpit --ports web,api
spaced project env shop > .env
spaced hosts add docs 4000              # http://docs.localhost → localhost:4000
spaced net login | share postgres | mount <peer> postgres
spaced system disk | reclaim | update-all
```

## Default credentials (local development only)

| Service | Connection |
|---|---|
| Postgres | `postgres://space:space@localhost:5432/postgres`. Projects use `<name>:<name>`. |
| MongoDB | `mongodb://space:space@localhost:27017/?authSource=admin` |
| Redis | `redis://localhost:6379` |
| Mailpit | SMTP `localhost:1025`, UI at http://mailpit.localhost |
| RustFS | `http://localhost:9000`, access key and secret `spaceadmin`, console at http://rustfs.localhost/rustfs/console/ |
| Langfuse | http://langfuse.localhost (`dev@space.test` / `spacespace`), keys `pk-lf-space` / `sk-lf-space` |

Containers reach shared services at `192.168.64.1:<port>`. `spaced` relays that address to localhost.

## Adding a service

Each service is a YAML recipe in `Sources/SpaceCore/Recipes/`. To override a built-in recipe or add
your own, put a file in `~/.config/space/recipes/` (Config tab → **Edit…**). A recipe declares:

- image, ports, volumes, env and health check
- actions, which run inside the container, in a throwaway container, or as HTTP calls
- resources
- project `.env` templates
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
