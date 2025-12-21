# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains Swizzin installer scripts - bash installation scripts for integrating applications into the [Swizzin](https://swizzin.ltd/) self-hosted media server management platform.

## Architecture

### Script Structure

Each installer script follows a consistent pattern:

1. Source Swizzin utilities from `/etc/swizzin/sources/functions/utils`
2. Load the panel helper (locally or fetched from GitHub)
3. Define app variables (port, paths, config directory)
4. Execute installation functions in sequence:
   - `_install_<app>()` - Download, extract, configure
   - `_systemd_<app>()` - Create and enable systemd service
   - `_nginx_<app>()` - Configure reverse proxy (if nginx is installed)
5. Register with Swizzin panel via `panel_register_app()`
6. Create lock file at `/install/.<appname>.lock`

### Binary Placement

- **Single-file binaries** → `/usr/bin/<appname>` (e.g., decypharr, notifiarr, zurg)
- **Multi-file apps** → `/opt/<appname>/` (e.g., seerr, byparr, huntarr, subgen)

### Files

- **decypharr.sh** - Installs Decypharr (encrypted file/torrent management via rclone)
- **notifiarr.sh** - Installs Notifiarr client (notification relay for Starr apps)
- **seerr.sh** - Installs Seerr/Overseerr (media request platform, requires Node.js build)
- **byparr.sh** - Installs Byparr (FlareSolverr alternative, uses uv + Python 3.13)
- **huntarr.sh** - Installs Huntarr (automated media discovery for *arr apps, uses uv)
- **subgen.sh** - Installs Subgen (Whisper-based subtitle generation, uses uv + ffmpeg)
- **zurg.sh** - Installs Zurg (Real-Debrid WebDAV server + rclone mount)
- **organizr-subdomain.sh** - Converts Organizr to subdomain mode with SSO authentication
- **plex.sh** - Extends Plex install with nginx subfolder config at `/plex`
- **plex-subdomain.sh** - Converts Plex from subfolder to subdomain mode
- **emby-subdomain.sh** - Converts Emby from subfolder to subdomain mode
- **jellyfin-subdomain.sh** - Converts Jellyfin from subfolder to subdomain mode
- **sonarr.sh** - Multi-instance Sonarr manager (add/remove/list named instances)
- **radarr.sh** - Multi-instance Radarr manager (add/remove/list named instances)
- **panel_helpers.sh** - Shared utility for Swizzin panel app registration

### Python Apps (uv-based)

Byparr, Huntarr, and Subgen use `uv` for Python version and dependency management:
- uv is installed per-user at `~/.local/bin/uv`
- Apps are cloned to `/opt/<appname>`
- Dependencies installed via `uv sync` or `uv add`
- Systemd runs apps via `uv run python main.py`

### Zurg (Real-Debrid)

Zurg creates two systemd services:
- `zurg.service` - The WebDAV server
- `rclone-zurg.service` - The rclone filesystem mount at `/mnt/zurg`

### Organizr Subdomain (SSO Gateway)

organizr-subdomain.sh is an extension script (not a standalone installer) that:
- Runs `box install organizr` first if Organizr isn't installed
- Converts from subfolder (`/organizr`) to subdomain mode
- Uses Organizr as SSO authentication gateway for other apps via `auth_request`
- Stores config at `/opt/swizzin/organizr-auth.conf`
- Backups at `/opt/swizzin/organizr-backups/`

**Flags:**
- `--configure` - Modify which apps are protected
- `--revert` - Revert to subfolder mode (preserves config)
- `--remove` - Complete removal (runs `box remove organizr`)

**Auth levels:** 0=Admin, 1=Co-Admin, 2=Super User, 3=Power User, 4=User, 998=Logged In

**Key files:**
- `/etc/nginx/sites-available/organizr` - Subdomain vhost with auth endpoint
- `/etc/nginx/snippets/organizr-apps.conf` - Dynamic includes (excludes panel.conf)
- `/opt/swizzin/organizr-auth.conf` - Protected apps configuration

**Auth mechanism:** Uses internal rewrite to `/api/v2/auth?group=N` which is handled by the existing PHP location block. Apps add `auth_request /organizr-auth/auth-0;` to their location blocks.

**Note:** Swizzin's automated Organizr wizard may fail to create the database. Users should complete setup manually via the web interface if needed.

### Media Server Subdomain Scripts

plex-subdomain.sh, emby-subdomain.sh, and jellyfin-subdomain.sh follow a common pattern:

- Convert from subfolder (`/<app>`) to dedicated subdomain
- Request Let's Encrypt certificate via `box install letsencrypt`
- Backup original nginx config to `/opt/swizzin/<app>-backups/`
- Update panel meta with `baseurl = None` and `urloverride` in `/opt/swizzin/core/custom/profiles.py`
- Add `Content-Security-Policy: frame-ancestors` header for Organizr embedding (if configured)
- Exclude app from Organizr SSO protection (removes from both `/opt/swizzin/organizr-auth.conf` and `/etc/nginx/snippets/organizr-apps.conf`)

**Flags:**
- `--revert` - Revert to subfolder mode (restores backup, notifies about re-adding Organizr protection)
- `--remove [--force]` - Complete removal (runs `box remove <app>`)

**Ports:**
- Plex: 32400 (HTTP)
- Emby: 8096 (HTTP)
- Jellyfin: 8922 (HTTPS)

**Nginx features per app:**
- **Plex**: X-Plex-* proxy headers, `/library/streams/` location
- **Emby**: Range/If-Range headers for streaming
- **Jellyfin**: WebSocket `/socket` location, WebOS CORS headers, Range/If-Range headers, `/metrics` with private network ACL

**plex.sh** is a prerequisite for plex-subdomain.sh that adds `/plex` nginx config to Swizzin's Plex install (includes X-Plex-* headers and referer-based rewrite).

### Multi-Instance Scripts (Sonarr/Radarr)

sonarr.sh and radarr.sh manage multiple named instances of Sonarr/Radarr:

**Commands:**
```bash
sonarr.sh                      # Install base if needed, then add instances interactively
sonarr.sh --add [name]         # Add a named instance (e.g., 4k, anime, kids)
sonarr.sh --remove [name]      # Remove instance(s) - interactive if no name
sonarr.sh --remove name --force # Remove without prompts, purge config
sonarr.sh --list               # List all instances with ports
```

**Naming convention:**
| Component | Pattern | Example |
|-----------|---------|---------|
| Service | `sonarr-<name>.service` | `sonarr-4k.service` |
| Config dir | `/home/<user>/.config/sonarr-<name>/` | `/home/user/.config/sonarr-4k/` |
| Nginx | `/etc/nginx/apps/sonarr-<name>.conf` | `/etc/nginx/apps/sonarr-4k.conf` |
| URL path | `/sonarr-<name>/` | `/sonarr-4k/` |
| Lock file | `/install/.sonarr-<name>.lock` | `/install/.sonarr-4k.lock` |

**Instance name validation:**
- Alphanumeric only (a-z, 0-9), converted to lowercase
- Checked against existing lock files for uniqueness
- Reserved words blocked: "base"

**Port allocation:** Dynamic via `port 10000 12000` (not the base port)

**Key differences between apps:**
| Variable | Sonarr | Radarr |
|----------|--------|--------|
| `app_binary` | /opt/Sonarr/Sonarr | /opt/Radarr/Radarr |
| `app_base_port` | 8989 | 7878 |
| `app_branch` | main | master |

**Base app protection:** Base cannot be removed via these scripts. Remove all instances before running `box remove sonarr/radarr`.

### Key Swizzin Functions Used

```bash
port <start> <end>           # Allocate free port in range
apt_install <packages>       # Install packages via apt
swizdb get/set               # Swizzin database operations
_get_master_username         # Get primary Swizzin user
_os_arch                     # Detect CPU architecture (amd64, arm64, armv6)
echo_progress_start/done     # Progress logging
echo_error, echo_info        # Status logging
```

### Environment Variables

| Script | Variable | Required | Description |
|--------|----------|----------|-------------|
| seerr.sh | `SEERR_DOMAIN` | **Yes** | Public FQDN for the Seerr instance |
| seerr.sh | `SEERR_LE_HOSTNAME` | No | Let's Encrypt hostname (defaults to SEERR_DOMAIN) |
| seerr.sh | `SEERR_LE_INTERACTIVE` | No | Set to `yes` for interactive Let's Encrypt (CloudFlare DNS) |
| organizr-subdomain.sh | `ORGANIZR_DOMAIN` | **Yes** | Public FQDN for Organizr subdomain |
| organizr-subdomain.sh | `ORGANIZR_LE_HOSTNAME` | No | Let's Encrypt hostname (defaults to ORGANIZR_DOMAIN) |
| organizr-subdomain.sh | `ORGANIZR_LE_INTERACTIVE` | No | Set to `yes` for interactive Let's Encrypt (CloudFlare DNS) |
| plex-subdomain.sh | `PLEX_DOMAIN` | **Yes** | Public FQDN for Plex subdomain |
| plex-subdomain.sh | `PLEX_LE_HOSTNAME` | No | Let's Encrypt hostname |
| plex-subdomain.sh | `PLEX_LE_INTERACTIVE` | No | Set to `yes` for interactive Let's Encrypt |
| emby-subdomain.sh | `EMBY_DOMAIN` | **Yes** | Public FQDN for Emby subdomain |
| emby-subdomain.sh | `EMBY_LE_HOSTNAME` | No | Let's Encrypt hostname |
| emby-subdomain.sh | `EMBY_LE_INTERACTIVE` | No | Set to `yes` for interactive Let's Encrypt |
| jellyfin-subdomain.sh | `JELLYFIN_DOMAIN` | **Yes** | Public FQDN for Jellyfin subdomain |
| jellyfin-subdomain.sh | `JELLYFIN_LE_HOSTNAME` | No | Let's Encrypt hostname |
| jellyfin-subdomain.sh | `JELLYFIN_LE_INTERACTIVE` | No | Set to `yes` for interactive Let's Encrypt |
| notifiarr.sh | `DN_API_KEY` | Interactive | Notifiarr.com API key (prompted if not set) |
| zurg.sh | Real-Debrid token | Interactive | Real-Debrid API token (prompted if not set) |
| All scripts | `<APP>_OWNER` | No | App owner username (defaults to master user) |

## Conventions
 
### Naming

- `app_*` - Application configuration variables
- `_function_name()` - Private/internal functions (underscore prefix)
- Function pattern: `_<action>_<appname>()` (e.g., `_install_seerr`, `_systemd_notifiarr`)

### Port Allocation

Most installers use `port 10000 12000` to find an available port in the 10000-12000 range.

**Fixed ports:**
- **Byparr**: 8191 (FlareSolverr compatibility)
- **Zurg**: 9999 (WebDAV server default)

### Nginx Configuration

- **Decypharr/Notifiarr/Huntarr**: Location-based routing at `/<appname>/`
- **Seerr**: Dedicated vhost for subdomain-based access with frame-ancestors CSP
- **Organizr Subdomain**: Dedicated vhost at `/etc/nginx/sites-available/organizr` with internal auth rewrite
- **Plex/Emby/Jellyfin Subdomain**: Dedicated vhosts with panel meta urloverride and frame-ancestors CSP
- **Plex (subfolder)**: Location-based routing at `/plex/` via plex.sh
- **Byparr/Subgen/Zurg**: No nginx (internal API/webhook services)
- API endpoints bypass htpasswd authentication

### Panel Icons

For apps with their own logo, set `app_icon_name="$app_name"` and `app_icon_url` to the icon URL.

For apps without a logo, use the placeholder (automatically downloaded by `panel_helpers.sh`):
```bash
app_icon_name="placeholder"
app_icon_url=""
```

### ShellCheck

Scripts source Swizzin globals and utilities:
```bash
. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils
```

### Coding Standards

**Bracket style:** Use Bash `[[ ]]` throughout (not POSIX `[ ]`):
```bash
if [[ -f "$file" ]]; then
if [[ "$var" == "value" ]]; then
```

**Variable quoting:** Always quote variables and use braces for clarity:
```bash
touch "$log"
chown "${user}:${user}" "$config_dir"
mkdir -p "${app_dir}/${app_name}"
```

**Confirmations:** Use Swizzin's `ask` function for yes/no prompts:
```bash
if ask "Would you like to purge the configuration?" N; then
    rm -rf "$config_dir"
fi
```

**Panel helper loading:** Use the download-and-cache pattern:
```bash
PANEL_HELPER_LOCAL="/opt/swizzin/panel_helpers.sh"
PANEL_HELPER_URL="https://raw.githubusercontent.com/STiXzoOR/swizzin-scripts/main/panel_helpers.sh"

_load_panel_helper() {
    if [[ -f "$PANEL_HELPER_LOCAL" ]]; then
        . "$PANEL_HELPER_LOCAL"
        return
    fi
    mkdir -p "$(dirname "$PANEL_HELPER_LOCAL")"
    if curl -fsSL "$PANEL_HELPER_URL" -o "$PANEL_HELPER_LOCAL" >>"$log" 2>&1; then
        chmod +x "$PANEL_HELPER_LOCAL"
        . "$PANEL_HELPER_LOCAL"
    fi
}
```

## Templates

The `templates/` directory contains starter templates for common script types:

| Template | Use Case | Examples |
|----------|----------|----------|
| `template-binary.sh` | Single binary apps installed to `/usr/bin` | decypharr, notifiarr |
| `template-python.sh` | Python apps using uv for dependencies | byparr, huntarr, subgen |
| `template-subdomain.sh` | Converting apps from subfolder to subdomain | plex-subdomain, emby-subdomain |
| `template-multiinstance.sh` | Managing multiple instances of a base app | sonarr, radarr |

Each template includes:
- Detailed header with customization points (marked `# CUSTOMIZE:`)
- Standard function structure
- Inline documentation
- All coding standards applied

## Testing

Scripts must be tested on a Swizzin-installed system. No automated test framework exists.

```bash
# Example execution
export SEERR_DOMAIN="seerr.example.com"
bash seerr.sh
```

## Integration Points

- Swizzin utilities: `/etc/swizzin/sources/functions/utils`
- Swizzin database: accessed via `swizdb` command
- Panel registration: `/opt/swizzin/core/custom/profiles.py`
- Lock files: `/install/.<appname>.lock`
- Logs: `/root/logs/swizzin.log`
