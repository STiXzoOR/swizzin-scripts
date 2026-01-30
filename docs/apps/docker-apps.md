# Docker Apps

Docker Compose apps wrapped by systemd for lifecycle management.

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
