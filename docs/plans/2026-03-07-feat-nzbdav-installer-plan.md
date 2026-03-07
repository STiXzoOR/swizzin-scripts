---
title: "feat: Add NZBDav Docker installer"
type: feat
status: active
date: 2026-03-07
deepened: 2026-03-07
origin: docs/brainstorms/2026-03-07-nzbdav-brainstorm.md
---

# feat: Add NZBDav Docker Installer

## Enhancement Summary

**Deepened on:** 2026-03-07
**Sections enhanced:** 10
**Research sources:** Web (NZBDav GitHub, setup guide, entrypoint.sh, Dockerfile, Issue #227), codebase (zurg.sh lines 253-1105, mdblistarr.sh, Docker template), spec flow analysis, rclone/systemd/FUSE best practices, security hardening patterns

### Key Improvements
1. Resolved chicken-and-egg problem with `--setup-rclone` subcommand (rclone mount deferred until after web UI setup)
2. Confirmed `sub_filter` required — NZBDav has no base URL support, reuse zurg.sh `sub_filter` rules
3. Security: `network_mode: host` exposes port on `0.0.0.0` — added UFW rule requirement
4. Health check confirmed at `/health` endpoint (from entrypoint.sh analysis, NOT `/health` on port 3000 directly — backend health on port 8080, proxied by frontend)
5. rclone mount systemd: `Type=notify` with `ExecStartPre` readiness probe (not fixed sleep)
6. Removal ordering: unmount rclone FIRST, then stop Docker (prevents hung FUSE mounts)
7. rclone.conf section removal on purge (sed-based, preserves other remotes — zurg.sh:444-452 pattern)
8. FUSE kernel module check before install (`modinfo fuse`)

## Overview

Create a Docker-based Swizzin installer for NZBDav, a C#/.NET WebDAV server that mounts NZB documents as a virtual filesystem for Usenet streaming. NZBDav provides a SABnzbd-compatible API (drop-in download client for Sonarr/Radarr) and a WebDAV endpoint mounted via rclone so Plex/Jellyfin can stream content directly from Usenet providers without local storage.

This is a **hybrid installer**: Docker container + host-side rclone WebDAV mount service, following the established zurg.sh pattern.

(see brainstorm: `docs/brainstorms/2026-03-07-nzbdav-brainstorm.md`)

## Problem Statement / Motivation

Usenet users need a way to stream content from their Usenet provider without downloading entire files to disk. NZBDav fills this gap by acting as a SABnzbd-compatible download client that "downloads" are actually WebDAV mounts. Combined with rclone, media servers can stream directly from the Usenet provider, enabling an "infinite library" with zero storage footprint.

## Proposed Solution

A `nzbdav.sh` installer with two systemd services:

| Service | Type | Purpose |
|---------|------|---------|
| `nzbdav.service` | oneshot (Docker Compose) | Runs NZBDav container |
| `rclone-nzbdav.service` | notify (rclone mount) | Mounts WebDAV to host filesystem |

Single Docker container. `network_mode: host`. Dynamic port allocation. nginx subfolder with API auth bypass. rclone WebDAV mount with FUSE. User-configurable mount point. Display Sonarr/Radarr connection info.

## Technical Considerations

### Architecture

- **Single container**: NZBDav is self-contained — C# backend (port 8080 internal) + Node.js frontend (port 3000 exposed), SQLite config at `/config/db.sqlite`
- **Networking**: `network_mode: host` (matches mdblistarr/lingarr pattern — arr stack runs natively on host, not in Docker)
- **Port**: Dynamic via `port 10000 12000` (default 3000 conflicts with Grafana, Node apps, etc.)
- **Web UI**: Full admin interface — settings, queue, DAV explorer, health monitor
- **rclone mount**: Host-side FUSE mount of NZBDav's WebDAV endpoint, separate systemd service
- **User mapping**: `PUID`/`PGID` environment variables (LinuxServer.io-style entrypoint with `su-exec`, NOT Docker `user:` directive)

### NZBDav Internal Architecture

From the Dockerfile and entrypoint.sh analysis:

```
Container port 3000 (frontend - Node.js)
   ↕ (proxies to)
Container port 8080 (backend - C#/.NET)
   ↕ (serves)
WebDAV endpoint + SABnzbd API + Health check at /health
```

- `BACKEND_URL` defaults to `http://localhost:8080` (internal, not exposed)
- `FRONTEND_BACKEND_API_KEY` auto-generated on each container start
- `CONFIG_PATH` env var for config directory (defaults to `/config`)
- Database migration runs on every startup (`./NzbWebDAV --db-migration`)
- Health check: backend at `${BACKEND_URL}/health` (HTTP 200)

#### Research Insights

**Health check chain:** The frontend at port 3000 proxies `/health` to the backend at port 8080. Docker healthcheck should target `http://localhost:3000/health` (NOT 8080, which is internal). The `ExecStartPre` readiness probe in the rclone service should also target port 3000 since that's the externally accessible port.

**Database migration safety:** The `--db-migration` flag runs on every container start. This is idempotent by design (EF Core migrations). However, if the container crashes mid-migration, SQLite WAL journaling protects against corruption. No special handling needed.

**`FRONTEND_BACKEND_API_KEY` regeneration:** This key changes on every container restart. It's internal only (frontend↔backend communication). No external consumer depends on it, so restarts are safe.

### Chicken-and-Egg: rclone Mount vs. First-Run Configuration

**Critical design issue**: NZBDav has NO environment variable support for settings (GitHub Issue #227 open). WebDAV credentials and Usenet provider details are configured exclusively through the web UI and stored in SQLite. This means:

1. Fresh install → container starts → WebDAV endpoint has no credentials → rclone cannot authenticate
2. User must visit web UI first → configure Usenet provider + WebDAV password
3. Only then can rclone mount succeed

**Solution**: Install `rclone-nzbdav.service` but do NOT enable it on fresh install. Post-install instructions tell the user to:
1. Configure NZBDav via web UI
2. Set WebDAV password in Settings > WebDAV
3. Run the provided command to configure rclone credentials and start the mount

```bash
# Post-install script or manual command:
_finalize_rclone() {
    echo_query "Enter the WebDAV password you set in NZBDav Settings > WebDAV:"
    read -rs webdav_pass </dev/tty
    echo ""

    # Generate obscured password for rclone
    local obscured
    obscured=$(rclone obscure "$webdav_pass") || {
        echo_error "Failed to obscure password"
        return 1
    }

    # Write rclone.conf
    cat >"${app_dir}/rclone.conf" <<RCLONE
[nzbdav]
type = webdav
url = http://127.0.0.1:${app_port}/
vendor = other
user = admin
pass = ${obscured}
RCLONE
    chmod 600 "${app_dir}/rclone.conf"
    chown "${user}:${user}" "${app_dir}/rclone.conf"

    # Enable and start rclone mount
    systemctl enable rclone-nzbdav.service
    systemctl start rclone-nzbdav.service
}
```

On **re-run** (rclone.conf already exists): skip the prompt, just restart the mount service.

### Compose File Structure

```yaml
services:
  nzbdav:
    image: nzbdav/nzbdav:latest
    container_name: nzbdav
    restart: unless-stopped
    network_mode: host
    environment:
      - PUID=<uid>
      - PGID=<gid>
    volumes:
      - /opt/nzbdav/config:/config
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      interval: 60s
      timeout: 5s
      retries: 3
      start_period: 10s
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
```

**Notes:**
- `PUID`/`PGID` (not `user:`) — NZBDav's entrypoint uses `su-exec` to switch to the correct user
- Bind mount at `/opt/nzbdav/config` for backup system compatibility (not named volumes)
- No `/mnt:/mnt` mount — rclone runs on the host, not inside the container
- Health check targets the frontend at port 3000 (which proxies to backend `/health`)
- `network_mode: host` means the app binds to `0.0.0.0:<port>` — nginx + firewall required

#### Research Insights

**No `user:` directive — confirmed:** NZBDav's entrypoint.sh uses `su-exec` to drop from root to `PUID:PGID`. Adding Docker's `user:` directive would conflict — the entrypoint would fail because `su-exec` requires root to switch users. This matches the LinuxServer.io pattern used by Sonarr, Radarr, etc.

**`start_period` tuning:** .NET apps with EF Core migrations can take 5-15s on first start. The `start_period: 10s` is borderline — increase to `30s` for safety on slow VPS instances. This only affects the initial grace period, not ongoing checks.

**UFW firewall rule:** With `network_mode: host`, the dynamic port is directly accessible on all interfaces. Add UFW deny rule during install:
```bash
if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
    ufw deny in on any to any port "$app_port" proto tcp comment "nzbdav - nginx only" >>"$log" 2>&1 || true
fi
```
Remove the UFW rule during `--remove`.

### rclone Mount Service

Following the zurg.sh pattern (`zurg.sh:1014-1060`):

```ini
[Unit]
Description=rclone NZBDav WebDAV mount
After=nzbdav.service
Requires=nzbdav.service

[Service]
Type=notify
User=<user>
Group=<user>
ExecStartPre=/bin/bash -c 'until curl -sf http://127.0.0.1:<port>/health; do sleep 2; done'
ExecStart=/usr/bin/rclone mount nzbdav: <mount_point> \
    --config /opt/nzbdav/rclone.conf \
    --uid <uid> --gid <gid> \
    --allow-other \
    --links \
    --use-cookies \
    --vfs-cache-mode full \
    --buffer-size 0M \
    --vfs-read-ahead 512M \
    --vfs-cache-max-size 20G \
    --vfs-cache-max-age 24h \
    --dir-cache-time 20s
ExecStop=/bin/fusermount -uz <mount_point>
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

**Key design decisions:**
- `ExecStartPre` uses a readiness probe (curl loop) instead of fixed `sleep` — solves boot race and container startup delay
- rclone flags from official NZBDav docs: `--links` (symlink support, requires rclone v1.70.3+), `--use-cookies` (performance), `--buffer-size 0M` (prevent double-caching)
- `--vfs-cache-max-size 20G` — official recommendation. Disk space for VFS cache.
- Mount point: user-configurable, default `/mnt/nzbdav` (prompted during install like zurg.sh `_get_mount_point()`)

#### Research Insights

**`ExecStartPre` timeout guard:** The bare `until curl` loop has no timeout — if the container never becomes healthy, the service hangs forever. Add a max-retry counter:
```bash
ExecStartPre=/bin/bash -c 'for i in $(seq 1 30); do curl -sf http://127.0.0.1:<port>/health && exit 0; sleep 2; done; echo "NZBDav health check timed out after 60s"; exit 1'
```
This caps the wait at 60 seconds (30 retries × 2s). Matches systemd best practice of bounded pre-start checks.

**`Type=notify` vs `Type=simple`:** rclone v1.53+ supports `--sd-notify` which sends `READY=1` to systemd when the mount is established. With `Type=notify`, systemd waits for this signal before considering the service active. This is correct — `Type=simple` would report "active" before the mount is ready, causing race conditions with media servers. Confirmed from zurg.sh:1021.

**rclone version check for `--links`:** The `--links` flag requires rclone v1.70.3+. Add a version check:
```bash
local rclone_ver
rclone_ver=$(rclone version 2>/dev/null | head -1 | grep -oP 'v\K[\d.]+')
if [[ "$(printf '%s\n' "1.70.3" "$rclone_ver" | sort -V | head -1)" != "1.70.3" ]]; then
    echo_warn "rclone $rclone_ver does not support --links (requires v1.70.3+). Symlinks disabled."
    # Omit --links from the mount service
fi
```

**Stale mount detection and recovery:** If the container crashes while the FUSE mount is active, the mount point becomes stale (`Transport endpoint is not connected`). The `--setup-rclone` and `--update` subcommands should check for stale mounts:
```bash
if mountpoint -q "$mount_point" 2>/dev/null || stat "$mount_point" 2>&1 | grep -q "Transport endpoint"; then
    fusermount -uz "$mount_point" 2>/dev/null || true
fi
```

**`--vfs-cache-mode full` disk space warning:** 20GB VFS cache can surprise users on small VPS. Post-install should mention: "rclone VFS cache uses up to 20GB at `~/.cache/rclone/vfs/nzbdav/`. Adjust `--vfs-cache-max-size` in the systemd service if needed."

### FUSE Configuration

```bash
# Install fuse3
app_reqs=("curl" "fuse3")

# Enable user_allow_other for cross-user mount access
if ! grep -q "^user_allow_other" /etc/fuse.conf 2>/dev/null; then
    echo "user_allow_other" >>/etc/fuse.conf
fi
```

Required so Plex/Jellyfin (different user) can access the rclone mount.

#### Research Insights

**FUSE kernel module pre-check:** Some VPS providers (OpenVZ, older LXC) don't have the FUSE kernel module. Check before install:
```bash
if ! modinfo fuse &>/dev/null && ! grep -q fuse /proc/filesystems 2>/dev/null; then
    echo_error "FUSE kernel module not available. rclone mount requires FUSE support."
    echo_info "Contact your VPS provider to enable FUSE, or use a KVM-based VPS."
    exit 1
fi
```

**`fuse3` vs `fuse`:** Modern distros (Ubuntu 22.04+, Debian 12+) ship `fuse3`. Older distros have `fuse`. rclone works with both, but `fuse3` is preferred for better performance and the `--links` flag support. The `app_reqs=("curl" "fuse3")` is correct for target distros.

### Mount Point Configuration

Same pattern as zurg.sh `_get_mount_point()`:

```bash
app_default_mount="/mnt/nzbdav"

_get_mount_point() {
    if [[ -n "${NZBDAV_MOUNT_PATH:-}" ]]; then
        app_mount_point="$NZBDAV_MOUNT_PATH"
        return
    fi

    local existing_mount
    existing_mount=$(swizdb get "nzbdav/mount_point" 2>/dev/null) || true
    local default_mount="${existing_mount:-$app_default_mount}"

    echo_query "Enter NZBDav mount point" "[$default_mount]"
    read -r input_mount </dev/tty

    if [[ -z "$input_mount" ]]; then
        app_mount_point="$default_mount"
    else
        [[ "$input_mount" = /* ]] || { echo_error "Must be absolute path"; exit 1; }
        app_mount_point="$input_mount"
    fi

    # Check if already a mount point
    if mountpoint -q "$app_mount_point" 2>/dev/null; then
        echo_error "Path is already a mount point: $app_mount_point"
        exit 1
    fi

    swizdb set "nzbdav/mount_point" "$app_mount_point"
}
```

### Nginx Configuration

NZBDav does NOT support a base URL path prefix (no env var for it). However, since we use `network_mode: host`, the app is directly accessible. The nginx subfolder needs `sub_filter` for asset path rewriting.

**Important**: Need to investigate whether NZBDav's frontend generates absolute or relative paths. If relative, no `sub_filter` needed. If absolute (e.g., `/assets/`, `/api/`), `sub_filter` is required.

```nginx
location /nzbdav {
    return 301 /nzbdav/;
}

location ^~ /nzbdav/ {
    proxy_pass http://127.0.0.1:<port>/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_redirect off;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $http_connection;

    # sub_filter directives if needed (TBD during implementation)
    # sub_filter_once off;
    # sub_filter '="/' '="/nzbdav/';
    # sub_filter 'href="/' 'href="/nzbdav/';
    # sub_filter 'src="/' 'src="/nzbdav/';

    auth_basic "What's the password?";
    auth_basic_user_file /etc/htpasswd.d/htpasswd.<user>;
}

# SABnzbd API bypass for Sonarr/Radarr
# NZBDav's SABnzbd API is at /api (standard SABnzbd path)
location ^~ /nzbdav/api {
    auth_request off;
    proxy_pass http://127.0.0.1:<port>/api;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

**`auth_request off`** (not `auth_basic off`) — matches codebase pattern and maintains Organizr compatibility.

**Note**: The SABnzbd API uses its own API key authentication (set in NZBDav Settings > SABnzbd). The nginx bypass only removes htpasswd/Organizr auth; the API key still protects the endpoint.

#### Research Insights

**`sub_filter` rules — confirmed required:** NZBDav has no base URL / path prefix support (Issue #227). The frontend generates absolute paths (`/assets/`, `/api/`, etc.). Use the proven zurg.sh `sub_filter` pattern (`zurg.sh:1096-1105`):
```nginx
sub_filter_once off;
sub_filter_types text/html text/css text/javascript application/javascript application/json;
sub_filter 'href="/' 'href="/nzbdav/';
sub_filter 'src="/' 'src="/nzbdav/';
sub_filter 'action="/' 'action="/nzbdav/';
sub_filter 'url(/' 'url(/nzbdav/';
sub_filter '"/api/' '"/nzbdav/api/';
sub_filter "'/api/" "'/nzbdav/api/";
sub_filter 'fetch("/' 'fetch("/nzbdav/';
sub_filter "fetch('/" "fetch('/nzbdav/";
```
This rewrites HTML/CSS/JS responses to prefix all absolute paths with `/nzbdav/`. The `sub_filter_types` line ensures CSS and JS files are also processed (nginx only filters `text/html` by default).

**Narrow the API auth bypass:** The current plan bypasses auth for all of `/nzbdav/api`. NZBDav's SABnzbd API is typically at `/api` with query parameters (`?mode=queue&apikey=...`). Since the SABnzbd API key provides its own authentication, this bypass is safe. However, if NZBDav exposes other API paths (settings, admin), those would also be unprotected by htpasswd. During implementation, verify which paths live under `/api` and consider narrowing to `/nzbdav/api?mode=` if possible.

**WebSocket support:** The config includes `Upgrade` and `Connection` headers. NZBDav's frontend likely uses WebSockets for real-time queue updates. Keep these headers.

### Security

- `network_mode: host` means port is directly accessible — **must** ensure UFW blocks external access or app binds to `127.0.0.1`
- `chmod 600` on `docker-compose.yml` and `rclone.conf` (contain no secrets in compose, but rclone.conf has obscured WebDAV password)
- `chown root:root` on compose file, `chown user:user` on rclone.conf (rclone runs as user)
- `no-new-privileges:true` + `cap_drop: ALL` on container
- WebDAV password read with `read -rs` (silent, no echo)
- rclone password obscured via `rclone obscure` before writing to config
- SABnzbd API key is auto-generated by NZBDav and stored in SQLite — only accessible via web UI

#### Research Insights

**Container security matches codebase standard:** `no-new-privileges:true` + `cap_drop: ALL` is the same hardening applied to StremThru, Zilean, and MediaFusion plans. NZBDav doesn't need any Linux capabilities — it uses `su-exec` in the entrypoint (before cap_drop applies) and doesn't bind privileged ports.

**`read_only: true` consideration:** Unlike StremThru (which only writes to `/app/data`), NZBDav writes to `/config` and may create temp files elsewhere. Do NOT add `read_only: true` without testing — the .NET runtime and Node.js frontend may need writable `/tmp`. If desired, add `tmpfs: ["/tmp"]` but leave the root filesystem writable for safety.

**rclone.conf password obscuration:** `rclone obscure` uses AES-CTR with a fixed key — it's obfuscation, not encryption. It prevents casual shoulder-surfing but won't stop a determined attacker with file access. Combined with `chmod 600`, this provides reasonable protection. Document this limitation in post-install info.

### Sonarr/Radarr Integration (Display Only)

Discover installed arr instances and display connection info:

```bash
_display_arr_info() {
    echo ""
    echo_info "=== Sonarr/Radarr Download Client Setup ==="
    echo_info "Add NZBDav as a SABnzbd download client:"
    echo_info "  Client: SABnzbd"
    echo_info "  Host: 127.0.0.1"
    echo_info "  Port: ${app_port}"
    echo_info "  API Key: (found in NZBDav Settings > SABnzbd)"
    echo ""
    echo_info "Then configure NZBDav's Radarr/Sonarr settings:"
    echo_info "  Go to NZBDav Settings > Radarr/Sonarr"
    echo_info "  Add each instance with its host, port, and API key"
    echo ""

    # Discover and list installed arr instances
    for app in sonarr radarr; do
        if [[ -f "/install/.${app}.lock" ]]; then
            local cfg port base api_key
            for cfg in /home/*/.config/${app^}/config.xml; do
                [[ -f "$cfg" ]] || continue
                port=$(grep -oP '<Port>\K[^<]+' "$cfg" 2>/dev/null) || true
                base=$(grep -oP '<UrlBase>\K[^<]+' "$cfg" 2>/dev/null) || true
                api_key=$(grep -oP '<ApiKey>\K[^<]+' "$cfg" 2>/dev/null) || true
                echo_info "  ${app^}: http://127.0.0.1:${port}${base:+/$base} (API: ${api_key})"
                break
            done
        fi
    done
}
```

No auto-configuration — adding download clients via POST `/api/v3/downloadclient` has no codebase precedent.

#### Research Insights

**Arr discovery pattern:** The `for cfg in /home/*/.config/${app^}/config.xml` pattern matches how mdblistarr.sh discovers arr instances (`mdblistarr.sh:457-526`). Note the `${app^}` capitalize — Sonarr stores config at `~/.config/Sonarr/config.xml`, not `~/.config/sonarr/`. The `break` after first match assumes single-user Swizzin (correct for this project).

**NZBDav bidirectional integration:** Unlike traditional download clients, NZBDav also needs to know about Sonarr/Radarr (for symlink creation and library management). The post-install info should remind users to configure both directions:
1. Add NZBDav as SABnzbd client in each arr app
2. Add each arr app in NZBDav Settings > Radarr/Sonarr

## Acceptance Criteria

- [ ] `nzbdav.sh` installs NZBDav via Docker Compose with `network_mode: host`
- [ ] rclone + fuse3 installed on host
- [ ] User prompted for mount point (default `/mnt/nzbdav`, persisted in swizdb)
- [ ] `rclone-nzbdav.service` created but NOT enabled on fresh install (chicken-and-egg)
- [ ] Post-install instructions guide user through first-run configuration + rclone setup
- [ ] `nzbdav.sh --update` pulls latest image, recreates container, restarts rclone mount if active
- [ ] `nzbdav.sh --remove` unmounts FUSE first, then stops Docker, cleans up both services
- [ ] `nzbdav.sh --remove` with purge removes rclone.conf `[nzbdav]` section (not entire file), mount point, config
- [ ] Nginx subfolder at `/nzbdav` with `auth_request off` for `/nzbdav/api`
- [ ] Panel registration works
- [ ] `swizzin-app-info` updated
- [ ] Sonarr/Radarr instance discovery with connection info displayed
- [ ] Bind mounts at `/opt/nzbdav/` for backup system compatibility
- [ ] `PUID`/`PGID` environment variables (not `user:` directive)
- [ ] Container security: `no-new-privileges`, `cap_drop: ALL`
- [ ] Idempotent: re-running preserves existing config and rclone.conf
- [ ] Unattended install via `NZBDAV_MOUNT_PATH`, `NZBDAV_PORT` env vars

## Implementation Plan

### Phase 1: Core Installer (`nzbdav.sh`)

#### 1.1 Create `nzbdav.sh` (new file)

Based on Docker template + zurg.sh rclone pattern:

- **App variables**: `app_name="nzbdav"`, dynamic port, image `nzbdav/nzbdav:latest`, `app_reqs=("curl" "fuse3")`
- **`_get_mount_point()`**: Prompt with default `/mnt/nzbdav`, env var override, swizdb persistence, mount conflict check
- **`_install_nzbdav()`**: Docker install, compose generation (`network_mode: host`, `PUID`/`PGID`, bind mount), container start
- **`_install_rclone()`**: Install rclone on host (reuse zurg.sh pattern), configure FUSE `user_allow_other`
- **`_systemd_nzbdav()`**: Create TWO services — `nzbdav.service` (Docker oneshot) + `rclone-nzbdav.service` (rclone mount with readiness probe, NOT enabled on fresh install)
- **`_nginx_nzbdav()`**: Subfolder proxy with SABnzbd API auth bypass, `sub_filter` if needed
- **`_finalize_rclone()`**: Prompt for WebDAV password (on re-run or explicit call), write rclone.conf, enable+start mount service
- **`_display_arr_info()`**: Discover Sonarr/Radarr, display connection info
- **`_update_nzbdav()`**: Pull latest image, recreate container, restart rclone mount service if running
- **`_remove_nzbdav()`**: Stop rclone mount FIRST (unmount), then stop Docker, remove both services, remove rclone.conf `[nzbdav]` section, cleanup
- **Cleanup trap**: Extended for Docker container + FUSE unmount + rclone config

#### Research Insights

**Cleanup trap for hybrid installer:** The standard Docker template cleanup trap only handles container cleanup. The hybrid pattern needs an extended trap that also handles FUSE unmount on failure:
```bash
_cleanup() {
    # Standard Docker cleanup
    docker compose -f "${app_dir}/docker-compose.yml" down 2>/dev/null || true
    # FUSE unmount cleanup (if mount was started during install)
    if mountpoint -q "${app_mount_point}" 2>/dev/null; then
        fusermount -uz "${app_mount_point}" 2>/dev/null || true
    fi
    # Remove incomplete systemd services
    rm -f "/etc/systemd/system/rclone-nzbdav.service" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
}
```
This pattern comes from zurg.sh:395-422 (`_cleanup_version_artifacts()`).

**Removal ordering — critical:** Must unmount FUSE BEFORE stopping the Docker container. If Docker stops first, the WebDAV backend disappears and `fusermount -uz` may hang. Order: (1) stop rclone-nzbdav.service, (2) fusermount -uz, (3) stop nzbdav.service, (4) remove containers. This matches zurg.sh:407-415.

**rclone.conf section removal on purge:** Use the exact sed pattern from zurg.sh:447:
```bash
sed -i '/^\[nzbdav\]/,/^\[/{/^\[nzbdav\]/d;/^\[/!d}' "${app_dir}/rclone.conf"
```
Since NZBDav uses its own rclone.conf at `/opt/nzbdav/rclone.conf` (not the user's global `~/.config/rclone/rclone.conf`), it's simpler — just delete the entire file on purge. The section-removal pattern is only needed if sharing a global rclone.conf.

**VFS cache cleanup on purge:** rclone stores VFS cache at `~/.cache/rclone/vfs/nzbdav/`. This can be up to 20GB. Report cache size before deletion (zurg.sh:435-441 pattern):
```bash
local cache_dir="/home/${user}/.cache/rclone/vfs/nzbdav"
if [[ -d "$cache_dir" ]]; then
    local cache_size
    cache_size=$(du -sh "$cache_dir" 2>/dev/null | cut -f1) || cache_size="unknown"
    rm -rf "$cache_dir"
    echo_info "Cleared VFS cache ($cache_size freed)"
fi
```

#### 1.2 Update `swizzin-app-info` (existing file)

```python
"nzbdav": {
    "config_paths": ["/opt/nzbdav/docker-compose.yml", "/opt/nzbdav/config/"],
    "format": "docker_compose",
    "keys": {
        "port": "PORT",
        "image": "nzbdav/nzbdav:latest",
        "mount_point": "swizdb:nzbdav/mount_point"
    }
}
```

#### 1.3 Update backup system

Add to `SERVICE_TYPES`, `SERVICE_STOP_ORDER`, and backup paths:
- Stop `rclone-nzbdav` before `nzbdav` (unmount first)
- Backup: `/opt/nzbdav/config/` (SQLite db + settings)
- Exclude: rclone VFS cache directory

### Phase 2: Post-Install UX

```bash
_post_install_info() {
    echo ""
    echo_info "=== NZBDav Installed ==="
    echo_info "Web UI: https://your-server/nzbdav/"
    echo ""
    echo_warn "=== FIRST-RUN SETUP REQUIRED ==="
    echo_info "1. Open the web UI and configure:"
    echo_info "   - Usenet provider (Settings > Usenet)"
    echo_info "   - WebDAV password (Settings > WebDAV)"
    echo_info "   - SABnzbd settings (Settings > SABnzbd)"
    echo ""
    echo_info "2. After configuring, set up the rclone mount:"
    echo_info "   Run: nzbdav.sh --setup-rclone"
    echo_info "   This will ask for your WebDAV password and start the mount"
    echo ""
    echo_info "Mount point: ${app_mount_point}"
    echo_info "SABnzbd API: http://127.0.0.1:${app_port}/api"
    echo_info "API Key: (check NZBDav Settings > SABnzbd after first-run setup)"
    echo ""

    _display_arr_info
}
```

### Phase 3: `--setup-rclone` subcommand

Add a dedicated `--setup-rclone` flag that:
1. Prompts for WebDAV password
2. Obscures it via `rclone obscure`
3. Writes/updates rclone.conf
4. Enables and starts `rclone-nzbdav.service`
5. Verifies mount is working (`ls "$mount_point"`)

This can also be called during `--update` if rclone.conf already exists (skip password prompt, just restart).

## Dependencies & Risks

- **No env var support**: NZBDav cannot be fully configured at install time (Issue #227). Requires web UI first-run. Mitigated by `--setup-rclone` subcommand.
- **rclone v1.70.3+**: `--links` flag requires recent rclone. The `curl | bash` installer gets latest.
- **FUSE availability**: Some VPS/containers lack FUSE kernel module. Check `modinfo fuse` and warn.
- **Port exposure with `network_mode: host`**: App may bind to `0.0.0.0`. Rely on nginx + UFW.
- **NZBDav `alpha` tag**: Currently the only available tag. May change to `latest`. Plan uses `latest`.
- **sub_filter uncertainty**: Need to test whether NZBDav's frontend uses absolute or relative paths. Will resolve during implementation.
- **Disk space**: VFS cache uses up to 20GB by default. May surprise users on small disks.

#### Research Insights

**`sub_filter` testing strategy:** Since `sub_filter` rules are the highest-risk uncertainty, the implementation phase should test with a real NZBDav instance. Start the container, access the web UI directly at `http://localhost:<port>/`, then inspect the HTML source for absolute path patterns. Compare against the zurg.sh `sub_filter` rules to confirm coverage. If NZBDav uses a JavaScript SPA with a bundler (likely, given TypeScript frontend), paths may be embedded in JS bundles — the `sub_filter_types` including `application/javascript` handles this.

**rclone install idempotency:** The `_install_rclone()` function (zurg.sh:253-272) already handles the case where rclone is pre-installed (returns early). If the user already has rclone from a zurg installation, NZBDav reuses it. No conflict — each app uses its own rclone.conf file.

### Edge Cases

- User forgets to run `--setup-rclone`: Mount service stays disabled, media servers can't access content. Clear post-install messaging.
- rclone mount becomes stale after container crash: `Restart=on-failure` in systemd + readiness probe handles recovery.
- Mount point already in use: Checked during install with `mountpoint -q`, abort with clear error.
- User has other rclone remotes: Removal only deletes `[nzbdav]` section, not entire rclone.conf.
- `--update` while rclone mount is active: Container restart → readiness probe waits → rclone reconnects.

#### Research Insights

**`--update` race condition:** When `--update` recreates the container, the rclone mount loses its WebDAV backend temporarily. The mount will return I/O errors during this window. The readiness probe in `ExecStartPre` only applies on service start, not during running operation. Mitigation: the `--update` handler should stop rclone-nzbdav first, then recreate the container, then restart rclone-nzbdav. This creates a clean restart sequence rather than relying on rclone's error recovery.

**Concurrent zurg + nzbdav:** Users may run both zurg (Real-Debrid) and nzbdav (Usenet) simultaneously. No conflicts — they use different rclone.conf files, different mount points, different ports, and different systemd services. Both use `fuse3` and `user_allow_other` which are shared system resources (no conflict).

## Sources & References

### Origin

- **Brainstorm document:** [docs/brainstorms/2026-03-07-nzbdav-brainstorm.md](../brainstorms/2026-03-07-nzbdav-brainstorm.md) — Key decisions: bundle rclone, `network_mode: host`, display-only arr info, dynamic port, user-configurable mount point.

### Internal References

- Docker template: `templates/template-docker.sh`
- rclone mount pattern: `zurg.sh` (lines 253-272 rclone install, 862-876 rclone.conf, 1005-1060 mount service, 1057-1059 FUSE config)
- Mount point prompt: `zurg.sh:275-310` (`_get_mount_point()`)
- Sonarr/Radarr discovery: `mdblistarr.sh:457-526` (`_discover_arr_instances()`)
- `network_mode: host`: `mdblistarr.sh:342`, `lingarr.sh:524`
- FUSE requirements: `zurg.sh:87`, `decypharr.sh:87`
- rclone.conf section removal: `zurg.sh:444-452`

### External References

- NZBDav GitHub: https://github.com/nzbdav-dev/nzbdav
- NZBDav setup guide: https://github.com/nzbdav-dev/nzbdav/blob/main/docs/setup-guide.md
- NZBDav Docker Hub: https://hub.docker.com/r/nzbdav/nzbdav
- NZBDav env var feature request: https://github.com/nzbdav-dev/nzbdav/issues/227
- ElfHosted NZBDav: https://docs.elfhosted.com/app/nzbdav/
- NZBDav entrypoint.sh: Uses `PUID`/`PGID` with `su-exec`, `CONFIG_PATH=/config`, `BACKEND_URL=http://localhost:8080`
