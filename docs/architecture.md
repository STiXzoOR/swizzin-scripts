# Architecture

## Script Structure

Each installer script follows this sequence:

1. Source Swizzin utilities from `/etc/swizzin/sources/functions/utils`
2. Load the panel helper (locally or fetched from GitHub)
3. Define app variables (port, paths, config directory)
4. Execute installation functions:
   - `_install_<app>()` - Download, extract, configure
   - `_systemd_<app>()` - Create and enable systemd service
   - `_nginx_<app>()` - Configure reverse proxy (if nginx installed)
5. Register with Swizzin panel via `panel_register_app()`
6. Create lock file at `/install/.<appname>.lock`

## Binary Placement

| Type                 | Location                                    | Examples                                   |
| -------------------- | ------------------------------------------- | ------------------------------------------ |
| Single-file binaries | `/usr/bin/<appname>`                        | decypharr, notifiarr, zurg                 |
| Multi-file apps      | `/opt/<appname>/`                           | cleanuparr, seerr, byparr, huntarr, subgen |
| Docker apps          | `/opt/<appname>/` with `docker-compose.yml` | lingarr, libretranslate                    |

## Files Overview

| Script              | Description                                                 |
| ------------------- | ----------------------------------------------------------- |
| `cleanuparr.sh`     | Download queue cleanup for \*arr apps                       |
| `decypharr.sh`      | Encrypted file/torrent management via rclone                |
| `notifiarr.sh`      | Notification relay for Starr apps                           |
| `seerr.sh`          | Media request platform with subdomain support               |
| `byparr.sh`         | FlareSolverr alternative (uv + Python 3.13)                 |
| `huntarr.sh`        | Automated media discovery for \*arr apps (uv)               |
| `subgen.sh`         | Whisper-based subtitle generation (uv + Python 3.11)        |
| `zurg.sh`           | Real-Debrid WebDAV server + rclone mount                    |
| `lingarr.sh`        | Subtitle translation (Docker, auto-discovers Sonarr/Radarr) |
| `libretranslate.sh` | Machine translation API (Docker, GPU auto-detection)        |
| `organizr.sh`       | SSO gateway with subdomain support                          |
| `plex.sh`           | Plex with subdomain support                                 |
| `emby.sh`           | Emby with subdomain + Premiere bypass                       |
| `jellyfin.sh`       | Jellyfin with subdomain support                             |
| `panel.sh`          | Swizzin panel subdomain support                             |
| `sonarr.sh`         | Multi-instance Sonarr manager                               |
| `radarr.sh`         | Multi-instance Radarr manager                               |
| `panel_helpers.sh`  | Shared panel registration utility                           |

## Function Naming

- `app_*` - Application configuration variables
- `_function_name()` - Private/internal functions (underscore prefix)
- Pattern: `_<action>_<appname>()` (e.g., `_install_seerr`, `_systemd_notifiarr`)

## Key Swizzin Functions

```bash
port <start> <end>           # Allocate free port in range
apt_install <packages>       # Install packages via apt
swizdb get/set               # Swizzin database operations
_get_master_username         # Get primary Swizzin user
_os_arch                     # Detect CPU architecture (amd64, arm64, armv6)
echo_progress_start/done     # Progress logging
echo_error, echo_info        # Status logging
ask "question?" Y/N          # Interactive yes/no prompts
```

## Port Allocation

Most installers use `port 10000 12000` to find an available port.

**Fixed ports:**

- Byparr: 8191 (FlareSolverr compatibility)
- Zurg: 9999 (WebDAV server default)

## Integration Points

| Component          | Location                               |
| ------------------ | -------------------------------------- |
| Swizzin utilities  | `/etc/swizzin/sources/functions/utils` |
| Swizzin database   | `swizdb` command                       |
| Panel registration | `/opt/swizzin/core/custom/profiles.py` |
| Lock files         | `/install/.<appname>.lock`             |
| Logs               | `/root/logs/swizzin.log`               |

## Python Apps (uv-based)

Byparr, Huntarr, and Subgen use `uv` for Python management:

- uv installed per-user at `~/.local/bin/uv`
- Apps cloned to `/opt/<appname>`
- Dependencies via `uv sync` or `uv add`
- Systemd runs apps via `uv run python <entry>.py`
- Subgen runs `subgen.py` directly (not `launcher.py`), auto-detects NVIDIA GPU

## Nginx Configuration

| App Type                               | Pattern                                                    |
| -------------------------------------- | ---------------------------------------------------------- |
| Cleanuparr/Decypharr/Notifiarr/Huntarr | Location-based at `/<appname>/`                            |
| Lingarr                                | Subfolder (`/lingarr/` with sub_filter) or subdomain vhost |
| Seerr                                  | Dedicated vhost with frame-ancestors CSP                   |
| Organizr                               | Dedicated vhost at `/etc/nginx/sites-available/organizr`   |
| Plex/Emby/Jellyfin                     | Dedicated vhosts with panel meta urloverride               |
| Byparr/Subgen/Zurg                     | No nginx (internal API/webhook services)                   |

API endpoints bypass htpasswd authentication.

## Panel Icons

For apps with their own logo:

```bash
app_icon_name="$app_name"
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/myapp.png"
```

For apps without a logo (uses placeholder):

```bash
app_icon_name="placeholder"
app_icon_url=""
```
