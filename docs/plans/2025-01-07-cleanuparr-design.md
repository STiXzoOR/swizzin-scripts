# Cleanuparr Installer Design

## Overview

Swizzin installer script for Cleanuparr - a download queue cleanup tool from the Huntarr team that removes stalled/blocked downloads from *arr applications (Sonarr, Radarr, Lidarr, etc.).

**Source:** https://github.com/Cleanuparr/Cleanuparr

## Usage

```bash
bash cleanuparr.sh              # Install
bash cleanuparr.sh --remove     # Remove (asks about purging config)
bash cleanuparr.sh --remove --force  # Force remove without lock check
```

## File Structure

```
/opt/cleanuparr/
├── Cleanuparr           # Main binary (chmod +x)
└── config/
    └── cleanuparr.json  # Config file

/etc/systemd/system/cleanuparr.service
/etc/nginx/apps/cleanuparr.conf
/install/.cleanuparr.lock
```

## Configuration

| Variable | Value |
|----------|-------|
| `app_name` | `cleanuparr` |
| `app_port` | Dynamic (10000-12000) |
| `app_dir` | `/opt/cleanuparr` |
| `app_binary` | `Cleanuparr` |
| `app_configdir` | `/opt/cleanuparr/config` |
| `app_baseurl` | `cleanuparr` |
| `app_icon_url` | `https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/cleanuparr.png` |

**Config file** (`/opt/cleanuparr/config/cleanuparr.json`):
```json
{
  "PORT": <allocated_port>,
  "BIND_ADDRESS": "127.0.0.1",
  "BASE_PATH": "/cleanuparr"
}
```

## Installation Flow

1. Create directories (`/opt/cleanuparr/config`)
2. Detect architecture (amd64/arm64)
3. Query GitHub API for latest release
4. Download matching `Cleanuparr-*-linux-{arch}.zip`
5. Extract to `/opt/cleanuparr/`
6. Make binary executable
7. Create config file with allocated port and base path
8. Set ownership to master user

**Dependencies:** `unzip`

## Systemd Service

```ini
[Unit]
Description=Cleanuparr Daemon
After=syslog.target network.target

[Service]
User=<master_user>
Group=<master_user>
Type=simple
WorkingDirectory=/opt/cleanuparr
ExecStart=/opt/cleanuparr/Cleanuparr
TimeoutStopSec=20
KillMode=process
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

`WorkingDirectory` ensures the binary finds its `config/` folder.

## Nginx Configuration

```nginx
location /cleanuparr {
    return 301 /cleanuparr/;
}

location ^~ /cleanuparr/ {
    proxy_pass http://127.0.0.1:<port>/cleanuparr/;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_redirect off;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $http_connection;

    auth_basic "What's the password?";
    auth_basic_user_file /etc/htpasswd.d/htpasswd.<user>;
}

location ^~ /cleanuparr/api {
    auth_request off;
    proxy_pass http://127.0.0.1:<port>/cleanuparr/api;
}
```

API endpoint bypasses htpasswd auth for external integrations.

## Removal Flow

1. Check lock file exists (unless `--force`)
2. Prompt: "Would you like to purge the configuration?" [N]
3. Stop and disable systemd service
4. Remove service file, reload daemon
5. Remove files:
   - If purging: `rm -rf /opt/cleanuparr`
   - If not: `rm -f /opt/cleanuparr/Cleanuparr` (keeps config/)
6. Remove nginx config, reload nginx
7. Unregister from panel
8. Clear swizdb entry
9. Remove lock file

## Panel Registration

```bash
panel_register_app \
    "cleanuparr" \
    "Cleanuparr" \
    "/cleanuparr" \
    "" \
    "cleanuparr" \
    "cleanuparr" \
    "https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/cleanuparr.png" \
    "true"
```

## State Storage (swizdb)

- `cleanuparr/owner` - Owner username

## Environment Variables

- `CLEANUPARR_OWNER` - Override owner username (defaults to master user)
