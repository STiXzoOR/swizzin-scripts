# Sonarr/Radarr Multi-Instance Scripts Design

## Overview

Two self-contained scripts (`sonarr.sh` and `radarr.sh`) that install the base app and manage multiple named instances (e.g., 4k, anime, kids).

## Commands

```bash
sonarr.sh                      # Install base if needed, then add instances interactively
sonarr.sh --add                # Add instance directly (requires base installed)
sonarr.sh --remove [name]      # Remove instance(s) - interactive if no name
sonarr.sh --remove name --force # Remove without prompts, purge config
sonarr.sh --list               # List all instances with ports
```

## Install Flow

1. Check if base app installed (`/install/.sonarr.lock`)
2. If not installed → run `box install sonarr`
3. Ask "Would you like to add another instance? (y/n)"
4. If yes:
   - Prompt for instance name (alphanumeric only, validated unique)
   - Allocate port via `port 10000 12000`
   - Create config directory, systemd service, nginx config, panel entry
   - Create lock file `/install/.sonarr-<name>.lock`
5. Loop: Ask "Add another instance?" until user says no

## Naming Convention

| Component | Pattern | Example |
|-----------|---------|---------|
| Service | `sonarr-<name>.service` | `sonarr-4k.service` |
| Config dir | `/home/<user>/.config/sonarr-<name>/` | `/home/user/.config/sonarr-4k/` |
| Nginx | `/etc/nginx/apps/sonarr-<name>.conf` | `/etc/nginx/apps/sonarr-4k.conf` |
| URL path | `/sonarr-<name>/` | `/sonarr-4k/` |
| Lock file | `/install/.sonarr-<name>.lock` | `/install/.sonarr-4k.lock` |

## Instance Name Validation

- Alphanumeric only (a-z, 0-9)
- Automatically converted to lowercase
- Cannot be empty
- Cannot conflict with existing instance (check lock file)
- Reserved words blocked: "base"

## Instance Creation Details

### Config XML (`/home/<user>/.config/sonarr-<name>/config.xml`)

```xml
<Config>
  <LogLevel>info</LogLevel>
  <UpdateMechanism>BuiltIn</UpdateMechanism>
  <Branch>main</Branch>
  <BindAddress>127.0.0.1</BindAddress>
  <Port>{allocated_port}</Port>
  <SslPort>9898</SslPort>
  <EnableSsl>False</EnableSsl>
  <LaunchBrowser>False</LaunchBrowser>
  <AuthenticationMethod>None</AuthenticationMethod>
  <UrlBase>sonarr-{name}</UrlBase>
  <UpdateAutomatically>False</UpdateAutomatically>
</Config>
```

### Systemd Service

```ini
[Unit]
Description=Sonarr {Name} Instance
After=network.target

[Service]
User={user}
Group={user}
UMask=0002
Type=simple
ExecStart=/opt/Sonarr/Sonarr -nobrowser -data=/home/{user}/.config/sonarr-{name}
TimeoutStopSec=20
KillMode=process
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

### Nginx Config

```nginx
location ^~ /sonarr-{name} {
    proxy_pass http://127.0.0.1:{port};
    proxy_set_header Host $proxy_host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_redirect off;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $http_connection;
    auth_basic "What's the password?";
    auth_basic_user_file /etc/htpasswd.d/htpasswd.{user};
}

location ^~ /sonarr-{name}/api {
    auth_basic off;
    proxy_pass http://127.0.0.1:{port};
}
```

### Panel Registration

```python
class sonarr_{name}_meta:
    name = "sonarr-{name}"
    pretty_name = "Sonarr {Name}"
    baseurl = "/sonarr-{name}"
    systemd = "sonarr-{name}"
    check_theD = False
    img = "sonarr"
```

## Removal Flow

### With name: `sonarr.sh --remove 4k [--force]`

1. Check `/install/.sonarr-4k.lock` exists
2. If not found, error and exit
3. Stop and disable service
4. Remove systemd service file
5. Remove nginx config, reload nginx
6. Remove panel meta class from profiles.py
7. If `--force`: purge config directory
   Else: prompt "Purge configuration? (y/n)"
8. Remove lock file

### Without name: `sonarr.sh --remove [--force]`

1. Scan for `/install/.sonarr-*.lock` files (excluding base)
2. If none found, message "No instances installed"
3. Show whiptail checklist with all instances
4. Remove selected instances using steps above
5. `--force` skips config purge prompts

## Base Removal Protection

- Base app cannot be removed via this script
- When instances exist, base removal would orphan them
- User must remove all instances before running `box remove sonarr`
- Document this behavior in README

## List Flow (`--list`)

1. Check for base: `/install/.sonarr.lock`
2. Scan for instances: `/install/.sonarr-*.lock`
3. For each instance, read port from config.xml
4. Print formatted list:
   ```
   Sonarr Instances:
     sonarr (base)     - port 8989
     sonarr-4k         - port 10234
     sonarr-anime      - port 10567
   ```

## Sonarr vs Radarr Differences

| Variable | Sonarr | Radarr |
|----------|--------|--------|
| `app_name` | sonarr | radarr |
| `app_binary` | /opt/Sonarr/Sonarr | /opt/Radarr/Radarr |
| `base_port` | 8989 | 7878 |
| `config_branch` | main | master |

## Pre-flight Checks

- nginx installed (`/install/.nginx.lock`)
- For adding instances: base app installed
- Binary exists at expected path

## Error Messages

- Instance name taken: "Instance 'sonarr-4k' already exists"
- Base not installed: "Install base Sonarr first: box install sonarr"
- Instance not found: "Instance 'sonarr-4k' not found"
- Invalid name: "Instance name must be alphanumeric only"
