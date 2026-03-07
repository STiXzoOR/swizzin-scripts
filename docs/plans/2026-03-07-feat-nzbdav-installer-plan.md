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
1. **Networking changed to bridge** — NZBDav has NO `PORT` env var (Issue #227). Cannot use `network_mode: host` with dynamic port allocation. Use `ports: ["127.0.0.1:${app_port}:3000"]` + `extra_hosts` for arr connectivity. Resolves 0.0.0.0 exposure without UFW.
2. **`/mnt:/mnt:rslave` volume added** — NZBDav needs host mount visibility for symlink resolution (Rclone Mount Directory setting) and library repairs (dead link monitoring). Requires mount propagation for host-side rclone FUSE mount.
3. Resolved chicken-and-egg problem via **re-run detection** (not `--setup-rclone` subcommand — no codebase precedent for post-install flags)
4. Confirmed `sub_filter` required — NZBDav has no base URL support, reuse zurg.sh `sub_filter` rules
5. Health check confirmed at `/health` endpoint (frontend proxies to backend)
6. **All rclone flags kept** — official setup guide documents each as essential for streaming performance
7. rclone mount systemd: `Type=notify` with bounded `ExecStartPre` readiness probe (max 60s timeout)
8. Removal ordering: unmount rclone FIRST, then stop Docker (prevents hung FUSE mounts)
9. **`umask 077`** on credential file writes (TOCTOU race fix)
10. rclone.conf is app-isolated at `/opt/nzbdav/rclone.conf` — just delete on purge (no section removal needed)

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

Single Docker container. Bridge networking with `127.0.0.1` port mapping + `extra_hosts` for arr connectivity. Dynamic port allocation. nginx subfolder with API auth bypass. rclone WebDAV mount with FUSE. User-configurable mount point. Display Sonarr/Radarr connection info.

## Technical Considerations

### Architecture

- **Single container**: NZBDav is self-contained — C# backend (port 8080 internal) + Node.js frontend (port 3000 exposed), SQLite config at `/config/db.sqlite`
- **Networking**: Bridge with `ports: ["127.0.0.1:${app_port}:3000"]` + `extra_hosts: ["host.docker.internal:host-gateway"]`
- **Port**: Dynamic via `port 10000 12000` (NZBDav has no `PORT` env var — always listens on 3000 internally. Bridge port mapping solves this.)
- **Web UI**: Full admin interface — settings, queue, DAV explorer, health monitor
- **rclone mount**: Host-side FUSE mount of NZBDav's WebDAV endpoint, separate systemd service
- **User mapping**: `PUID`/`PGID` environment variables (LinuxServer.io-style entrypoint with `su-exec`, NOT Docker `user:` directive)
- **Mount propagation**: `/mnt:/mnt:rslave` — NZBDav container must see host rclone mount for symlink resolution and library repairs

**Why bridge networking (not `network_mode: host`):**
Unlike mdblistarr/lingarr which support `PORT` and `ASPNETCORE_URLS` env vars, NZBDav has NO port/bind configuration (Issue #227). With `network_mode: host`, the app binds to `0.0.0.0:3000` AND `0.0.0.0:8080` with no way to control it. Bridge networking with `127.0.0.1` port mapping:
1. Exposes only one port on localhost (3000 mapped to dynamic port)
2. Backend port 8080 stays container-internal
3. Dynamic port allocation works via Docker port mapping
4. No UFW rule needed
5. NZBDav reaches host arr apps via `host.docker.internal` (documented in post-install)

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
3. **Re-run the installer** (`bash nzbdav.sh`) — it detects the missing rclone.conf and prompts for the WebDAV password

**Re-run detection logic** (no `--setup-rclone` subcommand — no codebase precedent for post-install flags):

```bash
# During main install flow:
if [[ -f "/install/.nzbdav.lock" ]]; then
    if [[ ! -f "${app_dir}/rclone.conf" ]]; then
        # Lock exists but rclone not configured → prompt for WebDAV password
        _setup_rclone
    else
        # Everything configured → just restart services
        _restart_services
    fi
    exit 0
fi
```

```bash
_setup_rclone() {
    echo_query "Enter the WebDAV password you set in NZBDav Settings > WebDAV:"
    read -rs webdav_pass </dev/tty
    echo ""

    # Generate obscured password for rclone
    local obscured
    obscured=$(echo "$webdav_pass" | rclone obscure -) || {
        echo_error "Failed to obscure password"
        return 1
    }
    unset webdav_pass

    # Write rclone.conf with restrictive permissions from creation
    (umask 077; cat >"${app_dir}/rclone.conf" <<RCLONE
[nzbdav]
type = webdav
url = http://127.0.0.1:${app_port}/
vendor = other
user = admin
pass = ${obscured}
RCLONE
    )
    chown "${user}:${user}" "${app_dir}/rclone.conf"

    # Enable and start rclone mount
    systemctl enable rclone-nzbdav.service
    systemctl start rclone-nzbdav.service
}
```

**Security improvements over original design:**
- `rclone obscure -` reads from stdin (password not visible in `ps aux`)
- `unset webdav_pass` immediately after use
- `umask 077` subshell ensures file created with 0600 from the start (no TOCTOU race)

On **re-run** (rclone.conf already exists): skip the prompt, just restart the mount service.

### Compose File Structure

```yaml
services:
  nzbdav:
    image: nzbdav/nzbdav:latest
    container_name: nzbdav
    restart: unless-stopped
    ports:
      - "127.0.0.1:<app_port>:3000"
    environment:
      - PUID=<uid>
      - PGID=<gid>
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - /opt/nzbdav/config:/config
      - /mnt:/mnt:rslave
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      interval: 1m
      timeout: 5s
      retries: 3
      start_period: 30s
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
```

**Notes:**
- `PUID`/`PGID` (not `user:`) — NZBDav's entrypoint uses `su-exec` to switch to the correct user
- Bind mount at `/opt/nzbdav/config` for backup system compatibility (not named volumes)
- `/mnt:/mnt:rslave` — NZBDav needs to see the host rclone mount for symlink resolution and library repairs (`:rslave` propagates host FUSE mounts into the container)
- Health check matches official setup guide: `curl -f http://localhost:3000/health`
- `127.0.0.1` port mapping — only accessible from localhost, no UFW rule needed
- `extra_hosts` — allows NZBDav to reach host-native Sonarr/Radarr via `host.docker.internal`

#### Research Insights

**No `user:` directive — confirmed:** NZBDav's entrypoint.sh uses `su-exec` to drop from root to `PUID:PGID`. Adding Docker's `user:` directive would conflict — the entrypoint would fail because `su-exec` requires root to switch users. This matches the LinuxServer.io pattern used by Sonarr, Radarr, etc.

**`start_period: 30s`:** .NET apps with EF Core migrations can take 5-15s on first start. The official guide uses `start_period: 5s`, but that's optimistic for slow VPS. 30s provides margin without affecting steady-state checks.

**Bridge networking + `extra_hosts` trade-off:** MDBListarr and Lingarr use `network_mode: host` because they support `PORT`/`ASPNETCORE_URLS` env vars for port control. NZBDav lacks this, making bridge networking the only way to get dynamic port allocation and localhost-only binding. The trade-off: users configure arr hosts in NZBDav as `http://host.docker.internal:<port>` instead of `http://127.0.0.1:<port>`. This is documented in post-install instructions.

**`:rslave` mount propagation:** Required because the host-side rclone mount happens AFTER the container starts (deferred setup). Without `:rslave`, the container would not see the FUSE mount created later at `/mnt/nzbdav`. With `:rslave`, new host mounts under `/mnt` propagate into the container automatically.

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
ExecStartPre=/bin/bash -c 'for i in $(seq 1 30); do curl -sf http://127.0.0.1:<port>/health && exit 0; sleep 2; done; echo "NZBDav health check timed out after 60s"; exit 1'
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

**Stale mount detection and recovery:** If the container crashes while the FUSE mount is active, the mount point becomes stale (`Transport endpoint is not connected`). The re-run and `--update` flows should check for stale mounts:
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

    swizdb set "nzbdav/mount_point" "$app_mount_point"
}
```

### Nginx Configuration

NZBDav does NOT support a base URL path prefix (no env var for it, Issue #227). The nginx subfolder needs `sub_filter` for asset path rewriting (TypeScript SPA generates absolute paths like `/assets/`, `/api/`).

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
    proxy_set_header Accept-Encoding "";
    proxy_redirect off;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $http_connection;

    # Rewrite absolute paths in responses (NZBDav has no base_url support)
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

    auth_basic "What's the password?";
    auth_basic_user_file /etc/htpasswd.d/htpasswd.<user>;
}

# SABnzbd API bypass for Sonarr/Radarr (localhost only via bridge networking)
# NZBDav's SABnzbd API is at /api (standard SABnzbd path)
location ^~ /nzbdav/api {
    auth_request off;
    proxy_pass http://127.0.0.1:<port>/api;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_http_version 1.1;
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

- Bridge networking with `127.0.0.1` port mapping — port only accessible from localhost, no UFW rule needed
- Backend port 8080 stays container-internal (not exposed via port mapping)
- `umask 077` subshell around all credential file writes (`rclone.conf`) — no TOCTOU race
- `chown root:root` on compose file, `chown user:user` on rclone.conf (rclone runs as user)
- `chmod 700 /opt/nzbdav/config` — SQLite db contains Usenet credentials
- `no-new-privileges:true` + `cap_drop: ALL` on container
- WebDAV password read with `read -rs` (silent, no echo)
- `rclone obscure -` reads password from stdin (not visible in `ps aux`)
- `unset webdav_pass` immediately after use
- SABnzbd API key is auto-generated by NZBDav and stored in SQLite — only accessible via web UI

#### Research Insights

**Container security matches codebase standard:** `no-new-privileges:true` + `cap_drop: ALL` is the same hardening applied to StremThru, Zilean, and MediaFusion plans. NZBDav doesn't need any Linux capabilities — it uses `su-exec` in the entrypoint (before cap_drop applies) and doesn't bind privileged ports.

**`read_only: true` consideration:** Unlike StremThru (which only writes to `/app/data`), NZBDav writes to `/config` and may create temp files elsewhere. Do NOT add `read_only: true` without testing — the .NET runtime and Node.js frontend may need writable `/tmp`. If desired, add `tmpfs: ["/tmp"]` but leave the root filesystem writable for safety.

**rclone.conf password obscuration:** `rclone obscure` uses AES-CTR with a fixed key — it's obfuscation, not encryption. It prevents casual shoulder-surfing but won't stop a determined attacker with file access. Combined with `umask 077` + `chmod 600`, this provides reasonable protection.

### Sonarr/Radarr Integration (Display Only)

NZBDav requires **bidirectional** integration with Sonarr/Radarr (unlike traditional download clients):
1. **Arr → NZBDav**: Add NZBDav as SABnzbd download client in Sonarr/Radarr
2. **NZBDav → Arr**: Add Sonarr/Radarr instances in NZBDav Settings > Radarr/Sonarr (for symlink creation and queue management)

Since NZBDav runs in bridge networking, it reaches host-native arr apps via `host.docker.internal`.

Display static connection info (no arr discovery needed — user already knows their arr URLs):

```bash
_display_arr_info() {
    echo ""
    echo_info "=== Sonarr/Radarr Download Client Setup ==="
    echo_info "Step 1: Add NZBDav as download client in Sonarr/Radarr:"
    echo_info "  Type: SABnzbd | Host: 127.0.0.1 | Port: ${app_port}"
    echo_info "  API Key: found in NZBDav Settings > SABnzbd"
    echo ""
    echo_info "Step 2: Add arr instances in NZBDav Settings > Radarr/Sonarr:"
    echo_info "  Use http://host.docker.internal:<arr_port> as the host URL"
    echo_info "  (NZBDav runs in Docker and reaches host services via host.docker.internal)"
    echo ""
    echo_info "Step 3: Configure mount & repairs in NZBDav:"
    echo_info "  Settings > SABnzbd > Rclone Mount Directory: ${app_mount_point}"
    echo_info "  Settings > Repairs > Library Directory: /mnt/media (or your library root)"
    echo_info "  Settings > Repairs > Enable Background Repairs: checked"
    echo ""
}
```

No auto-configuration — adding download clients via POST `/api/v3/downloadclient` has no codebase precedent.

#### Research Insights

**Simplified from arr discovery:** The original plan used mdblistarr.sh-style arr instance discovery (`_discover_arr_instances()`). This is unnecessary for NZBDav — users who set up Usenet streaming already know where Sonarr/Radarr runs. Static text with NZBDav's connection details is clearer and eliminates ~30 lines of discovery logic.

**`host.docker.internal` requirement:** With bridge networking, the NZBDav container cannot reach `127.0.0.1` on the host. The `extra_hosts: ["host.docker.internal:host-gateway"]` directive maps `host.docker.internal` to the Docker bridge gateway IP. Users configure arr hosts in NZBDav as `http://host.docker.internal:8989` (Sonarr) or `http://host.docker.internal:7878` (Radarr).

**Rclone Mount Directory setting:** From the official setup guide (Phase 4 Step 3): this tells NZBDav where files physically exist on the host filesystem so it can pass correct paths to Radarr/Sonarr for import. Must match the actual rclone mount point.

**Library repairs:** NZBDav can monitor for dead symlinks in the media library and trigger automatic redownloads. Requires the Library Directory setting pointing to the root media folder (e.g., `/mnt/media`).

## Acceptance Criteria

- [ ] `nzbdav.sh` installs NZBDav via Docker Compose with bridge networking (`127.0.0.1:${app_port}:3000`)
- [ ] `extra_hosts: ["host.docker.internal:host-gateway"]` for arr connectivity from container
- [ ] `/mnt:/mnt:rslave` volume for mount propagation (symlink resolution + repairs)
- [ ] rclone + fuse3 installed on host
- [ ] User prompted for mount point (default `/mnt/nzbdav`, persisted in swizdb)
- [ ] `rclone-nzbdav.service` created but NOT enabled on fresh install (chicken-and-egg)
- [ ] Post-install instructions guide user through first-run config + re-run for rclone setup
- [ ] Re-running installer detects missing rclone.conf and prompts for WebDAV password
- [ ] `nzbdav.sh --update` pulls latest image, recreates container, restarts rclone mount only if it was active
- [ ] `nzbdav.sh --remove` unmounts FUSE first, then stops Docker, cleans up both services
- [ ] `nzbdav.sh --remove` with purge deletes `/opt/nzbdav/rclone.conf` and VFS cache directory
- [ ] Nginx subfolder at `/nzbdav` with `sub_filter` rules and `auth_request off` for `/nzbdav/api`
- [ ] Panel registration works
- [ ] `swizzin-app-info` updated
- [ ] Static connection info displayed (SABnzbd URL, arr setup steps with `host.docker.internal`)
- [ ] Bind mounts at `/opt/nzbdav/` for backup system compatibility
- [ ] `PUID`/`PGID` environment variables (not `user:` directive)
- [ ] Container security: `no-new-privileges`, `cap_drop: ALL`
- [ ] Credential security: `umask 077`, `rclone obscure -` via stdin, `unset` after use
- [ ] `chmod 700 /opt/nzbdav/config` for SQLite database protection
- [ ] Idempotent: re-running preserves existing config and rclone.conf
- [ ] Unattended install via `NZBDAV_MOUNT_PATH`, `NZBDAV_PORT` env vars

## Implementation Plan

### Phase 1: Core Installer (`nzbdav.sh`)

#### 1.1 Create `nzbdav.sh` (new file)

Based on Docker template + zurg.sh rclone pattern:

- **App variables**: `app_name="nzbdav"`, dynamic port, image `nzbdav/nzbdav:latest`, `app_reqs=("curl" "fuse3")`
- **`_get_mount_point()`**: Prompt with default `/mnt/nzbdav`, env var override, swizdb persistence, mount conflict check
- **`_install_nzbdav()`**: Docker install, compose generation (bridge networking, `127.0.0.1` port map, `extra_hosts`, `PUID`/`PGID`, `/mnt:/mnt:rslave`), container start
- **`_install_rclone()`**: Install rclone on host (reuse zurg.sh pattern), configure FUSE `user_allow_other`
- **`_systemd_nzbdav()`**: Create TWO services — `nzbdav.service` (Docker oneshot) + `rclone-nzbdav.service` (rclone mount with readiness probe, NOT enabled on fresh install)
- **`_nginx_nzbdav()`**: Subfolder proxy with SABnzbd API auth bypass, `sub_filter` if needed
- **`_setup_rclone()`**: Prompt for WebDAV password (on re-run when rclone.conf missing), obscure via stdin, write with `umask 077`, enable+start mount service
- **`_display_arr_info()`**: Static connection info (SABnzbd URL, `host.docker.internal` for arr hosts, mount directory, repairs config)
- **`_update_nzbdav()`**: Pull latest image, recreate container, restart rclone mount service if running
- **`_remove_nzbdav()`**: Stop rclone mount FIRST (unmount), then stop Docker, remove both services, delete `/opt/nzbdav/rclone.conf`, cleanup VFS cache
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

**rclone.conf removal on purge:** NZBDav uses an app-isolated rclone.conf at `/opt/nzbdav/rclone.conf` (not the user's global `~/.config/rclone/rclone.conf`). Just `rm -f "${app_dir}/rclone.conf"` on purge. The zurg.sh:447 sed section-removal pattern is unnecessary here since there's no shared config file.

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
    echo_info "   Re-run: bash nzbdav.sh"
    echo_info "   It will detect the missing rclone config and ask for your WebDAV password"
    echo ""
    echo_info "Mount point: ${app_mount_point}"
    echo_info "SABnzbd API: http://127.0.0.1:${app_port}/api"
    echo_info "API Key: (check NZBDav Settings > SABnzbd after first-run setup)"
    echo ""

    _display_arr_info
}
```

### Phase 3: Re-run rclone Setup

No dedicated `--setup-rclone` subcommand (no codebase precedent). Instead, the installer's re-run detection handles it:

1. **Fresh install** (no lock file): Full install, rclone service created but NOT enabled
2. **Re-run, no rclone.conf** (lock file exists, rclone.conf missing): Prompt for WebDAV password, write rclone.conf, enable+start mount
3. **Re-run, rclone.conf exists** (lock file + rclone.conf present): Just restart services

The `--update` flow restarts the rclone mount only if `systemctl is-active rclone-nzbdav.service` was true before the container recreate.

## Dependencies & Risks

- **No env var support**: NZBDav cannot be configured at install time (Issue #227). Requires web UI first-run. Mitigated by re-run detection for deferred rclone setup.
- **rclone v1.70.3+**: `--links` flag requires recent rclone. The `curl | bash` installer gets latest. Add version check and warn if too old.
- **FUSE availability**: Some VPS/containers lack FUSE kernel module. Check `modinfo fuse` and warn.
- **Mount propagation**: `/mnt:/mnt:rslave` requires Docker to support bind propagation. Fails on very old Docker versions (< 17.06). Swizzin targets recent Docker.
- **`host.docker.internal` dependency**: NZBDav reaches arr apps via `host.docker.internal`. This requires Docker Engine 20.10+ (Linux support added). Falls back to Docker bridge gateway IP if needed.
- **NZBDav `alpha` tag**: Currently the only available tag. May change to `latest`. Plan uses `latest`.
- **sub_filter uncertainty**: Need to test whether NZBDav's frontend uses absolute or relative paths. Will resolve during implementation (TypeScript SPA likely uses absolute paths based on zurg.sh precedent).
- **Disk space**: VFS cache uses up to 20GB by default. Post-install warning included.

#### Research Insights

**`sub_filter` testing strategy:** Since `sub_filter` rules are the highest-risk uncertainty, the implementation phase should test with a real NZBDav instance. Start the container, access the web UI directly at `http://localhost:<port>/`, then inspect the HTML source for absolute path patterns. Compare against the zurg.sh `sub_filter` rules to confirm coverage. If NZBDav uses a JavaScript SPA with a bundler (likely, given TypeScript frontend), paths may be embedded in JS bundles — the `sub_filter_types` including `application/javascript` handles this.

**rclone install idempotency:** The `_install_rclone()` function (zurg.sh:253-272) already handles the case where rclone is pre-installed (returns early). If the user already has rclone from a zurg installation, NZBDav reuses it. No conflict — each app uses its own rclone.conf file.

### Edge Cases

- User forgets to re-run installer: Mount service stays disabled, media servers can't access content. Clear post-install messaging.
- rclone mount becomes stale after container crash: `Restart=on-failure` in systemd + readiness probe handles recovery.
- Mount point already in use: Checked during install with `mountpoint -q`, abort with clear error.
- User has other rclone remotes: Removal only deletes `[nzbdav]` section, not entire rclone.conf.
- `--update` while rclone mount is active: Container restart → readiness probe waits → rclone reconnects.

#### Research Insights

**`--update` race condition:** When `--update` recreates the container, the rclone mount loses its WebDAV backend temporarily. The mount will return I/O errors during this window. The readiness probe in `ExecStartPre` only applies on service start, not during running operation. Mitigation: the `--update` handler should stop rclone-nzbdav first, then recreate the container, then restart rclone-nzbdav. This creates a clean restart sequence rather than relying on rclone's error recovery.

**Concurrent zurg + nzbdav:** Users may run both zurg (Real-Debrid) and nzbdav (Usenet) simultaneously. No conflicts — they use different rclone.conf files, different mount points, different ports, and different systemd services. Both use `fuse3` and `user_allow_other` which are shared system resources (no conflict).

## Sources & References

### Origin

- **Brainstorm document:** [docs/brainstorms/2026-03-07-nzbdav-brainstorm.md](../brainstorms/2026-03-07-nzbdav-brainstorm.md) — Key decisions: bundle rclone, display-only arr info, dynamic port, user-configurable mount point. (Networking changed from `network_mode: host` to bridge after discovering NZBDav lacks PORT env var.)

### Internal References

- Docker template: `templates/template-docker.sh`
- rclone mount pattern: `zurg.sh` (lines 253-272 rclone install, 862-876 rclone.conf, 1005-1060 mount service, 1057-1059 FUSE config)
- Mount point prompt: `zurg.sh:275-310` (`_get_mount_point()`)
- Sonarr/Radarr discovery: `mdblistarr.sh:457-526` (`_discover_arr_instances()`)
- Bridge networking with `extra_hosts`: diverges from `mdblistarr.sh` (host networking) because NZBDav lacks PORT env var
- `extra_hosts` pattern: Docker Engine 20.10+ `host-gateway` support
- FUSE requirements: `zurg.sh:87`, `decypharr.sh:87`
- rclone.conf section removal: `zurg.sh:444-452`

### External References

- NZBDav GitHub: https://github.com/nzbdav-dev/nzbdav
- NZBDav setup guide: https://github.com/nzbdav-dev/nzbdav/blob/main/docs/setup-guide.md
- NZBDav Docker Hub: https://hub.docker.com/r/nzbdav/nzbdav
- NZBDav env var feature request: https://github.com/nzbdav-dev/nzbdav/issues/227
- ElfHosted NZBDav: https://docs.elfhosted.com/app/nzbdav/
- NZBDav entrypoint.sh: Uses `PUID`/`PGID` with `su-exec`, `CONFIG_PATH=/config`, `BACKEND_URL=http://localhost:8080`
- NZBDav official setup guide: Phases 1-5 covering Docker deploy, rclone sidecar, arr integration, mount config, Stremio/AIOStreams
- Official rclone flags documentation: Each flag explained as essential for streaming (--links, --use-cookies, --buffer-size 0M, --vfs-read-ahead 512M)
