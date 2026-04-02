# Docker Apps

Docker Compose apps wrapped by systemd for lifecycle management.

## Autopulse

Media server library notifier. Receives Sonarr/Radarr webhooks and sends targeted library update notifications to Emby/Jellyfin/Plex via path-specific API calls (replaces slow full-library scans).

**Install:** `bash autopulse.sh`
**Update:** `bash autopulse.sh --update`
**Remove:** `bash autopulse.sh --remove`

**Auto-discovery:** The installer automatically discovers all Sonarr/Radarr/Lidarr/Readarr instances and Emby/Jellyfin/Plex servers. It configures Autopulse triggers/targets and adds webhook notifications to each arr instance.

**Ports:** Two dynamic ports (API + UI) allocated from 10000-12000 range.

**Nginx:** Exposed at `/autopulse` subfolder. Trigger API endpoints at `/autopulse/triggers/` bypass basic auth for Sonarr/Radarr webhook access.

**Environment overrides** (unattended install):
- `AUTOPULSE_PORT` — API port
- `AUTOPULSE_UI_PORT` — UI port
- `AUTOPULSE_AUTH_PASSWORD` — Auth password

**Upstream:** [dan-online/autopulse](https://github.com/dan-online/autopulse)

---

## Lingarr

Subtitle translation service that auto-discovers Sonarr/Radarr installations.

### File Layout

| Path                                  | Purpose                    |
| ------------------------------------- | -------------------------- |
| `/opt/lingarr/docker-compose.yml`     | Compose file               |
| `/opt/lingarr/config/`                | Lingarr config + SQLite DB |
| `/etc/nginx/apps/lingarr.conf`        | Reverse proxy (subfolder)  |
| `/etc/nginx/sites-available/lingarr`  | Reverse proxy (subdomain)  |
| `/etc/systemd/system/lingarr.service` | Systemd wrapper            |
| `/install/.lingarr.lock`              | Swizzin lock file          |

### Features

- Docker Engine + Compose plugin auto-installed if missing
- Media paths auto-discovered from Sonarr/Radarr SQLite databases (base + multi-instance)
- Sonarr/Radarr API credentials auto-discovered from `config.xml`
- Port bound to `127.0.0.1` only (nginx handles external access)
- Container runs as master user UID:GID
- `--update` flag pulls latest image and recreates container
- Supports subfolder mode (`/lingarr/` with sub_filter) and subdomain mode

### Subdomain Mode

Subdomain mode follows the same pattern as seerr.sh:

- Standalone panel meta class
- Let's Encrypt certificate
- Organizr integration (optional)

---

## LibreTranslate

Machine translation API with GPU auto-detection and Lingarr integration.

### File Layout

| Path                                         | Purpose                   |
| -------------------------------------------- | ------------------------- |
| `/opt/libretranslate/docker-compose.yml`     | Compose file              |
| `/opt/libretranslate/config/`                | DB + models cache         |
| `/etc/nginx/apps/libretranslate.conf`        | Reverse proxy (subfolder) |
| `/etc/nginx/sites-available/libretranslate`  | Reverse proxy (subdomain) |
| `/etc/systemd/system/libretranslate.service` | Systemd wrapper           |
| `/install/.libretranslate.lock`              | Swizzin lock file         |

### Features

- Auto-detects NVIDIA GPU and uses CUDA image if available
- Whiptail multi-select picker for 48 supported languages
- Auto-configures Lingarr integration if Lingarr is detected
- Native `LT_URL_PREFIX` support for subfolder mode (no sub_filter needed)
- Port dynamically allocated via `port 10000 12000`
- htpasswd protection on web UI, API endpoints bypass auth

---

## StremThru

Debrid streaming proxy with store management. Provides Torznab API for Prowlarr integration.

### File Layout

| Path                                   | Purpose                   |
| -------------------------------------- | ------------------------- |
| `/opt/stremthru/docker-compose.yml`    | Compose file              |
| `/opt/stremthru/data/`                 | SQLite DB + hashlists     |
| `/opt/stremthru/.env`                  | Credentials               |
| `/etc/nginx/apps/stremthru.conf`       | Reverse proxy (subfolder) |
| `/etc/systemd/system/stremthru.service`| Systemd wrapper           |
| `/install/.stremthru.lock`             | Swizzin lock file         |

### Features

- Single container with SQLite database
- Stores debrid credentials in `.env` file (chmod 600)
- `proxy_cookie_path` for session cookie rewriting behind subfolder proxy
- Torznab API endpoint bypasses auth for Prowlarr access

---

## MediaFusion

Stremio/Kodi universal add-on with native Torznab API for Prowlarr. 5-container stack.

### File Layout

| Path                                      | Purpose                      |
| ----------------------------------------- | ---------------------------- |
| `/opt/mediafusion/docker-compose.yml`     | Compose file (5 services)    |
| `/opt/mediafusion/pgdata/`               | PostgreSQL data              |
| `/opt/mediafusion/redis/`                | Redis persistence            |
| `/etc/nginx/apps/mediafusion.conf`       | Reverse proxy (subfolder)    |
| `/etc/systemd/system/mediafusion.service`| Systemd wrapper              |
| `/install/.mediafusion.lock`             | Swizzin lock file            |

### Features

- 5 containers: app, worker (Dramatiq), PostgreSQL, Redis, Browserless (headless Chrome)
- Main container uses entrypoint sed to patch gunicorn bind port dynamically
- `HOST_URL` env var set from Organizr domain detection chain
- Comprehensive `sub_filter` rules for SPA JavaScript path rewriting
- Custom Prowlarr Cardigann indexer definition deployed from `resources/prowlarr/mediafusion.yml`
- Torznab and manifest endpoints bypass auth for Prowlarr/Stremio access

---

## Zilean

DMM hashlist Torznab indexer. Indexes debrid-cached content from DebridMediaManager hashlists.

### File Layout

| Path                                  | Purpose                   |
| ------------------------------------- | ------------------------- |
| `/opt/zilean/docker-compose.yml`      | Compose file              |
| `/opt/zilean/data/`                   | Config + IMDB title data  |
| `/opt/zilean/pgdata/`                | PostgreSQL data           |
| `/etc/nginx/apps/zilean.conf`        | Reverse proxy (subfolder) |
| `/etc/systemd/system/zilean.service` | Systemd wrapper           |
| `/install/.zilean.lock`              | Swizzin lock file         |

### Features

- 2 containers: app + PostgreSQL
- Standard Torznab API compatible with Prowlarr Generic Torznab indexer
- IMDB title data auto-downloaded on first run

---

## NzbDAV

NZB-to-WebDAV bridge for using debrid services as download clients in arr apps.

### File Layout

| Path                                | Purpose                   |
| ----------------------------------- | ------------------------- |
| `/opt/nzbdav/docker-compose.yml`   | Compose file              |
| `/opt/nzbdav/config/`             | SQLite DB + config        |
| `/etc/nginx/apps/nzbdav.conf`     | Reverse proxy (subfolder) |
| `/etc/systemd/system/nzbdav.service` | Systemd wrapper        |
| `/install/.nzbdav.lock`           | Swizzin lock file         |

### Features

- Single container with SQLite database
- React Router SSR frontend with `sub_filter` path rewriting
- Bridges NZB protocol to WebDAV for debrid download clients

---

## Common Docker Patterns

### Systemd Service Type

```ini
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/docker compose -f /opt/<app>/docker-compose.yml up -d
ExecStop=/usr/bin/docker compose -f /opt/<app>/docker-compose.yml down
```

### Docker Installation

Docker Engine + Compose plugin are auto-installed if missing. The installer bypasses `apt_install` for Docker packages due to GPG key requirements.

### Container User

Containers run as the master user's UID:GID for file permission consistency with other Swizzin apps.
