# Swizzin Scripts

A collection of installer scripts for integrating additional applications into [Swizzin](https://swizzin.ltd/), a self-hosted media server management platform.

## Available Scripts

| Script | Application | Description |
|--------|-------------|-------------|
| [decypharr.sh](#decypharr) | [Decypharr](https://github.com/sirrobot01/decypharr) | Encrypted file/torrent management via rclone and qBittorrent |
| [notifiarr.sh](#notifiarr) | [Notifiarr](https://github.com/Notifiarr/notifiarr) | Notification relay client for *arr apps and Plex |
| [organizr-subdomain.sh](#organizr-subdomain) | [Organizr](https://github.com/causefx/Organizr) | Convert Organizr to subdomain with SSO authentication |
| [seerr.sh](#seerr) | [Seerr](https://github.com/seerr-team/seerr) | Media request platform (Overseerr fork) |
| [byparr.sh](#byparr) | [Byparr](https://github.com/ThePhaseless/Byparr) | FlareSolverr alternative for bypassing anti-bot protections |
| [huntarr.sh](#huntarr) | [Huntarr](https://github.com/plexguide/Huntarr.io) | Automated media discovery for Sonarr, Radarr, Lidarr, etc. |
| [subgen.sh](#subgen) | [Subgen](https://github.com/McCloudS/subgen) | Automatic subtitle generation using Whisper AI |
| [zurg.sh](#zurg) | [Zurg](https://github.com/debridmediamanager/zurg-testing) | Real-Debrid WebDAV server with rclone mount |

## Requirements

- A working [Swizzin](https://swizzin.ltd/) installation
- Root access to the server
- Internet connectivity for downloading dependencies

## Installation

```bash
# Switch to root
sudo su -

# Download the script
wget https://raw.githubusercontent.com/STiXzoOR/swizzin-scripts/main/<script>.sh
# or
curl -O https://raw.githubusercontent.com/STiXzoOR/swizzin-scripts/main/<script>.sh

# Make executable and run
chmod +x ~/<script>.sh
~/<script>.sh
```

## Scripts

### Decypharr

Manages encrypted files and torrents using rclone integration with qBittorrent.

```bash
# Optional: Set custom owner (defaults to master user)
export DECYPHARR_OWNER="username"

bash decypharr.sh
```

**Access:** `https://your-server/decypharr/`

**Config:** `/home/<user>/.config/Decypharr/config.json`

---

### Notifiarr

Official client for [Notifiarr.com](https://notifiarr.com/) - provides notifications and integrations for *arr apps, Plex, and more.

```bash
# Optional: Set custom owner
export NOTIFIARR_OWNER="username"

# You will be prompted for your Notifiarr API key during installation
bash notifiarr.sh
```

**Access:** `https://your-server/notifiarr/`

**Config:** `/home/<user>/.config/Notifiarr/notifiarr.conf`

**Login:** Username: `admin` | Password: your API key (can be changed in Profile page)

---

### Organizr Subdomain

Converts Swizzin's default Organizr installation from subfolder (`/organizr`) to subdomain mode with SSO authentication for other apps.

```bash
# Required: Set the public domain for Organizr
export ORGANIZR_DOMAIN="organizr.example.com"

bash organizr-subdomain.sh
```

**Access:** `https://organizr.example.com/`

**Config:** `/opt/swizzin/organizr-auth.conf`

**Features:**
- Automatic Let's Encrypt certificate
- SSO authentication for selected apps (replaces htpasswd)
- Interactive app selection menu
- Configurable auth levels per app (Admin, User, etc.)

**Additional Commands:**

```bash
# Modify which apps are protected
bash organizr-subdomain.sh --configure

# Revert to subfolder mode
bash organizr-subdomain.sh --revert

# Complete removal
bash organizr-subdomain.sh --remove
```

**Note:** This script runs `box install organizr` first if Organizr isn't already installed.

---

### Seerr

Media request and discovery platform (Overseerr fork) with Plex/Jellyfin integration.

```bash
# Required: Set the public domain for Seerr
export SEERR_DOMAIN="seerr.example.com"

# Optional: Custom Let's Encrypt hostname (defaults to SEERR_DOMAIN)
export SEERR_LE_HOSTNAME="example.com"

# Optional: Set custom owner
export SEERR_OWNER="username"

bash seerr.sh
```

**Access:** `https://seerr.example.com/`

**Config:** `/home/<user>/.config/Seerr/`

**Note:** Seerr requires a dedicated subdomain. During installation, you will be prompted to configure Let's Encrypt interactively.

---

### Byparr

FlareSolverr-compatible alternative using Camoufox browser for bypassing anti-bot protections. Used by Prowlarr and other *arr apps.

```bash
# Optional: Set custom owner
export BYPARR_OWNER="username"

bash byparr.sh
```

**Port:** 8191 (FlareSolverr default for drop-in compatibility)

**Config:** `/home/<user>/.config/Byparr/env.conf`

**Prowlarr Setup:** Add as FlareSolverr indexer proxy with URL `http://127.0.0.1:8191`

---

### Huntarr

Automated media discovery tool that systematically searches for missing and upgradeable content across your *arr applications.

```bash
# Optional: Set custom owner
export HUNTARR_OWNER="username"

bash huntarr.sh
```

**Access:** `https://your-server/huntarr/`

**Config:** `/home/<user>/.config/Huntarr/env.conf`

**Post-Install:** Configure your *arr app connections via the web UI.

---

### Subgen

Automatic subtitle generation for your media library using OpenAI's Whisper AI model. Integrates with Plex, Jellyfin, and Emby via webhooks.

```bash
# Optional: Set custom owner
export SUBGEN_OWNER="username"

bash subgen.sh
```

**Webhook URL:** `http://127.0.0.1:<port>/webhook`

**Config:** `/home/<user>/.config/Subgen/env.conf`

**Default Settings:**
- Model: `medium` (balance of speed and accuracy)
- Device: `cpu` (GPU can be enabled by editing env.conf)
- Format: `srt`

**Media Server Setup:**
- **Plex:** Settings → Webhooks → Add `http://127.0.0.1:<port>/webhook`
- **Jellyfin:** Plugins → Webhook → Add endpoint
- **Emby:** Server → Webhooks → Add URL

---

### Zurg

Self-hosted Real-Debrid WebDAV server that mounts your debrid library as a local filesystem using rclone.

```bash
# Optional: Set custom owner
export ZURG_OWNER="username"

# You will be prompted for your Real-Debrid API token during installation
bash zurg.sh
```

**Port:** 9999 (WebDAV server)

**Mount Point:** `/mnt/zurg` (your Real-Debrid library)

**Config:** `/home/<user>/.config/zurg/config.yml`

**Services:**
- `zurg.service` - The WebDAV server
- `rclone-zurg.service` - The filesystem mount

**Get your API token:** https://real-debrid.com/apitoken

**Usage with *arr apps:** Point your *arr applications to `/mnt/zurg` for accessing Real-Debrid content.

---

## Environment Variables

All scripts support an optional `<APP>_OWNER` variable to specify the user account for the application. If not set, the Swizzin master user is used.

| Variable | Script | Required | Description |
|----------|--------|----------|-------------|
| `ORGANIZR_DOMAIN` | organizr-subdomain.sh | **Yes** | Public FQDN for Organizr |
| `SEERR_DOMAIN` | seerr.sh | **Yes** | Public FQDN for Seerr |
| `SEERR_LE_HOSTNAME` | seerr.sh | No | Let's Encrypt hostname |
| `DN_API_KEY` | notifiarr.sh | No* | Notifiarr.com API key (prompted if not set) |
| `RD_TOKEN` | zurg.sh | No* | Real-Debrid API token (prompted if not set) |
| `<APP>_OWNER` | All | No | Application owner username |

*Required for non-interactive installs (e.g., when piping to bash)

## Panel Integration

All scripts automatically register with the Swizzin panel if installed. Apps appear in the panel with their icons and links.

## Uninstallation

All scripts support the `--remove` flag for complete uninstallation:

```bash
# Switch to root
sudo su -

# Download the script (if not already present)
wget https://raw.githubusercontent.com/STiXzoOR/swizzin-scripts/main/<script>.sh

# Run with --remove flag
bash <script>.sh --remove
```

This will:
- Stop and disable all related services
- Remove the application binary/directory
- Remove nginx configuration
- Remove from Swizzin panel
- Remove configuration files
- Clean up lock files

**Note:** For Seerr, the Let's Encrypt certificate is not removed automatically.

## Architecture

Scripts follow a consistent pattern:

1. Source Swizzin utilities
2. Set application variables (port, paths, etc.)
3. Install dependencies and application
4. Create systemd service
5. Configure nginx reverse proxy (where applicable)
6. Register with Swizzin panel
7. Create lock file at `/install/.<app>.lock`

### Python Apps (uv-based)

Byparr, Huntarr, and Subgen use [uv](https://github.com/astral-sh/uv) for Python version and dependency management:
- uv is installed per-user at `~/.local/bin/uv`
- Applications are cloned to `/opt/<appname>`
- Systemd runs apps via `uv run python main.py`

## Contributing

1. Fork the repository
2. Create a feature branch
3. Follow the existing script patterns
4. Test on a Swizzin installation
5. Submit a pull request

## License

This project is licensed under the GPL-3.0 License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [Swizzin](https://swizzin.ltd/) - The media server management platform
- All the amazing open-source projects these scripts install
