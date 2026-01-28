# Lingarr Installer Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create a Swizzin installer script for Lingarr that manages a Docker Compose deployment with systemd, nginx, and panel integration.

**Architecture:** Docker Compose wrapped by systemd for lifecycle management. Auto-discovers Sonarr/Radarr media paths and API credentials from existing installations. Follows the same conventions as `cleanuparr.sh` and `notifiarr.sh` for nginx, panel registration, and removal.

**Tech Stack:** Bash, Docker Compose, systemd, nginx, SQLite (for querying arr root folders)

---

## Design Decisions

| Decision            | Choice                                     | Rationale                                                        |
| ------------------- | ------------------------------------------ | ---------------------------------------------------------------- |
| Distribution        | Docker Compose                             | Only available method                                            |
| Docker prerequisite | Auto-install if missing                    | Consistent with uv auto-install pattern                          |
| Database            | SQLite only                                | Single-user tool, zero setup                                     |
| Media paths         | Auto-discover from Sonarr/Radarr + confirm | Matches root folders, multi-instance aware                       |
| Sonarr/Radarr API   | Auto-discover silently                     | Technical values, no reason to override                          |
| LibreTranslate      | Not included                               | User configures translation service in web UI                    |
| Nginx               | Location-based at `/lingarr/`              | Consistent with utility apps                                     |
| Port                | Dynamic via `port 10000 12000`             | Standard Swizzin allocation                                      |
| Icon                | Custom from selfhst CDN                    | `https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/lingarr.png` |
| Container user      | Master user UID:GID                        | File permission consistency                                      |

## File Layout

| Path                                  | Purpose                    |
| ------------------------------------- | -------------------------- |
| `/opt/lingarr/docker-compose.yml`     | Compose file               |
| `/opt/lingarr/config/`                | Lingarr config + SQLite DB |
| `/etc/nginx/apps/lingarr.conf`        | Reverse proxy              |
| `/etc/systemd/system/lingarr.service` | Systemd wrapper            |
| `/install/.lingarr.lock`              | Swizzin lock file          |

---

### Task 1: Script scaffold and variables

**Files:**

- Create: `lingarr.sh`

**Step 1: Create `lingarr.sh` with header, sources, panel helper, and app variables**

Follow the exact pattern from `cleanuparr.sh`. The script header, Swizzin sources, `_load_panel_helper()`, log setup, and app variables section.

```bash
#!/bin/bash
# lingarr installer
# STiXzoOR 2025
# Usage: bash lingarr.sh [--update|--remove [--force]|--register-panel]

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils
```

App variables:

```bash
app_name="lingarr"
app_port=$(port 10000 12000)
app_servicefile="$app_name.service"
app_dir="/opt/$app_name"
app_configdir="$app_dir/config"
app_lockname="$app_name"
app_baseurl="$app_name"
app_icon_name="$app_name"
app_icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/lingarr.png"
```

Include the full `_load_panel_helper()` function identical to `cleanuparr.sh`.

Owner resolution pattern:

```bash
if ! LINGARR_OWNER="$(swizdb get "$app_name/owner" 2>/dev/null)"; then
    LINGARR_OWNER="$(_get_master_username)"
fi
user="$LINGARR_OWNER"
app_group="$user"
```

**Step 2: Add flag parsing and main flow at bottom of file**

Handle flags: `--update`, `--remove [--force]`, `--register-panel`, and default install flow.

```bash
# Handle --remove flag
if [ "$1" = "--remove" ]; then
    _remove_lingarr "$2"
fi

# Handle --update flag
if [ "$1" = "--update" ]; then
    _update_lingarr
fi

# Handle --register-panel flag
if [ "$1" = "--register-panel" ]; then
    # ... same pattern as cleanuparr.sh
fi

# Check if already installed
if [ -f "/install/.$app_lockname.lock" ]; then
    echo_info "${app_name^} is already installed"
else
    if [ -n "$LINGARR_OWNER" ]; then
        echo_info "Setting ${app_name^} owner = $LINGARR_OWNER"
        swizdb set "$app_name/owner" "$LINGARR_OWNER"
    fi

    _install_docker
    _discover_media_paths
    _discover_arr_api
    _install_lingarr
    _systemd_lingarr
    _nginx_lingarr
fi

# Panel registration (runs on both fresh install and re-run)
_load_panel_helper
if command -v panel_register_app >/dev/null 2>&1; then
    panel_register_app \
        "$app_name" \
        "Lingarr" \
        "/$app_baseurl" \
        "" \
        "$app_name" \
        "$app_icon_name" \
        "$app_icon_url" \
        "true"
fi

touch "/install/.$app_lockname.lock"
echo_success "${app_name^} installed"
```

**Step 3: Commit**

```bash
git add lingarr.sh
git commit -m "feat: add lingarr installer scaffold with variables and flag parsing"
```

---

### Task 2: Docker installation function

**Files:**

- Modify: `lingarr.sh`

**Step 1: Add `_install_docker()` function**

This function checks for Docker and Docker Compose, installing them if missing. Uses Docker's official apt repository method.

```bash
_install_docker() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        echo_info "Docker and Docker Compose already installed"
        return 0
    fi

    echo_progress_start "Installing Docker"

    # Install prerequisites
    apt_install ca-certificates curl gnupg

    # Add Docker's official GPG key
    install -m 0755 -d /etc/apt/keyrings
    if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
        curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg | \
            gpg --dearmor -o /etc/apt/keyrings/docker.gpg >>"$log" 2>&1
        chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    # Add Docker apt repository
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Install Docker Engine + Compose plugin
    apt-get update >>"$log" 2>&1
    apt_install docker-ce docker-ce-cli containerd.io docker-compose-plugin

    # Enable and start Docker
    systemctl enable --now docker >>"$log" 2>&1

    echo_progress_done "Docker installed"
}
```

**Step 2: Commit**

```bash
git add lingarr.sh
git commit -m "feat(lingarr): add Docker auto-installation"
```

---

### Task 3: Media path discovery

**Files:**

- Modify: `lingarr.sh`

**Step 1: Add `_discover_media_paths()` function**

Scans for Sonarr/Radarr lock files (base and multi-instance), queries their SQLite databases for root folder paths, deduplicates, and presents for confirmation.

Lock file conventions:

- Base: `/install/.sonarr.lock`, `/install/.radarr.lock`
- Multi-instance: `/install/.sonarr_*.lock`, `/install/.radarr_*.lock` (underscores)

Config dir conventions:

- Base Sonarr: `/home/<user>/.config/Sonarr/` (capital S)
- Base Radarr: `/home/<user>/.config/Radarr/` (capital R)
- Multi-instance: `/home/<user>/.config/sonarr-<name>/`, `/home/<user>/.config/radarr-<name>/` (lowercase, hyphens)

The function uses the same SQLite query pattern from `backup/swizzin-backup.sh:247`:

```bash
sqlite3 "$db" "SELECT Path FROM RootFolders;" 2>/dev/null
```

Discovery logic:

1. For each lock file found, derive the config directory name
2. Find the `.db` file in that config directory
3. Query `RootFolders` table for paths
4. Collect all unique paths into `MEDIA_PATHS` array
5. Display discovered paths and ask user to confirm
6. Allow user to add additional paths or remove discovered ones
7. If no paths discovered, prompt user to enter paths manually

Store results in a global array `MEDIA_PATHS=()` and a parallel array `MEDIA_MOUNT_NAMES=()` for the container volume mount targets (e.g., path `/mnt/media/movies` maps to `/movies` inside container based on the last directory component, deduplicating mount names if needed).

**Step 2: Commit**

```bash
git add lingarr.sh
git commit -m "feat(lingarr): add Sonarr/Radarr media path auto-discovery"
```

---

### Task 4: Arr API discovery

**Files:**

- Modify: `lingarr.sh`

**Step 1: Add `_discover_arr_api()` function**

Reads Sonarr/Radarr `config.xml` files to extract API keys and ports. Uses the same lock file scanning approach as `_discover_media_paths()`.

Config XML format (both Sonarr and Radarr):

```xml
<Config>
  <Port>8989</Port>
  <ApiKey>abc123...</ApiKey>
  ...
</Config>
```

Extract values with grep/sed (no XML parser dependency):

```bash
local api_key port
api_key=$(grep -oP '<ApiKey>\K[^<]+' "$config_xml" 2>/dev/null)
port=$(grep -oP '<Port>\K[^<]+' "$config_xml" 2>/dev/null)
```

Priority order:

1. Base Sonarr/Radarr instance (if installed)
2. First multi-instance found (if no base)

Store in global variables: `SONARR_URL`, `SONARR_API_KEY`, `RADARR_URL`, `RADARR_API_KEY`.

Only set environment variables for apps that are actually installed. Don't error if neither is found — Lingarr can still be configured manually via web UI.

**Step 2: Commit**

```bash
git add lingarr.sh
git commit -m "feat(lingarr): add Sonarr/Radarr API credential auto-discovery"
```

---

### Task 5: Docker Compose install function

**Files:**

- Modify: `lingarr.sh`

**Step 1: Add `_install_lingarr()` function**

Creates the app directory, generates `docker-compose.yml`, pulls the image, and starts the container.

```bash
_install_lingarr() {
    mkdir -p "$app_configdir"
    chown -R "$user":"$user" "$app_dir"

    # Get user UID:GID for container
    local uid gid
    uid=$(id -u "$user")
    gid=$(id -g "$user")

    # Build volume mounts
    local volumes=""
    volumes+="      - ${app_configdir}:/app/config\n"
    for i in "${!MEDIA_PATHS[@]}"; do
        volumes+="      - ${MEDIA_PATHS[$i]}:/${MEDIA_MOUNT_NAMES[$i]}\n"
    done

    # Build environment variables
    local env_vars=""
    env_vars+="      - ASPNETCORE_URLS=http://+:9876\n"
    env_vars+="      - DB_CONNECTION=sqlite\n"
    if [ -n "${SONARR_URL:-}" ]; then
        env_vars+="      - SONARR_URL=${SONARR_URL}\n"
        env_vars+="      - SONARR_API_KEY=${SONARR_API_KEY}\n"
    fi
    if [ -n "${RADARR_URL:-}" ]; then
        env_vars+="      - RADARR_URL=${RADARR_URL}\n"
        env_vars+="      - RADARR_API_KEY=${RADARR_API_KEY}\n"
    fi

    echo_progress_start "Generating Docker Compose configuration"
    cat > "$app_dir/docker-compose.yml" <<COMPOSE
services:
  lingarr:
    image: lingarr/lingarr:latest
    container_name: lingarr
    restart: unless-stopped
    user: "${uid}:${gid}"
    ports:
      - "127.0.0.1:${app_port}:9876"
    environment:
$(echo -e "$env_vars" | sed '/^$/d')
    volumes:
$(echo -e "$volumes" | sed '/^$/d')
COMPOSE
    echo_progress_done "Docker Compose configuration generated"

    # Pull and start
    echo_progress_start "Pulling Lingarr Docker image"
    docker compose -f "$app_dir/docker-compose.yml" pull >>"$log" 2>&1 || {
        echo_error "Failed to pull Docker image"
        exit 1
    }
    echo_progress_done "Docker image pulled"

    echo_progress_start "Starting Lingarr container"
    docker compose -f "$app_dir/docker-compose.yml" up -d >>"$log" 2>&1 || {
        echo_error "Failed to start container"
        exit 1
    }
    echo_progress_done "Lingarr container started"
}
```

Note: Port binding uses `127.0.0.1:${app_port}:9876` to only listen on localhost (nginx handles external access). Store `app_port` in swizdb for retrieval on re-runs: `swizdb set "$app_name/port" "$app_port"`.

**Step 2: Commit**

```bash
git add lingarr.sh
git commit -m "feat(lingarr): add Docker Compose generation and container startup"
```

---

### Task 6: Systemd service

**Files:**

- Modify: `lingarr.sh`

**Step 1: Add `_systemd_lingarr()` function**

```bash
_systemd_lingarr() {
    echo_progress_start "Installing systemd service"
    cat > "/etc/systemd/system/$app_servicefile" <<EOF
[Unit]
Description=Lingarr (Subtitle Translation)
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${app_dir}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF

    systemctl -q daemon-reload
    systemctl enable -q "$app_servicefile"
    echo_progress_done "Systemd service installed and enabled"
}
```

Note: Don't use `enable --now` since the container is already running from `_install_lingarr()`. Just enable for boot persistence.

**Step 2: Commit**

```bash
git add lingarr.sh
git commit -m "feat(lingarr): add systemd service wrapper for Docker Compose"
```

---

### Task 7: Nginx reverse proxy

**Files:**

- Modify: `lingarr.sh`

**Step 1: Add `_nginx_lingarr()` function**

Follow the `cleanuparr.sh` nginx pattern but add WebSocket headers for SignalR.

```bash
_nginx_lingarr() {
    if [[ -f /install/.nginx.lock ]]; then
        echo_progress_start "Configuring nginx"
        cat > /etc/nginx/apps/$app_name.conf <<-NGX
            location /$app_baseurl {
              return 301 /$app_baseurl/;
            }

            location ^~ /$app_baseurl/ {
                proxy_pass http://127.0.0.1:$app_port/;
                proxy_set_header Host \$host;
                proxy_set_header X-Real-IP \$remote_addr;
                proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Host \$host;
                proxy_set_header X-Forwarded-Proto \$scheme;
                proxy_redirect off;
                proxy_http_version 1.1;
                proxy_set_header Upgrade \$http_upgrade;
                proxy_set_header Connection \$http_connection;

                auth_basic "What's the password?";
                auth_basic_user_file /etc/htpasswd.d/htpasswd.${user};
            }

            location ^~ /$app_baseurl/api {
                auth_request off;
                proxy_pass http://127.0.0.1:$app_port/api;
                proxy_set_header Host \$host;
                proxy_set_header X-Real-IP \$remote_addr;
                proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto \$scheme;
            }
        NGX

        systemctl reload nginx
        echo_progress_done "Nginx configured"
    else
        echo_info "$app_name will run on port $app_port"
    fi
}
```

**Step 2: Commit**

```bash
git add lingarr.sh
git commit -m "feat(lingarr): add nginx reverse proxy with WebSocket support"
```

---

### Task 8: Update function

**Files:**

- Modify: `lingarr.sh`

**Step 1: Add `_update_lingarr()` function**

```bash
_update_lingarr() {
    if [ ! -f "/install/.$app_lockname.lock" ]; then
        echo_error "${app_name^} is not installed"
        exit 1
    fi

    echo_progress_start "Pulling latest Lingarr image"
    docker compose -f "$app_dir/docker-compose.yml" pull >>"$log" 2>&1 || {
        echo_error "Failed to pull latest image"
        exit 1
    }
    echo_progress_done "Latest image pulled"

    echo_progress_start "Recreating Lingarr container"
    docker compose -f "$app_dir/docker-compose.yml" up -d >>"$log" 2>&1 || {
        echo_error "Failed to recreate container"
        exit 1
    }
    echo_progress_done "Container recreated"

    # Clean up old images
    docker image prune -f >>"$log" 2>&1 || true

    echo_success "${app_name^} has been updated"
    exit 0
}
```

**Step 2: Commit**

```bash
git add lingarr.sh
git commit -m "feat(lingarr): add --update flag for pulling latest Docker image"
```

---

### Task 9: Remove function

**Files:**

- Modify: `lingarr.sh`

**Step 1: Add `_remove_lingarr()` function**

Follow the exact `cleanuparr.sh` removal pattern, adapted for Docker.

```bash
_remove_lingarr() {
    local force="$1"
    if [ "$force" != "--force" ] && [ ! -f "/install/.$app_lockname.lock" ]; then
        echo_error "${app_name^} is not installed (use --force to override)"
        exit 1
    fi

    echo_info "Removing ${app_name^}..."

    # Ask about purging configuration (skip prompt if --force)
    if [ "$force" = "--force" ]; then
        purgeconfig="true"
    elif ask "Would you like to purge the configuration?" N; then
        purgeconfig="true"
    else
        purgeconfig="false"
    fi

    # Stop and remove container
    echo_progress_start "Stopping Lingarr container"
    docker compose -f "$app_dir/docker-compose.yml" down >>"$log" 2>&1 || true
    echo_progress_done "Container stopped"

    # Remove Docker image
    echo_progress_start "Removing Docker image"
    docker rmi lingarr/lingarr >>"$log" 2>&1 || true
    echo_progress_done "Docker image removed"

    # Remove systemd service
    echo_progress_start "Removing systemd service"
    systemctl stop "$app_servicefile" 2>/dev/null || true
    systemctl disable "$app_servicefile" 2>/dev/null || true
    rm -f "/etc/systemd/system/$app_servicefile"
    systemctl daemon-reload
    echo_progress_done "Service removed"

    # Remove nginx config
    if [ -f "/etc/nginx/apps/$app_name.conf" ]; then
        echo_progress_start "Removing nginx configuration"
        rm -f "/etc/nginx/apps/$app_name.conf"
        systemctl reload nginx 2>/dev/null || true
        echo_progress_done "Nginx configuration removed"
    fi

    # Remove from panel
    _load_panel_helper
    if command -v panel_unregister_app >/dev/null 2>&1; then
        echo_progress_start "Removing from panel"
        panel_unregister_app "$app_name"
        echo_progress_done "Removed from panel"
    fi

    # Purge or keep config
    if [ "$purgeconfig" = "true" ]; then
        echo_progress_start "Purging configuration and data"
        rm -rf "$app_dir"
        echo_progress_done "All files purged"
        swizdb clear "$app_name/owner" 2>/dev/null || true
        swizdb clear "$app_name/port" 2>/dev/null || true
    else
        echo_info "Configuration kept at: $app_configdir"
        # Still remove compose file and non-config files
        rm -f "$app_dir/docker-compose.yml"
    fi

    # Remove lock file
    rm -f "/install/.$app_lockname.lock"

    echo_success "${app_name^} has been removed"
    exit 0
}
```

**Step 2: Commit**

```bash
git add lingarr.sh
git commit -m "feat(lingarr): add --remove flag with config purge option"
```

---

### Task 10: Port persistence and re-run handling

**Files:**

- Modify: `lingarr.sh`

**Step 1: Handle port persistence across re-runs**

The `port 10000 12000` call allocates a new port every time the script runs. For re-runs (when already installed), read the port from swizdb instead. Modify the app variables section:

```bash
# Try to read existing port from swizdb, allocate new one only on fresh install
if _existing_port="$(swizdb get "$app_name/port" 2>/dev/null)" && [ -n "$_existing_port" ]; then
    app_port="$_existing_port"
else
    app_port=$(port 10000 12000)
fi
```

And in `_install_lingarr()`, persist the port:

```bash
swizdb set "$app_name/port" "$app_port"
```

**Step 2: Commit**

```bash
git add lingarr.sh
git commit -m "fix(lingarr): persist port in swizdb to avoid re-allocation on re-runs"
```

---

### Task 11: Final review and cleanup

**Files:**

- Review: `lingarr.sh`

**Step 1: Review the complete script**

Read through the entire file and verify:

- All functions are defined before they're called in the main flow
- Variable quoting is consistent (all variables quoted, braces where needed)
- Bracket style uses `[[ ]]` for conditionals
- Error paths exit cleanly
- `--force` on `--remove` skips all prompts and purges everything
- The `--register-panel` flag works standalone
- Panel registration block runs on both fresh install and re-run

**Step 2: Update CLAUDE.md**

Add the lingarr entry to the Files section and any relevant details to the CLAUDE.md project instructions.

**Step 3: Final commit**

```bash
git add lingarr.sh CLAUDE.md
git commit -m "docs: add lingarr to CLAUDE.md project documentation"
```
