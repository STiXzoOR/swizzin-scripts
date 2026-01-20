# Panel Subdomain Installer Design

**Date:** 2026-01-20
**Status:** Approved

## Overview

Extended installer for the Swizzin panel that adds domain/subdomain support with Let's Encrypt certificates. Follows the same pattern as plex.sh, emby.sh, jellyfin.sh, and other subdomain scripts.

## Usage

```bash
bash panel.sh                       # Interactive - installs panel if needed, asks about subdomain
bash panel.sh --subdomain           # Convert to subdomain mode (prompts for domain)
bash panel.sh --subdomain --revert  # Revert to default snake-oil/catch-all mode
bash panel.sh --remove              # Complete removal (runs box remove panel, restores default site)
bash panel.sh --remove --force      # Remove without prompts
```

### Environment Variables

| Variable               | Description                                      |
| ---------------------- | ------------------------------------------------ |
| `PANEL_DOMAIN`         | Skip domain prompt                               |
| `PANEL_LE_HOSTNAME`    | Custom LE hostname (defaults to domain)          |
| `PANEL_LE_INTERACTIVE` | Set to `yes` for interactive LE (CloudFlare DNS) |

## Install States

| State           | Condition                                          |
| --------------- | -------------------------------------------------- |
| `not_installed` | No `/install/.panel.lock`                          |
| `subfolder`     | Panel installed, default site has `server_name _;` |
| `subdomain`     | Panel installed, default site has specific domain  |

## File Changes

### Modified

- `/etc/nginx/sites-enabled/default` - Only the port 443 block (3 lines):
  - `server_name _;` → `server_name <domain>;`
  - `ssl_certificate` → `/etc/nginx/ssl/<domain>/fullchain.pem`
  - `ssl_certificate_key` → `/etc/nginx/ssl/<domain>/key.pem`

### Untouched

- `/etc/nginx/apps/panel.conf` - Never modified
- Port 80 block in default site - Stays as catch-all (`server_name _;`)

### Created

- `/opt/swizzin-extras/panel-backups/default.bak` - Original config backup
- swizdb entry: `panel_domain` - Stores configured domain

### On Revert

- Restore `/etc/nginx/sites-enabled/default` from backup
- Remove swizdb `panel_domain` entry
- SSL certs left in place (Let's Encrypt manages them)

## Nginx Config Transformation

### Before (default)

```nginx
server {
  listen 443 ssl http2 default_server;
  listen [::]:443 ssl http2 default_server;
  server_name _;
  ssl_certificate /etc/ssl/certs/ssl-cert-snakeoil.pem;
  ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key;
  include snippets/ssl-params.conf;
  client_max_body_size 40M;
  server_tokens off;
  root /srv/;

  include /etc/nginx/apps/*.conf;

  location ~ /\.ht {
    deny all;
  }
}
```

### After (subdomain mode)

```nginx
server {
  listen 443 ssl http2 default_server;
  listen [::]:443 ssl http2 default_server;
  server_name panel.example.com;
  ssl_certificate /etc/nginx/ssl/panel.example.com/fullchain.pem;
  ssl_certificate_key /etc/nginx/ssl/panel.example.com/key.pem;
  include snippets/ssl-params.conf;
  client_max_body_size 40M;
  server_tokens off;
  root /srv/;

  include /etc/nginx/apps/*.conf;

  location ~ /\.ht {
    deny all;
  }
}
```

## Script Functions

| Function                 | Purpose                                                  |
| ------------------------ | -------------------------------------------------------- |
| `_get_domain()`          | Retrieve domain from swizdb                              |
| `_prompt_domain()`       | Interactive domain prompt with validation                |
| `_prompt_le_mode()`      | Let's Encrypt mode selection (interactive vs automatic)  |
| `_get_install_state()`   | Detect: not_installed, subfolder, subdomain              |
| `_install_panel()`       | Run `box install panel` if needed                        |
| `_backup_default_site()` | Copy to `/opt/swizzin-extras/panel-backups/`                    |
| `_install_subdomain()`   | Update default site with domain + LE certs               |
| `_revert_subdomain()`    | Restore from backup                                      |
| `_remove()`              | Run `box remove panel`, restore default site if modified |

## Interactive Flow

1. Check install state
2. If `not_installed` → install via `box install panel`
3. If `subfolder` → ask "Set up subdomain?" → prompt domain → request LE cert → update default site
4. If `subdomain` → inform user, offer `--revert` option
5. If Organizr is in subdomain mode → ask about exclusion from SSO

## Organizr Integration

**Condition:** Only offer Organizr exclusion if:

1. Organizr is installed (`/install/.organizr.lock` exists)
2. AND Organizr is in subdomain mode (`/etc/nginx/sites-enabled/organizr` exists)

**Action:** If user chooses to exclude:

- Update `/opt/swizzin-extras/organizr-auth.conf`
- Update `/etc/nginx/snippets/organizr-apps.conf`

## Consistency with Other Scripts

This script follows the same patterns established in:

- `plex.sh`
- `emby.sh`
- `jellyfin.sh`
- `seerr.sh`
- `organizr.sh`

Including:

- Same argument handling (`--subdomain`, `--revert`, `--remove`, `--force`)
- Same environment variable naming convention (`<APP>_DOMAIN`, `<APP>_LE_*`)
- Same backup location pattern (`/opt/swizzin-extras/<app>-backups/`)
- Same swizdb usage for domain persistence
- Same Organizr integration logic
