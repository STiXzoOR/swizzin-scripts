# Brainstorm: NZBDav Installer

**Date:** 2026-03-07
**Status:** Final

## What We're Building

A Docker-based Swizzin installer for **NZBDav** — a C#/.NET WebDAV server that mounts NZB documents as a virtual filesystem, enabling "infinite library" streaming from Usenet providers. NZBDav provides a SABnzbd-compatible API (drop-in replacement) so Sonarr/Radarr can use it as a download client, and a WebDAV endpoint that gets mounted via rclone so Plex/Jellyfin can stream directly.

Unlike the debrid indexer stack (Zilean/StremThru/MediaFusion), NZBDav is a **download client** — it sits between the arr stack and Usenet, not between Prowlarr and the arr stack.

## Why This Approach

Single Docker container + host-side rclone mount service. This is the same pattern as zurg.sh (Docker container for the app, separate systemd service for rclone WebDAV mount on the host filesystem).

**Why not rclone inside Docker?** Media servers (Plex/Emby/Jellyfin) run natively on the host. They need to see the mount on the host filesystem. FUSE mounts inside Docker can't propagate to the host reliably. The zurg.sh pattern solves this cleanly.

## Technical Details

- **Image:** `nzbdav/nzbdav:latest` (currently `alpha` tag, may stabilize to `latest`)
- **Language:** C# backend, TypeScript frontend
- **Port:** 3000 (default, configurable via dynamic allocation)
- **Config:** `/config` volume mount
- **Web UI:** Full admin interface at port 3000 (settings, queue, DAV explorer, health)
- **API:** SABnzbd-compatible API at port 3000 (same port as web UI)
- **WebDAV:** Served at port 3000 path (rclone connects to this)
- **Environment:** `PUID`, `PGID` for user/group mapping
- **Database:** None — config stored in `/config` directory
- **Nginx:** Subfolder with web UI auth + API auth bypass

### Two Systemd Services

| Service | Type | Purpose |
|---------|------|---------|
| `nzbdav.service` | oneshot (Docker Compose) | Runs the NZBDav container |
| `rclone-nzbdav.service` | notify (rclone mount) | Mounts WebDAV to host filesystem |

### rclone Mount (following zurg.sh pattern)

- Install rclone + fuse3 on host
- Generate `rclone.conf` with WebDAV remote pointing to `http://127.0.0.1:<port>/`
- Mount to user-configurable path (default: `/mnt/nzbdav`, prompted like zurg.sh)
- `--allow-other` + `user_allow_other` in `/etc/fuse.conf`
- `--vfs-cache-mode full` for streaming support
- `--links` flag for symlink support (rclone v1.70.3+)
- Mount service depends on Docker service via `After=` + `Requires=`

### Sonarr/Radarr Integration

NZBDav acts as a **SABnzbd download client**. Integration is display-only:
- Discover installed Sonarr/Radarr instances (lock files + config.xml)
- Display connection info: host, port, NZBDav SABnzbd API key
- User adds NZBDav as a SABnzbd download client in each arr instance

No auto-configuration via API — adding download clients via POST `/api/v3/downloadclient` has no precedent in the codebase and is more complex than the Prowlarr indexer pattern.

### Volumes (bind mounts)

- `/opt/nzbdav/config:/config` — NZBDav configuration + database
- `/mnt:/mnt` — Host mount propagation (so NZBDav can see the rclone mount path for symlinks)

## Key Decisions

1. **Bundle rclone mount** — Two systemd services, matching zurg.sh pattern. NZBDav is useless without the WebDAV mount for media servers.
2. **User-configurable mount point** — Prompt during install with default `/mnt/nzbdav`, support `NZBDAV_MOUNT_PATH` env var, persist in swizdb. Same UX as zurg.sh `_get_mount_point()`.
3. **`network_mode: host`** — arr stack runs natively on host, not in Docker. Matches mdblistarr/lingarr pattern.
4. **Display arr info only** — No auto-config of Sonarr/Radarr download clients. Show SABnzbd API URL + key for manual setup.
5. **Dynamic port** — Port 3000 conflicts easily (Grafana, various Node apps). Use `port 10000 12000`.
6. **Single container** — No database services. Config stored in `/config` volume.
7. **Image tag:** Use `nzbdav/nzbdav:latest` (alpha is current but should stabilize).

## Implementation Notes

- Follow Docker template pattern from `templates/template-docker.sh`
- Reuse `_install_rclone()` pattern from zurg.sh (curl installer)
- Reuse FUSE config pattern from zurg.sh (`user_allow_other` in `/etc/fuse.conf`)
- rclone mount service: `Type=notify`, `ExecStop=/bin/fusermount -uz $mount_point`
- WebDAV credentials: auto-generated password, stored in rclone.conf
- nginx: subfolder with htpasswd for web UI, `auth_basic off` for SABnzbd API path
- Post-install: display SABnzbd API URL/key, WebDAV mount path, arr connection info
- `swizzin-app-info` registration, backup system integration
- `app_reqs=("curl" "fuse3")` for FUSE support
