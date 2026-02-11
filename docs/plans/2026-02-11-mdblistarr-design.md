# MDBListarr Installer Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create a Swizzin installer script for MDBListarr that manages a Docker Compose deployment with systemd, nginx (subfolder + subdomain), and panel integration. Auto-discovers Sonarr/Radarr connection details and displays them post-install.

**Architecture:** Docker Compose wrapped by systemd for lifecycle management. Host networking so the container can reach Sonarr/Radarr on localhost. Auto-discovers Sonarr/Radarr instances and prints connection info for the user to enter in the MDBListarr web UI.

**Tech Stack:** Bash, Docker Compose, systemd, nginx

**Relationship to mdblist-sync:** Independent alternative. Both coexist; users pick whichever suits them.

---

## Design Decisions

| Decision              | Choice                                              | Rationale                                                                |
| --------------------- | --------------------------------------------------- | ------------------------------------------------------------------------ |
| Distribution          | Docker Compose                                      | Only available method                                                    |
| Image tag             | `latest`                                            | Current version is 2.2.1; auto-updates on `--update`                     |
| Docker prerequisite   | Auto-install if missing                             | Consistent with Lingarr/LibreTranslate pattern                           |
| Networking            | Host mode                                           | Container needs to reach Sonarr/Radarr on localhost                      |
| Nginx subfolder       | `sub_filter` rewrites                               | App has no native `FORCE_SCRIPT_NAME` or base URL support                |
| Nginx subdomain       | Full support with Let's Encrypt                     | Consistent with Lingarr/LibreTranslate                                   |
| Port                  | Dynamic via `port 10000 12000`                      | Standard Swizzin allocation, passed as `PORT` env var                    |
| Volume                | `/opt/mdblistarr/db` → `/usr/src/db`                | SQLite database persistence                                              |
| Auto-discovery        | Detect Sonarr/Radarr, display connection info       | User copies into web UI; no auto-configuration of mdblistarr itself      |
| Default credentials   | `admin` / `admin` (Django entrypoint)               | Warn user to change password post-install                                |
| Icon                  | `mdblistarr` from selfhst CDN or generic list icon  | Check availability at build time                                         |
| Container user        | Not set (app runs as root inside container)          | Django entrypoint requires root for migrations                           |

## File Layout

| Path                                      | Purpose                    |
| ----------------------------------------- | -------------------------- |
| `/opt/mdblistarr/docker-compose.yml`      | Compose file               |
| `/opt/mdblistarr/db/`                     | SQLite database            |
| `/etc/nginx/apps/mdblistarr.conf`         | Subfolder reverse proxy    |
| `/etc/nginx/sites-available/mdblistarr`   | Subdomain reverse proxy    |
| `/etc/systemd/system/mdblistarr.service`  | Systemd wrapper            |
| `/install/.mdblistarr.lock`               | Swizzin lock file          |

## Nginx Sub-filter Analysis

MDBListarr is a Django app with no `FORCE_SCRIPT_NAME` support. The following URLs need rewriting for subfolder mode, based on analysis of the source templates and views:

**From `layout.html`** — navigation links:
- `href="/"` → Configure page
- `href="/log"` → Log page

**From `index.html`** — form actions and AJAX:
- `action="/"` → all form actions (from `{% url 'home_view' %}`)
- `fetch('/set_active_tab/', ...)` → tab persistence AJAX
- `fetch('/test_radarr_connection/', ...)` → Radarr test AJAX
- `fetch('/test_sonarr_connection/', ...)` → Sonarr test AJAX

**From `views.py`** — redirect headers:
- `HttpResponseRedirect(reverse('home_view'))` → sends `Location: /`

No local static files — CSS/JS loaded from Bootstrap CDN.

---

### Task 1: Script scaffold and variables

**Files:**

- Create: `mdblistarr.sh`

**Step 1: Create `mdblistarr.sh` with header, sources, panel helper, and app variables**

Follow the exact pattern from `lingarr.sh`. The script header, Swizzin sources, `_load_panel_helper()`, log setup, and app variables section.

```bash
#!/bin/bash
# mdblistarr installer
# STiXzoOR 2026
# Usage: bash mdblistarr.sh [--subdomain [--revert]|--update|--remove [--force]|--register-panel]

. /etc/swizzin/sources/globals.sh

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils
```

App variables:

```bash
app_name="mdblistarr"
app_servicefile="$app_name.service"
app_dir="/opt/$app_name"
app_dbdir="$app_dir/db"
app_lockname="$app_name"
app_baseurl="$app_name"
app_icon_name="$app_name"
app_icon_url=""  # Determine during implementation
```

Port resolution (read from swizdb or allocate new):

```bash
if _existing_port="$(swizdb get "$app_name/port" 2>/dev/null)" && [ -n "$_existing_port" ]; then
    app_port="$_existing_port"
else
    app_port=$(port 10000 12000)
fi
```

Owner resolution:

```bash
if ! MDBLISTARR_OWNER="$(swizdb get "$app_name/owner" 2>/dev/null)"; then
    MDBLISTARR_OWNER="$(_get_master_username)"
fi
user="$MDBLISTARR_OWNER"
app_group="$user"
```

Include the full `_load_panel_helper()` function identical to `lingarr.sh`.

**Step 2: Add flag parsing and main flow at bottom of file**

Handle flags: `--subdomain [--revert]`, `--update`, `--remove [--force]`, `--register-panel`, and default install flow.

```bash
# Handle --remove flag
if [[ "$1" = "--remove" ]]; then
    _remove_mdblistarr "$2"
fi

# Handle --update flag
if [[ "$1" = "--update" ]]; then
    _update_mdblistarr
fi

# Handle --subdomain flag
if [[ "$1" = "--subdomain" ]]; then
    if [[ "$2" = "--revert" ]]; then
        _revert_subdomain
    else
        _install_subdomain
    fi
    exit 0
fi

# Handle --register-panel flag
if [[ "$1" = "--register-panel" ]]; then
    # ... same pattern as lingarr.sh
fi

# Check if already installed
if [[ -f "/install/.$app_lockname.lock" ]]; then
    echo_info "${app_name^} is already installed"
else
    _install_docker
    _install_mdblistarr
    _systemd_mdblistarr
    _nginx_mdblistarr
    _discover_arr_instances
fi

# Panel registration (runs on both fresh install and re-run)
_load_panel_helper
if command -v panel_register_app >/dev/null 2>&1; then
    panel_register_app \
        "$app_name" \
        "MDBListarr" \
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
git add mdblistarr.sh
git commit -m "feat: add mdblistarr installer scaffold with variables and flag parsing"
```

---

### Task 2: Docker installation function

**Files:**

- Modify: `mdblistarr.sh`

**Step 1: Add `_install_docker()` function**

Copy the `_install_docker()` function from `lingarr.sh` exactly — it's a generic Docker installation function.

**Step 2: Commit**

```bash
git add mdblistarr.sh
git commit -m "feat(mdblistarr): add Docker auto-installation"
```

---

### Task 3: Docker Compose install function

**Files:**

- Modify: `mdblistarr.sh`

**Step 1: Add `_install_mdblistarr()` function**

Creates the app directory, generates `docker-compose.yml`, pulls the image, and starts the container.

Docker Compose with host networking:

```yaml
services:
  mdblistarr:
    image: linaspurinis/mdblistarr:latest
    container_name: mdblistarr
    restart: unless-stopped
    network_mode: host
    volumes:
      - ${db_path}:/usr/src/db
    environment:
      - PORT=${port}
```

Key points:
- Host networking so container can reach Sonarr/Radarr on localhost
- `PORT` env var sets the Django dev server listen port to the allocated port
- Database volume at `/opt/mdblistarr/db` for persistence
- Persist port in swizdb: `swizdb set "$app_name/port" "$app_port"`
- Persist owner in swizdb: `swizdb set "$app_name/owner" "$user"`

**Step 2: Commit**

```bash
git add mdblistarr.sh
git commit -m "feat(mdblistarr): add Docker Compose generation and container startup"
```

---

### Task 4: Systemd service

**Files:**

- Modify: `mdblistarr.sh`

**Step 1: Add `_systemd_mdblistarr()` function**

Standard oneshot systemd wrapper:

```ini
[Unit]
Description=MDBListarr (MDBList.com Sonarr/Radarr Integration)
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/mdblistarr
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
```

Enable but don't start (container already running from install step).

**Step 2: Commit**

```bash
git add mdblistarr.sh
git commit -m "feat(mdblistarr): add systemd service wrapper"
```

---

### Task 5: Nginx reverse proxy (subfolder)

**Files:**

- Modify: `mdblistarr.sh`

**Step 1: Add `_nginx_mdblistarr()` function**

Subfolder mode with `sub_filter` rewrites since the app has no native base URL support:

```nginx
location /mdblistarr {
    return 301 /mdblistarr/;
}

location ^~ /mdblistarr/ {
    proxy_pass http://127.0.0.1:$port/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $http_connection;

    # Rewrite redirect headers (Django HttpResponseRedirect)
    proxy_redirect / /mdblistarr/;

    # Rewrite response body (no FORCE_SCRIPT_NAME support)
    proxy_set_header Accept-Encoding "";
    sub_filter_once off;
    sub_filter_types text/html text/javascript application/javascript;

    # Navigation links (layout.html)
    sub_filter 'href="/"' 'href="/mdblistarr/"';
    sub_filter 'href="/log"' 'href="/mdblistarr/log"';

    # Form actions (index.html — Django {% url 'home_view' %} resolves to /)
    sub_filter 'action="/"' 'action="/mdblistarr/"';

    # AJAX endpoints (index.html JavaScript)
    sub_filter "'/set_active_tab/'" "'/mdblistarr/set_active_tab/'";
    sub_filter "'/test_radarr_connection/'" "'/mdblistarr/test_radarr_connection/'";
    sub_filter "'/test_sonarr_connection/'" "'/mdblistarr/test_sonarr_connection/'";

    auth_basic "What's the password?";
    auth_basic_user_file /etc/htpasswd.d/htpasswd.${user};
}
```

**Step 2: Commit**

```bash
git add mdblistarr.sh
git commit -m "feat(mdblistarr): add nginx subfolder proxy with sub_filter rewrites"
```

---

### Task 6: Subdomain support

**Files:**

- Modify: `mdblistarr.sh`

**Step 1: Add subdomain functions**

Follow the Lingarr/LibreTranslate subdomain pattern:

- `_get_domain()` / `_prompt_domain()` — domain management with swizdb
- `_prompt_le_mode()` — interactive vs automated Let's Encrypt
- `_get_install_state()` — detect current state (not_installed/installed/subdomain)
- `_install_subdomain()` — create nginx sites-available config with HTTP→HTTPS redirect, LE cert, proxy to `127.0.0.1:$port` (no sub_filter needed at root), Organizr frame-ancestors CSP header. Remove subfolder config. Exclude from Organizr auth.
- `_revert_subdomain()` — remove subdomain config, restore subfolder config, re-add Organizr auth

Environment variables:
- `MDBLISTARR_DOMAIN` — domain for subdomain mode
- `MDBLISTARR_LE_INTERACTIVE` — Let's Encrypt interactive mode (yes/no)
- `MDBLISTARR_LE_HOSTNAME` — override LE hostname (for wildcards)

**Step 2: Commit**

```bash
git add mdblistarr.sh
git commit -m "feat(mdblistarr): add subdomain support with Let's Encrypt"
```

---

### Task 7: Sonarr/Radarr auto-discovery

**Files:**

- Modify: `mdblistarr.sh`

**Step 1: Add `_discover_arr_instances()` function**

Scans for installed Sonarr/Radarr instances (including multi-instance variants) and displays their connection details.

Lock file conventions:
- Base: `/install/.sonarr.lock`, `/install/.radarr.lock`
- Multi-instance: `/install/.sonarr_*.lock`, `/install/.radarr_*.lock`

Config dir conventions:
- Base Sonarr: `/home/<user>/.config/Sonarr/` (capital S)
- Base Radarr: `/home/<user>/.config/Radarr/` (capital R)
- Multi-instance: `/home/<user>/.config/sonarr-<name>/`, `/home/<user>/.config/radarr-<name>/` (lowercase, hyphens)

Extract API key and port from `config.xml`:

```bash
api_key=$(grep -oP '<ApiKey>\K[^<]+' "$config_xml" 2>/dev/null)
port=$(grep -oP '<Port>\K[^<]+' "$config_xml" 2>/dev/null)
```

Output format:

```
Detected Sonarr/Radarr instances:
  sonarr:       http://127.0.0.1:8989  API: abc123...
  sonarr-anime: http://127.0.0.1:8990  API: def456...
  radarr:       http://127.0.0.1:7878  API: ghi789...

Enter these in the MDBListarr web UI to connect your instances.
```

Also print:
```
MDBListarr is now available at https://yourserver/mdblistarr/
Default credentials: admin / admin — change this password!
```

**Step 2: Commit**

```bash
git add mdblistarr.sh
git commit -m "feat(mdblistarr): add Sonarr/Radarr auto-discovery with connection info display"
```

---

### Task 8: Update function

**Files:**

- Modify: `mdblistarr.sh`

**Step 1: Add `_update_mdblistarr()` function**

Standard Docker update pattern:

```bash
docker compose -f "$app_dir/docker-compose.yml" pull
docker compose -f "$app_dir/docker-compose.yml" up -d
docker image prune -f
```

**Step 2: Commit**

```bash
git add mdblistarr.sh
git commit -m "feat(mdblistarr): add --update flag for pulling latest Docker image"
```

---

### Task 9: Remove function

**Files:**

- Modify: `mdblistarr.sh`

**Step 1: Add `_remove_mdblistarr()` function**

Follow the Lingarr removal pattern:

1. Ask about purging configuration (skip if `--force`)
2. Stop and remove container: `docker compose down`
3. Remove Docker image: `docker rmi linaspurinis/mdblistarr`
4. Remove systemd service
5. Remove nginx config (both subfolder and subdomain)
6. Unregister from panel
7. Purge or keep config based on user choice
8. Clear swizdb entries (`$app_name/owner`, `$app_name/port`, `$app_name/domain`)
9. Remove lock file

**Step 2: Commit**

```bash
git add mdblistarr.sh
git commit -m "feat(mdblistarr): add --remove flag with config purge option"
```

---

### Task 10: Backup integration

**Files:**

- Modify: backup system definitions (check existing backup config for the pattern)

**Step 1: Add mdblistarr to backup definitions**

Add `/opt/mdblistarr/db/` to the backup system so the SQLite database is preserved.

**Step 2: Commit**

```bash
git add backup/
git commit -m "feat(backup): add mdblistarr database to backup definitions"
```

---

### Task 11: Final review and documentation

**Files:**

- Review: `mdblistarr.sh`
- Modify: `CLAUDE.md`

**Step 1: Review the complete script**

Verify:
- All functions defined before called in main flow
- Variable quoting consistent (`"$var"`, `"${user}"`)
- Bracket style uses `[[ ]]` for conditionals
- Error paths exit cleanly
- `--force` on `--remove` skips all prompts and purges everything
- `--register-panel` works standalone
- Panel registration runs on both fresh install and re-run
- Subdomain mode switching works correctly
- Sub-filter rewrites cover all app URLs

**Step 2: Update CLAUDE.md**

Add mdblistarr entry to the App-Specific Documentation section.

**Step 3: Final commit**

```bash
git add mdblistarr.sh CLAUDE.md
git commit -m "docs: add mdblistarr to project documentation"
```
