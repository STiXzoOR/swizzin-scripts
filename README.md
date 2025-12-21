# Swizzin Scripts

A collection of installer scripts for integrating additional applications into [Swizzin](https://swizzin.ltd/), a self-hosted media server management platform.

## Available Scripts

| Script | Application | Description |
|--------|-------------|-------------|
| [sonarr.sh](#sonarr) | [Sonarr](https://sonarr.tv/) | Multi-instance Sonarr manager (4k, anime, etc.) |
| [radarr.sh](#radarr) | [Radarr](https://radarr.video/) | Multi-instance Radarr manager (4k, anime, etc.) |
| [decypharr.sh](#decypharr) | [Decypharr](https://github.com/sirrobot01/decypharr) | Encrypted file/torrent management via rclone and qBittorrent |
| [notifiarr.sh](#notifiarr) | [Notifiarr](https://github.com/Notifiarr/notifiarr) | Notification relay client for *arr apps and Plex |
| [organizr-subdomain.sh](#organizr-subdomain) | [Organizr](https://github.com/causefx/Organizr) | Convert Organizr to subdomain with SSO authentication |
| [plex.sh](#plex) | [Plex](https://plex.tv/) | Extend Plex install with nginx subfolder config |
| [plex-subdomain.sh](#plex-subdomain) | [Plex](https://plex.tv/) | Convert Plex to subdomain mode |
| [emby-subdomain.sh](#emby-subdomain) | [Emby](https://emby.media/) | Convert Emby to subdomain mode |
| [jellyfin-subdomain.sh](#jellyfin-subdomain) | [Jellyfin](https://jellyfin.org/) | Convert Jellyfin to subdomain mode |
| [seerr.sh](#seerr) | [Seerr](https://github.com/seerr-team/seerr) | Media request platform (Overseerr fork) |
| [byparr.sh](#byparr) | [Byparr](https://github.com/ThePhaseless/Byparr) | FlareSolverr alternative for bypassing anti-bot protections |
| [huntarr.sh](#huntarr) | [Huntarr](https://github.com/plexguide/Huntarr.io) | Automated media discovery for Sonarr, Radarr, Lidarr, etc. |
| [subgen.sh](#subgen) | [Subgen](https://github.com/McCloudS/subgen) | Automatic subtitle generation using Whisper AI |
| [zurg.sh](#zurg) | [Zurg](https://github.com/debridmediamanager/zurg-testing) | Real-Debrid WebDAV server with rclone mount |
| [dns-fix.sh](#dns-fix) | - | Fix DNS issues for FlareSolverr/Byparr cookie validation |

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

### Sonarr

Multi-instance Sonarr manager. Installs the base Sonarr app if needed, then allows adding named instances (e.g., 4k, anime, kids).

```bash
# Install base + add instances interactively
bash sonarr.sh

# Add a specific instance
bash sonarr.sh --add 4k

# List all instances
bash sonarr.sh --list

# Remove instances (interactive)
bash sonarr.sh --remove

# Remove specific instance
bash sonarr.sh --remove 4k

# Remove without prompts
bash sonarr.sh --remove 4k --force
```

**Instance naming:** Alphanumeric only (e.g., `4k`, `anime`, `kids`, `remux`)

**Per-instance files:**
- Config: `/home/<user>/.config/sonarr-<name>/`
- Service: `sonarr-<name>.service`
- Access: `https://your-server/sonarr-<name>/`

**Note:** Base Sonarr is installed via `box install sonarr`. Instances share the binary at `/opt/Sonarr/` but have separate configs and ports.

---

### Radarr

Multi-instance Radarr manager. Installs the base Radarr app if needed, then allows adding named instances (e.g., 4k, anime, kids).

```bash
# Install base + add instances interactively
bash radarr.sh

# Add a specific instance
bash radarr.sh --add 4k

# List all instances
bash radarr.sh --list

# Remove instances (interactive)
bash radarr.sh --remove

# Remove specific instance
bash radarr.sh --remove 4k

# Remove without prompts
bash radarr.sh --remove 4k --force
```

**Instance naming:** Alphanumeric only (e.g., `4k`, `anime`, `kids`, `remux`)

**Per-instance files:**
- Config: `/home/<user>/.config/radarr-<name>/`
- Service: `radarr-<name>.service`
- Access: `https://your-server/radarr-<name>/`

**Note:** Base Radarr is installed via `box install radarr`. Instances share the binary at `/opt/Radarr/` but have separate configs and ports.

---

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

# Optional: Custom Let's Encrypt hostname (defaults to ORGANIZR_DOMAIN)
export ORGANIZR_LE_HOSTNAME="example.com"

# Optional: Interactive Let's Encrypt (for CloudFlare DNS validation)
export ORGANIZR_LE_INTERACTIVE="yes"

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

**Notes:**
- This script runs `box install organizr` first if Organizr isn't already installed.
- Swizzin's automated Organizr wizard may fail. If Organizr shows the setup wizard, complete it manually at your subdomain URL.

---

### Plex

Extends Swizzin's Plex installation with an nginx subfolder configuration for accessing Plex at `/plex`.

```bash
bash plex.sh
```

**Access:** `https://your-server/plex/`

**Additional Commands:**

```bash
# Complete removal (removes Plex entirely)
bash plex.sh --remove

# Force removal
bash plex.sh --remove --force
```

---

### Plex Subdomain

Converts Plex from subfolder (`/plex`) to subdomain mode with Let's Encrypt certificate.

```bash
# Required: Set the public domain for Plex
export PLEX_DOMAIN="plex.example.com"

# Optional: Custom Let's Encrypt hostname
export PLEX_LE_HOSTNAME="example.com"

# Optional: Interactive Let's Encrypt (for CloudFlare DNS validation)
export PLEX_LE_INTERACTIVE="yes"

bash plex-subdomain.sh
```

**Access:** `https://plex.example.com/`

**Features:**
- Automatic Let's Encrypt certificate
- Proper X-Plex-* proxy headers for client communication
- Frame-ancestors CSP header for Organizr embedding (if configured)
- Automatically removes from Organizr SSO protection

**Additional Commands:**

```bash
# Revert to subfolder mode
bash plex-subdomain.sh --revert

# Complete removal
bash plex-subdomain.sh --remove
```

---

### Emby Subdomain

Converts Emby from subfolder (`/emby`) to subdomain mode with Let's Encrypt certificate.

```bash
# Required: Set the public domain for Emby
export EMBY_DOMAIN="emby.example.com"

# Optional: Custom Let's Encrypt hostname
export EMBY_LE_HOSTNAME="example.com"

# Optional: Interactive Let's Encrypt (for CloudFlare DNS validation)
export EMBY_LE_INTERACTIVE="yes"

bash emby-subdomain.sh
```

**Access:** `https://emby.example.com/`

**Features:**
- Automatic Let's Encrypt certificate
- Range/If-Range headers for proper media streaming
- Frame-ancestors CSP header for Organizr embedding (if configured)
- Automatically removes from Organizr SSO protection

**Additional Commands:**

```bash
# Revert to subfolder mode
bash emby-subdomain.sh --revert

# Complete removal
bash emby-subdomain.sh --remove
```

**Note:** Runs `box install emby` first if Emby isn't already installed.

---

### Jellyfin Subdomain

Converts Jellyfin from subfolder (`/jellyfin`) to subdomain mode with Let's Encrypt certificate.

```bash
# Required: Set the public domain for Jellyfin
export JELLYFIN_DOMAIN="jellyfin.example.com"

# Optional: Custom Let's Encrypt hostname
export JELLYFIN_LE_HOSTNAME="example.com"

# Optional: Interactive Let's Encrypt (for CloudFlare DNS validation)
export JELLYFIN_LE_INTERACTIVE="yes"

bash jellyfin-subdomain.sh
```

**Access:** `https://jellyfin.example.com/`

**Features:**
- Automatic Let's Encrypt certificate
- WebSocket support via `/socket` location
- WebOS LG TV CORS headers
- Range/If-Range headers for proper media streaming
- Prometheus `/metrics` endpoint with private network restrictions
- Frame-ancestors CSP header for Organizr embedding (if configured)
- Automatically removes from Organizr SSO protection

**Additional Commands:**

```bash
# Revert to subfolder mode
bash jellyfin-subdomain.sh --revert

# Complete removal
bash jellyfin-subdomain.sh --remove
```

**Note:** Runs `box install jellyfin` first if Jellyfin isn't already installed.

---

### Seerr

Media request and discovery platform (Overseerr fork) with Plex/Jellyfin integration.

```bash
# Required: Set the public domain for Seerr
export SEERR_DOMAIN="seerr.example.com"

# Optional: Custom Let's Encrypt hostname (defaults to SEERR_DOMAIN)
export SEERR_LE_HOSTNAME="example.com"

# Optional: Interactive Let's Encrypt (for CloudFlare DNS validation)
export SEERR_LE_INTERACTIVE="yes"

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

## Utility Scripts

### DNS Fix

Fixes DNS resolution issues that can cause "cookies not valid" errors when using FlareSolverr or Byparr with Jackett indexers.

```bash
# Check current DNS status
bash dns-fix.sh --status

# Apply fix (configure public DNS, optionally disable IPv6)
bash dns-fix.sh

# Revert to original configuration
bash dns-fix.sh --revert
```

**What it does:**
- Configures system to use public DNS (8.8.8.8, 1.1.1.1)
- Optionally disables IPv6 (can cause resolution mismatches)
- Backs up original configuration
- Restarts affected services (byparr, jackett, etc.)

**When to use:** If Jackett reports "The cookies provided by FlareSolverr are not valid" when testing indexers.

---

## Environment Variables

All scripts support an optional `<APP>_OWNER` variable to specify the user account for the application. If not set, the Swizzin master user is used.

| Variable | Script | Required | Description |
|----------|--------|----------|-------------|
| `ORGANIZR_DOMAIN` | organizr-subdomain.sh | **Yes** | Public FQDN for Organizr |
| `ORGANIZR_LE_HOSTNAME` | organizr-subdomain.sh | No | Let's Encrypt hostname |
| `ORGANIZR_LE_INTERACTIVE` | organizr-subdomain.sh | No | Set to `yes` for interactive LE |
| `PLEX_DOMAIN` | plex-subdomain.sh | **Yes** | Public FQDN for Plex |
| `PLEX_LE_HOSTNAME` | plex-subdomain.sh | No | Let's Encrypt hostname |
| `PLEX_LE_INTERACTIVE` | plex-subdomain.sh | No | Set to `yes` for interactive LE |
| `EMBY_DOMAIN` | emby-subdomain.sh | **Yes** | Public FQDN for Emby |
| `EMBY_LE_HOSTNAME` | emby-subdomain.sh | No | Let's Encrypt hostname |
| `EMBY_LE_INTERACTIVE` | emby-subdomain.sh | No | Set to `yes` for interactive LE |
| `JELLYFIN_DOMAIN` | jellyfin-subdomain.sh | **Yes** | Public FQDN for Jellyfin |
| `JELLYFIN_LE_HOSTNAME` | jellyfin-subdomain.sh | No | Let's Encrypt hostname |
| `JELLYFIN_LE_INTERACTIVE` | jellyfin-subdomain.sh | No | Set to `yes` for interactive LE |
| `SEERR_DOMAIN` | seerr.sh | **Yes** | Public FQDN for Seerr |
| `SEERR_LE_HOSTNAME` | seerr.sh | No | Let's Encrypt hostname |
| `SEERR_LE_INTERACTIVE` | seerr.sh | No | Set to `yes` for interactive LE |
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
3. **Use a template** from `templates/` as your starting point:
   - `template-binary.sh` - For single-binary applications
   - `template-python.sh` - For Python apps using uv
   - `template-subdomain.sh` - For subdomain converters
   - `template-multiinstance.sh` - For multi-instance managers
4. Follow the coding standards in `CLAUDE.md`
5. Test on a Swizzin installation
6. Submit a pull request

See `CLAUDE.md` for detailed coding conventions and architecture documentation.

## License

This project is licensed under the GPL-3.0 License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [Swizzin](https://swizzin.ltd/) - The media server management platform
- All the amazing open-source projects these scripts install
