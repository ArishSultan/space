# Space — Product Spec

Space runs local development services (databases, mail catcher, S3 storage, observability) on a Mac, without Docker. It is a macOS menu-bar app backed by a background daemon, with a CLI and an MCP server as equal-citizen interfaces. This document lists **what the product must do**, not how it looks.

Platform: macOS 26+, Apple silicon. Services run in Apple `container` VMs. Remote access uses an embedded Tailscale node (no Tailscale app installed).

---

## 1. Surfaces

| Surface | Purpose |
|---|---|
| **Menu-bar panel** | Quick glance + quick actions: service on/off, projects, hostnames, usage, other Macs. Opens from the menu-bar icon or a global hotkey. |
| **Service window** (one per service, several can be open) | Deep view of one service: overview/stats, logs, config, manage contents. |
| **Logs window** (one per service) | Standalone live log viewer. |
| **Settings window** | General, Apps, Storage, Network. |
| **Blocking dialogs** | Connected-clients warning, destructive-action confirmations, error banner. |

The daemon keeps services running when the app is closed. The app is a client of the daemon's API.

---

## 2. Domain concepts

- **Service (app):** a defined, containerised dev service. Built-in: PostgreSQL, MongoDB, Redis, Mailpit, S3 storage, Langfuse (a stack with hidden parts: Langfuse worker, ClickHouse). Always latest version, one instance each.
  - Attributes: id, name, logo/icon, accent colour, image, state, health, ports, connection strings, admin web URL, shared flag, hidden flag (stack parts are never listed on their own).
  - **States:** `not_created`, `stopped`, `running`, `stopping`, `unknown`. **Health:** healthy / unhealthy / unknown (only while running and only if the service defines a check).
- **Recipe:** YAML definition of a service (image, ports, volumes, env, resources, health check, connection templates, actions, managed resources, project .env templates, dependencies, stack parts, pre-start steps, pre-update backup). Built-ins ship with the app; users can override or add recipes in `~/.config/space/recipes/`.
- **Action:** a named operation a recipe exposes (run inside the container, in a throwaway container, or as an HTTP call), with optional parameters and an optional "hidden" flag. Examples: Mailpit *recent / search / clear*; Redis *keyspace / scan keys / flush all / info*.
- **Resource kind:** "things inside a service" that can be listed/created/deleted — Postgres/Mongo: **database + user, databases, users**; S3 storage: **buckets**. Each has singular/plural title, hint text, protected (undeletable) names, and a per-item connection string.
- **Project:** an app you are building: a name, **endpoints** (label + port + `*.localhost` hostname) and **resource links** (plain references to databases, buckets, Redis… used by it). It yields one `.env`.
- **Hostname:** `http://<name>.localhost → localhost:<port>`, created by project endpoints. **Service hostnames** are auto-created for built-in services with web UIs and are read-only.
- **Peer:** another Mac running Space on the same tailnet.
- **Share:** exposing one of this Mac's services to the user's other Macs.
- **Mount ("Use here"):** tunnelling a peer's shared service to this Mac's localhost, with connection strings rewritten to local ports.
- **Host selection:** which Mac the panel is controlling — this Mac, or a peer (remote control through the tailnet).

---

## 3. Functional requirements

### 3.1 Service lifecycle
1. List all visible services with state, health and running count ("N of M running").
2. Start / stop a service. Start pulls the image on first use, starts dependencies (`dependsOn`) and stack parts first, and runs pre-start steps (e.g. create the stack's database in Postgres).
3. Restart a running service.
4. **Update to latest image:** pull the newest image and recreate; data is kept; services with a defined backup (Postgres, MongoDB) are backed up first. Disabled when the service has never been created.
5. **Update all apps** in one action.
6. Per-service busy/in-flight indication; operations on one service must not block the UI for others.
7. **Connected-clients protection:** before stop, restart or update (from any surface) check for connected clients; if any, warn with the list of clients (e.g. "psql — shop@shop from 192.168.64.1", "2 connections from this Mac") and require explicit confirmation to force. The same dialog applies from the panel, service window and Settings.
8. Hide a service from the panel (Settings → Apps) without stopping it.
9. Open a service's admin web UI when it has one.
10. Copy any of a service's connection strings (keyed by label, e.g. `url`).
11. Share / unshare a service with other Macs (see 3.8).

### 3.2 Monitoring
1. Live stats per running service: CPU % (of one core), memory used / limit, network in/out, disk read/written, process count; sampled continuously with a rolling history.
2. Aggregate totals across running services (total CPU, total memory).
3. Usage history chart across all running services, switchable between memory and CPU; per-service current values listed beside it. Shown only when ≥1 service is running.
4. "Not running" state where live usage is unavailable.
5. Sampling only needs to run while a surface showing it is visible.

### 3.3 Logs
1. Per-service live log stream (stdout/stderr), also reachable via MCP/CLI (`logs -f`, tail N lines up to 5000).
2. Viewer capabilities: text filter, follow/auto-scroll toggle, pause/resume, copy.
3. Openable in its own window directly from the panel; also embedded in the service window.
4. Stack services include their parts' logs context as defined by the recipe.

### 3.4 Service configuration
1. View the effective definition: image, memory, CPUs, ports (host→container), volumes, env/connection info.
2. Edit the recipe YAML (creates/uses an override in `~/.config/space/recipes/`), show the override path, and **apply changes** (validates, reloads, recreates the service as needed).
3. Per-app **image override** (Settings → Apps): set a custom image, reset to default, with "overridden" indication; applies at next update.

### 3.5 Managing service contents (per-service "Manage")
Available only for services whose recipe defines resource kinds or visible actions.
1. For each resource kind: list items, create (name input; lowercase letters, digits, `-`, `_`), delete (with destructive confirmation: "its data is removed"), copy per-item connection string, mark built-in/protected items as non-deletable.
2. Show the service's hint text for each kind.
3. Generic actions: list visible actions with description and parameter inputs; run; show output; destructive/irreversible actions require confirmation ("This can't be undone").
4. Requires the service to be running; otherwise show a start prompt.
5. Quick access to "Manage …" from the panel's per-service menu.
6. Specialised capabilities: Mailpit (recent, search with Mailpit syntax, view a message, clear all); Redis (keyspace, scan keys by pattern, info, flush all).

### 3.6 Projects
A project is one app you're building. It has **endpoints** and **resource links**; it never owns data.
1. List projects with: name, endpoints (label, hostname, port, whether something is listening), linked resources.
2. **Create project** from just a name (3–42 lowercase letters, digits, hyphens). Endpoints and links can be given at creation or added later.
3. **Endpoint** = label (e.g. `api`, `portal`) + the port the app listens on + a hostname. Hostname defaults to `<label>.<project>.localhost` and can be overridden; it must be unique across projects and not clash with built-in service hostnames. Ports 80 and 443 are not allowed. The first endpoint maps to `PORT`/`APP_URL` in the `.env`, others to `<LABEL>_PORT`/`<LABEL>_URL`.
4. Add / remove endpoints at any time. Opening an endpoint launches its URL; a status dot shows whether the port is listening. A project's dot is green when any endpoint is up.
5. **Resource link** = reference `(service, kind, name)` to a database, database + user, bucket, etc., or `(service)` for Redis, Mailpit and Langfuse. Several links to the same service are allowed (several databases, several buckets).
6. Adding a link may **create** the resource first; its service is started automatically when it isn't running. Links to items that don't exist are rejected unless creating. A link whose target is later deleted is flagged **missing** on single-project reads.
7. Removing a link, or deleting a project, never deletes the linked resource. Deleting a resource leaves a dangling link.
8. The service's Manage tab shows which projects use each item.
9. **Copy .env:** endpoint variables plus each link's settings. If two links would produce the same variable (two databases → `DATABASE_URL`), later ones are prefixed with their resource name (`ANALYTICS_DATABASE_URL`).
10. **Delete project** removes the project and its hostnames only (confirmation).
11. Empty state explains what a project is. Local-only: not available while controlling a remote Mac.

### 3.7 Hostnames
1. Hostnames exist only as project endpoints (`http://<hostname>.localhost → localhost:<port>`) plus automatic read-only hostnames for built-in service UIs (e.g. `mailpit.localhost`). There is no standalone "add hostname".
2. A built-in router listens on port 80 and routes by Host header (WebSockets and keep-alive work); show router status and its error if it cannot start (e.g. port 80 in use). No DNS, certificates or passwords needed; only this Mac can use it.
3. Unknown hostnames get a helpful 404 page listing configured ones; a hostname with nothing listening gets a "nothing running" page.

### 3.8 Other Macs (Tailscale)
1. **Sign in** to Tailscale once, from inside Space (browser-based login); show "waiting for browser" state; **log out**. Show this Mac's tailnet name/device name, tailnet, number of Space devices.
2. List peers with online/offline and what each shares ("nothing shared" when empty).
3. **Share / unshare** a local service (per-service toggle). Only devices on the user's Tailscale account can connect.
4. **Use here** (mount) a peer's shared service on this Mac's localhost: show the resulting local ports, copy connection string, toggle off to unmount; show "Available" / "Stopped on that Mac" status.
5. **Remote control:** switch the panel's host to a peer to start/stop/inspect that Mac's services; return to "This Mac". Host picker only appears when at least one peer is online or a remote is selected.
6. Peer section only appears when signed in and peers exist.

### 3.9 Maintenance & storage
1. **Disk usage:** images (size, unused/reclaimable), containers (size, reclaimable), per-service data volumes (bytes actually used).
2. **Reclaim space:** remove stopped app containers and unused app images (data kept); report freed bytes and number of items removed.
3. **Also delete data of stopped apps** — destructive, separate confirmation ("databases, buckets and messages of every app that isn't running are permanently deleted").
4. Busy indication for long-running maintenance; disable conflicting actions meanwhile.

### 3.10 General settings
1. Open Space at login (toggle).
2. Global hotkey to toggle the panel (record / clear; requires ⌘/⌥/⌃ modifier; Esc cancels).
3. Background service status (running / not running) and data/definitions location with "show in Finder".
4. **Agent (MCP) setup:** copyable `claude mcp add …` command for stdio and the HTTP endpoint (`http://127.0.0.1:7777/mcp`).

### 3.11 Daemon & resilience
1. App installs `spaced` as a per-user LaunchAgent on first run and reloads it after rebuilds.
2. If the daemon is down: show an explicit offline state with a "Start service" action; hide data sections.
3. Errors from any operation surface in a dismissible error banner (copyable text).
4. Periodic refresh while any surface is visible; refresh on open.
5. Quit via ⌘Q / ⌃Q.

---

## 4. Per-service content rules (what each built-in needs)

| Service | Ports | Admin UI | Manage | Notes |
|---|---|---|---|---|
| PostgreSQL | 5432 | — | database + user, databases, users | Default `space:space`; auto-upgrades data dir; backup before update; client list |
| MongoDB | 27017 | — | database + user, databases, users | Backup before update; client list |
| Redis | 6379 | — | actions: keyspace, scan keys, info, flush all | Client list |
| Mailpit | SMTP 1025, UI | `mailpit.localhost` | actions: recent, search, clear | Captures all outgoing dev mail |
| S3 Storage (Versity S3 Gateway) | 9000 | — (no console) | buckets | Key/secret `spaceadmin`; env-only config; one folder per bucket |
| Langfuse | — | `langfuse.localhost` | — | Stack: web + worker + ClickHouse, depends on Postgres, Redis, S3 Storage; preset login & API keys |

---

## 5. Agent & CLI interfaces (feature parity)

**CLI (`spaced`)**: status, start/stop, logs (-f), stats, action, project create/add-endpoint/link/unlink/env, hosts status, net login/share/mount, system disk/reclaim/update-all, mcp.

**MCP server (stdio + HTTP)** — 39 tools in these groups:
- Services: list, start, stop, restart, update, get connection info, list clients, stats, logs, watch logs
- Contents: list/run actions, list/create/delete resources
- Mail: recent, search, get, clear
- Projects: list, get, create (with endpoints and resource links), add/remove endpoint, add/remove resource link (optionally creating the resource), get env, delete
- Hostnames: list (read-only)
- Tailnet: status, list peers, list peer services, share, unshare, use remote service, stop using remote service
- Maintenance: disk usage, reclaim space, update all
- MCP resources: last 500 log lines per service

Anything the UI does must remain possible via the API (single source of truth); the UI adds no capability the daemon lacks.

---

## 6. Non-functional requirements
- Native SwiftUI only for UI; third-party packages only for non-UI plumbing.
- Local dev credentials are intentionally simple and documented; no secrets management.
- Remote access limited to the user's own tailnet; hostname routing limited to this Mac.
- Destructive operations always confirmed; data preserved by default on stop/update/reclaim.
- State persisted: hidden-in-panel set, image overrides, projects (endpoints + resource links), mounts, shares, global hotkey, login item.

---

## 7. Screen inventory (content only, for design handoff)

1. **Panel** — header (title, running count or host picker, tailnet/sign-in access, settings access); service list; projects (with endpoints); usage; other Macs; offline card; error banner.
2. **Service window** — header (identity, state/health, actions: open web UI, restart, update, start/stop); tabs: Overview, Logs, Config, Manage (tabs shown conditionally).
3. **Logs window** — filter, follow, pause, copy, stream.
4. **New project flow** — name only. **New endpoint flow** — label, port, optional hostname, with a live URL preview.
5. (no standalone hostname flow)
6. **Settings → General / Apps / Storage / Network.**
7. **Dialogs** — connected-clients warning, delete project, delete resource, run destructive action, delete stopped-app data.
8. **States** — empty (no projects/resources), loading, busy, offline daemon, error, remote-controlling, not signed in to tailnet.
