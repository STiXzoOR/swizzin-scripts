# Autopulse Installer Design

## Overview

Swizzin installer script for [Autopulse](https://github.com/dan-online/autopulse) - a lightweight Rust service that receives Sonarr/Radarr webhooks and sends targeted library update notifications to Emby/Jellyfin/Plex. Replaces slow full-library scans with path-specific API calls.

## Problem

Emby's built-in library monitor has a 90-second delay (plus 45s hardcoded) and inotify doesn't work with FUSE/rclone mounts. Sonarr/Radarr's built-in Emby Connect triggers `POST /Library/Refresh` (full library scan). On large libraries this takes minutes. Autopulse calls `/Library/Media/Updated` with the specific file path instead.

## App Configuration

| Field | Value |
|---|---|
| app_name | autopulse |
| app_pretty | Autopulse |
| app_dir | /opt/autopulse |
| API image | ghcr.io/dan-online/autopulse:latest |
| UI image | ghcr.io/dan-online/autopulse:ui-dynamic |
| Ports | 2 dynamic (API + UI), range 10000-12000, persisted to swizdb |
| Nginx | /etc/nginx/apps/autopulse.conf (subfolder /autopulse) |
| Systemd | autopulse.service (oneshot docker compose wrapper) |
| Lock | /install/.autopulse.lock |

## Deployment Model

Single Docker Compose file with two containers (API + UI). One systemd oneshot service wraps docker compose up/down. Matches the MediaFusion multi-container pattern.

## Auto-Discovery

### Arr Instances

Scans Swizzin lock files to discover all arr instances:

- `/install/.sonarr.lock`, `/install/.sonarr_*.lock`
- `/install/.radarr.lock`, `/install/.radarr_*.lock`
- `/install/.lidarr.lock`, `/install/.lidarr_*.lock`
- `/install/.readarr.lock`, `/install/.readarr_*.lock`

For each discovered instance, reads `config.xml` from `/home/*/.config/<AppName>/config.xml` to extract:
- Port (`<Port>`)
- API key (`<ApiKey>`)
- URL base (`<UrlBase>`)

Instance naming convention:
- Base instance: `sonarr`, `radarr`, etc.
- Multi-instance: `sonarr-4k`, `sonarr-anime`, `radarr-4k`, etc. (derived from lock file name)

### Media Servers

Scans for installed media servers:

**Emby** (`/install/.emby.lock`):
- API key: read from `/var/lib/emby/config/system.xml` or create one via `POST /emby/Users/<admin_id>/Authenticate` then generate an API key via `POST /emby/Auth/Keys`
- Port: from systemd unit or default 8096
- If no API key found, create one named "Autopulse" via the Emby API

**Jellyfin** (`/install/.jellyfin.lock`):
- API key: read from Jellyfin network config XML or create one via `POST /Auth/Keys` with name "Autopulse"
- Port: from systemd unit or default 8096
- If no API key found, create one named "Autopulse" via the Jellyfin API

**Plex** (`/install/.plex.lock`):
- Token: read from `Preferences.xml` (`PlexOnlineToken`)
- Port: default 32400
- Plex tokens are per-account, not creatable via API; if not found, prompt user

Each discovered media server becomes an Autopulse target entry. If no media servers found, prompts user for manual configuration.

## Config Generation

### Autopulse Config (`/opt/autopulse/config.yaml`)

```yaml
app:
  hostname: 0.0.0.0
  port: <api_port>
  log_level: info

auth:
  username: <master_user>
  password: <generated_password>

triggers:
  sonarr:
    type: sonarr
  sonarr-4k:
    type: sonarr
  sonarr-anime:
    type: sonarr
  radarr:
    type: radarr
  radarr-4k:
    type: radarr

targets:
  emby:
    type: emby
    url: http://127.0.0.1:<emby_port>
    token: <emby_api_key>
```

- Triggers named to match arr instance names
- Each trigger gets webhook URL: `http://localhost:<api_port>/triggers/<name>`
- Auth credentials persisted to swizdb for idempotent re-runs
- Config file chmod 600, owned by root
- database_url set via env var in compose (not in config.yaml) for cleaner separation

### Docker Compose (`/opt/autopulse/docker-compose.yml`)

```yaml
services:
  autopulse:
    image: ghcr.io/dan-online/autopulse:latest
    container_name: autopulse
    restart: unless-stopped
    network_mode: host
    user: "<uid>:<gid>"
    environment:
      AUTOPULSE__APP__DATABASE_URL: sqlite://data/autopulse.db
    volumes:
      - /opt/autopulse/config.yaml:/app/config.yaml:ro
      - /opt/autopulse/data:/app/data
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL

  autopulse-ui:
    image: ghcr.io/dan-online/autopulse:ui-dynamic
    container_name: autopulse-ui
    restart: unless-stopped
    network_mode: host
    environment:
      BASE_PATH: /autopulse
      ORIGIN: http://localhost:<ui_port>
      PORT: "<ui_port>"
      FORCE_AUTH: "true"
      FORCE_SERVER_URL: http://localhost:<api_port>
      FORCE_USERNAME: <master_user>
      FORCE_PASSWORD: <generated_password>
      SECRET: <generated_secret>
    depends_on:
      - autopulse
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
```

- Host networking (avoids UFW/Docker firewall conflicts)
- Config mounted at `/app/config.yaml` (Autopulse default working dir)
- SQLite DB stored in `/app/data/` via volume mount
- Security hardened: no-new-privileges, cap_drop ALL
- UI uses `ui-dynamic` tag for runtime BASE_PATH support
- UI auto-authenticates to backend via FORCE_AUTH (no manual login needed)
- SECRET set to a generated value so auth cookie survives container restarts

## Nginx Configuration

```nginx
location /autopulse {
    return 301 /autopulse/;
}

location ^~ /autopulse/ {
    proxy_pass http://127.0.0.1:<ui_port>/autopulse/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $http_connection;

    auth_basic "What's the password?";
    auth_basic_user_file /etc/htpasswd.d/htpasswd.<user>;
}

location ^~ /autopulse/triggers/ {
    auth_request off;
    proxy_pass http://127.0.0.1:<api_port>/triggers/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

- UI behind basic auth
- Trigger API endpoints bypass basic auth (Autopulse has its own auth, Sonarr/Radarr need unauthenticated webhook POST access)
- No sub_filter needed - API is pure JSON, UI has native BASE_PATH support

## Arr Webhook Auto-Configuration

For each discovered arr instance, the installer:

1. **Checks for existing Autopulse webhook** via `GET /api/v3/notification` - skips if already configured (matched by name "Autopulse")
2. **Adds a Webhook notification** via `POST /api/v3/notification`:
   - Name: `Autopulse`
   - Implementation: `Webhook`
   - URL: `http://localhost:<api_port>/triggers/<instance_name>`
   - Method: POST
   - Events: On Import, On Upgrade, On Rename, On Delete
3. **Optionally disables existing Emby/Jellyfin/Plex Connect entries** that trigger full library scans - prompts user before modifying

Webhook configuration uses `curl --config <(printf ...)` for secure credential passing (not visible in `ps aux`).

## Update Flow

`bash autopulse.sh --update`:
1. Pull latest images (API + UI)
2. Recreate containers via docker compose
3. Prune dangling images
4. Re-run auto-discovery and update config if new arr instances or media servers found

## Remove Flow

`bash autopulse.sh --remove [--force]`:
1. Stop and remove containers
2. Remove Docker images
3. Remove systemd service
4. Remove nginx config
5. Remove Autopulse webhook from all discovered arr instances
6. Remove panel registration
7. Prompt for purge (remove /opt/autopulse and swizdb entries) or keep config

## Systemd Service

```ini
[Unit]
Description=Autopulse (Media Server Library Notifier)
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
Restart=on-failure
RestartSec=10
WorkingDirectory=/opt/autopulse
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
```

## Panel Registration

Standard Swizzin panel registration:
- Name: autopulse
- Pretty name: Autopulse
- Base URL: /autopulse
- Systemd: autopulse
- Icon: downloaded from CDN or bundled

## Script Structure

Follows the standard Docker app installer template:
1. Source globals + utils + nginx-utils
2. App configuration variables
3. Cleanup trap for rollback
4. `_install_docker()` - idempotent Docker installation
5. `_discover_arrs()` - find all arr instances
6. `_discover_media_servers()` - find Emby/Jellyfin/Plex
7. `_generate_config()` - write config.yml
8. `_generate_compose()` - write docker-compose.yml
9. `_systemd_autopulse()` - create and enable service
10. `_nginx_autopulse()` - configure reverse proxy
11. `_configure_arr_webhooks()` - add webhooks to all arr instances
12. `_disable_arr_media_connects()` - optionally disable full-scan Connect entries
13. `_update_autopulse()` - pull + recreate + re-discover
14. `_remove_autopulse()` - full teardown including webhook removal
15. Main case statement for --update/--remove/--register-panel/fresh install

## Dependencies

- Docker + Docker Compose (installed by script if missing)
- jq (for JSON parsing during auto-discovery) - installed if missing
- nginx (optional, for reverse proxy)
- sqlite3 (optional, for arr database queries if needed)

## Environment Variable Overrides

For unattended/automated installs:
- `AUTOPULSE_PORT` - override API port
- `AUTOPULSE_UI_PORT` - override UI port
- `AUTOPULSE_AUTH_PASSWORD` - override generated auth password
