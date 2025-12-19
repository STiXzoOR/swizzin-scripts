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

### Files

- **decypharr.sh** - Installs Decypharr (encrypted file/torrent management via rclone)
- **notifiarr.sh** - Installs Notifiarr client (notification relay for Starr apps)
- **seerr.sh** - Installs Seerr/Overseerr (media request platform, requires Node.js build)
- **byparr.sh** - Installs Byparr (FlareSolverr alternative, uses uv + Python 3.13)
- **huntarr.sh** - Installs Huntarr (automated media discovery for *arr apps, uses uv)
- **subgen.sh** - Installs Subgen (Whisper-based subtitle generation, uses uv + ffmpeg)
- **zurg.sh** - Installs Zurg (Real-Debrid WebDAV server + rclone mount)
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
- **Seerr**: Dedicated vhost file for subdomain-based access
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

Scripts use shellcheck source directives:
```bash
#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils
```

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
