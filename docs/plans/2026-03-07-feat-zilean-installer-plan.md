---
title: "feat: Add Zilean Docker installer"
type: feat
status: completed
date: 2026-03-07
deepened: 2026-03-07
origin: docs/brainstorms/2026-03-07-zilean-brainstorm.md
---

# feat: Add Zilean Docker Installer

## Enhancement Summary

**Deepened on:** 2026-03-07
**Sections enhanced:** 7
**Research sources:** Web (Zilean GitHub, Prowlarr wiki, ElfHosted docs), codebase (mdblistarr.sh, lingarr.sh, Docker template), Docker Compose best practices

### Key Improvements
1. Added Zilean version pinning recommendation (v3.5.0) and first-run IMDB warning
2. Concrete Prowlarr API payload for auto-configuration with JSON example
3. Shared `lib/prowlarr-utils.sh` library proposal for reuse across all 3 installers
4. PostgreSQL `shm_size` tuning and security hardening (read-only rootfs, no-new-privileges)
5. Port conflict handling: check 8181 availability, fall back to dynamic if occupied
6. Switched to `network_mode: host` + bind mounts for arr stack compatibility and backup support

## Overview

Create a Docker-based Swizzin installer for Zilean, a DMM (DebridMediaManager) hashlist Torznab indexer. Zilean indexes cached debrid content and exposes it as a Torznab API compatible with Prowlarr and the *arr stack. This is the simplest of the three debrid indexer apps (Zilean, StremThru, MediaFusion).

## Problem Statement / Motivation

Standard torrent indexers only find public torrents. Debrid users have access to massive libraries of pre-cached content shared via DebridMediaManager, but there's no way to search this from the *arr stack. Zilean bridges this gap by exposing DMM hashlists as a standard Torznab feed that Prowlarr can consume and distribute to Sonarr/Radarr.

## Proposed Solution

A single `zilean.sh` installer following the established Docker template pattern (`mdblistarr.sh` as reference). Two containers in one compose: Zilean app + PostgreSQL 17. Fixed port 8181 (well-known). Subfolder nginx reverse proxy. Auto-configure Prowlarr if installed.

(see brainstorm: `docs/brainstorms/2026-03-07-zilean-brainstorm.md`)

## Technical Considerations

### Architecture

- **Two-container compose**: `zilean` (app) + `zilean-postgres` (database)
- **Networking**: `network_mode: host` for zilean container (matches mdblistarr/lingarr pattern — arr stack runs natively on host, not in Docker). PostgreSQL on internal bridge network, accessed via published port on `127.0.0.1`.
- **Port**: Fixed 8181 - well-known port expected by other tools (Sootio, MediaFusion, Comet). Use `port` command to check availability but fall back to 8181 specifically.
- **No web UI**: Zilean is a pure API service - nginx subfolder exposes the Torznab endpoint only

#### Research Insights

**Port handling strategy:**
```bash
# Try fixed 8181 first, fall back to dynamic if occupied
if ! ss -tlnp | grep -q ':8181 '; then
    app_port=8181
else
    echo_warn "Port 8181 in use, allocating dynamic port"
    app_port=$(port 10000 12000)
fi
```

**First-run warning:** Zilean's IMDB matching on first run can take >1.5 days. The installer should display a clear warning:
```
echo_warn "First run: IMDB matching may take 24-48 hours to complete"
echo_info "Zilean will return limited results until indexing finishes"
```

**Version pinning:** Latest stable is v3.5.0 (April 2025). Consider `ipromknight/zilean:v3.5.0` instead of `:latest` for reproducible installs. The `--update` flag can pull `:latest` explicitly.

**`network_mode: host` rationale:** The arr stack (Prowlarr, Sonarr, Radarr) runs natively on the host — NOT in Docker. Using host networking for the app container:
1. Matches the established pattern (mdblistarr.sh, lingarr.sh both use `network_mode: host`)
2. App can reach any host service on localhost without port mapping complexity
3. Prowlarr connects to Zilean at `127.0.0.1:8181` — no bridge networking indirection
4. PostgreSQL gets a published port on localhost for the app to connect via `127.0.0.1`

### Prowlarr Auto-Configuration

New function `_configure_prowlarr()` that:
1. Checks for `/install/.prowlarr.lock`
2. Reads API key and port from `/home/<user>/.config/Prowlarr/config.xml`
3. Adds Zilean as a Generic Torznab indexer via `POST /api/v1/indexer`
4. Falls back to displaying manual instructions if auto-config fails

#### Research Insights: Prowlarr API Payload

Concrete JSON payload for adding a Generic Torznab indexer:

```bash
_configure_prowlarr() {
    if [[ ! -f /install/.prowlarr.lock ]]; then
        _display_prowlarr_instructions
        return
    fi

    local prowlarr_api prowlarr_port prowlarr_base
    for cfg in /home/*/.config/Prowlarr/config.xml; do
        [[ -f "$cfg" ]] || continue
        prowlarr_api=$(grep -oP '<ApiKey>\K[^<]+' "$cfg" 2>/dev/null) || true
        prowlarr_port=$(grep -oP '<Port>\K[^<]+' "$cfg" 2>/dev/null) || true
        prowlarr_base=$(grep -oP '<UrlBase>\K[^<]+' "$cfg" 2>/dev/null) || true
        break
    done

    if [[ -z "${prowlarr_api:-}" || -z "${prowlarr_port:-}" ]]; then
        echo_warn "Could not read Prowlarr config"
        _display_prowlarr_instructions
        return
    fi

    local prowlarr_url="http://127.0.0.1:${prowlarr_port}"
    [[ -n "${prowlarr_base:-}" ]] && prowlarr_url="${prowlarr_url}/${prowlarr_base#/}"

    echo_progress_start "Adding Zilean to Prowlarr"

    local payload
    payload=$(cat <<'JSONEOF'
{
  "name": "Zilean",
  "implementation": "Torznab",
  "implementationName": "Torznab",
  "configContract": "TorznabSettings",
  "protocol": "torrent",
  "enable": true,
  "fields": [
    {"name": "baseUrl", "value": "http://127.0.0.1:ZILEAN_PORT"},
    {"name": "apiPath", "/api"},
    {"name": "apiKey", "value": ""},
    {"name": "minimumSeeders", "value": 0}
  ],
  "tags": []
}
JSONEOF
)
    payload="${payload//ZILEAN_PORT/$app_port}"

    local http_code
    http_code=$(curl --config <(printf 'header = "X-Api-Key: %s"' "$prowlarr_api") \
        -s -o /dev/null -w '%{http_code}' \
        -X POST "${prowlarr_url}/api/v1/indexer" \
        -H "Content-Type: application/json" \
        -d "$payload") || true

    if [[ "$http_code" == "201" ]]; then
        echo_progress_done "Zilean added to Prowlarr"
    else
        echo_warn "Could not auto-configure Prowlarr (HTTP $http_code)"
    fi

    _display_prowlarr_instructions
}
```

**Best Practice: Extract to shared library.** Since all 3 installers use the same Prowlarr discovery + API pattern, create `lib/prowlarr-utils.sh`:
- `_discover_prowlarr()` - returns API key, port, base URL
- `_add_prowlarr_torznab()` - adds a Generic Torznab indexer
- `_display_prowlarr_info()` - prints manual setup instructions

### Compose File Structure

```yaml
services:
  zilean:
    image: ipromknight/zilean:latest
    container_name: zilean
    restart: unless-stopped
    network_mode: host
    environment:
      Zilean__Database__ConnectionString: "Host=127.0.0.1;Port=<pg_port>;Database=zilean;Username=zilean;Password=<generated>"
    volumes:
      - /opt/zilean/data:/app/data
    depends_on:
      zilean-postgres:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8181/healthchecks/ping"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    read_only: true
    tmpfs:
      - /tmp

  zilean-postgres:
    image: postgres:17-alpine
    container_name: zilean-postgres
    restart: unless-stopped
    shm_size: 256m
    ports:
      - "127.0.0.1:<pg_port>:5432"
    environment:
      POSTGRES_USER: zilean
      POSTGRES_PASSWORD: <generated>
      POSTGRES_DB: zilean
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes:
      - /opt/zilean/pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U zilean"]
      interval: 10s
      timeout: 5s
      retries: 5
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
```

#### Research Insights

**`shm_size` tuning:** 2GB is excessive for Zilean's workload. PostgreSQL uses shared memory for `shared_buffers` and parallel query workers. For a small indexer DB, `256m` is sufficient. 2GB should only be used for large databases with heavy concurrent queries.

**`start_period`:** Add to health check to avoid false failures during initial DB migration (Zilean runs Alembic migrations on startup).

**`read_only: true` + `tmpfs`:** Makes the container filesystem read-only, preventing writes outside mounted volumes. More secure against container escape.

**`no-new-privileges`:** Prevents privilege escalation inside container.

### Nginx Configuration

Simple reverse proxy - no `sub_filter` needed since there's no web UI:

```nginx
location /zilean {
    return 301 /zilean/;
}

location ^~ /zilean/ {
    proxy_pass http://127.0.0.1:8181/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_http_version 1.1;

    auth_basic "What's the password?";
    auth_basic_user_file /etc/htpasswd.d/htpasswd.<user>;
}

# Torznab API bypass - narrowed to specific endpoint (not all /api routes)
location ^~ /zilean/api/v1/search {
    auth_basic off;
    proxy_pass http://127.0.0.1:8181/api/v1/search;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

#### Research Insights

**Torznab API auth bypass security:** The bypass is narrowed to `/api/v1/search` only (not all `/api` routes) because:
1. A broad `/zilean/api` bypass would expose ALL API endpoints without authentication — including any future admin/config endpoints
2. Only the Torznab search endpoint (`/api/v1/search`) needs to be unauthenticated for Prowlarr
3. Zilean binds to `127.0.0.1` only (not exposed externally)
4. Prowlarr connects via localhost, bypassing nginx entirely — the bypass is for any nginx-proxied requests

**Rate limiting consideration:** For API endpoints, could add `limit_req` to prevent abuse, but unnecessary since Zilean is localhost-only.

### Security

- PostgreSQL password generated via `openssl rand -base64 32 | tr -dc A-Za-z0-9 | cut -c -32`
- `chmod 600` on `docker-compose.yml` (contains DB password)
- Prowlarr API key read via `curl --config` pattern (hidden from `ps`)

#### Research Insights

**Password generation best practice:**
```bash
_generate_password() {
    openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c -32
}
```
This produces a 32-character alphanumeric password. Avoid special characters in PostgreSQL passwords to prevent shell/YAML escaping issues.

**Compose file permissions:** Set `chmod 600` on the compose file AND `chown root:root` since it contains the DB password. The systemd service runs as root (to invoke `docker compose`), so root ownership is correct.

## Acceptance Criteria

- [x] `zilean.sh` installs Zilean + PostgreSQL via Docker Compose
- [x] `zilean.sh --update` pulls latest image and recreates container
- [x] `zilean.sh --remove` cleanly removes all containers, images, configs
- [x] `zilean.sh --remove` with purge removes all data volumes
- [x] Zilean health check passes at `/healthchecks/ping`
- [x] Nginx subfolder at `/zilean` proxies to Zilean API
- [x] Torznab API accessible at `/zilean/api/v1/search` without htpasswd auth (narrowed — not all /api)
- [x] Prowlarr auto-configured with Zilean as Torznab indexer (if installed)
- [x] Manual Prowlarr instructions displayed (always)
- [x] Panel registration works (`--register-panel`)
- [x] `swizzin-app-info` updated with Zilean entry
- [x] Systemd service starts/stops containers correctly
- [x] Idempotent: re-running doesn't break existing install
- [x] First-run IMDB indexing warning displayed
- [x] Port conflict handled gracefully (8181 or fallback)
- [x] Bind mounts at `/opt/zilean/` (not named volumes) for backup system compatibility
- [x] `network_mode: host` used for zilean container (arr stack runs natively on host)

## Implementation Plan

### Phase 1: Shared Library (`lib/prowlarr-utils.sh`)

Create reusable Prowlarr integration functions used by all 3 installers:

```bash
# lib/prowlarr-utils.sh
# Shared Prowlarr auto-configuration for Torznab indexers

_discover_prowlarr() {
    # Sets: PROWLARR_API, PROWLARR_PORT, PROWLARR_BASE
    # Returns 1 if not found
}

_add_prowlarr_torznab() {
    local name="$1" url="$2" api_key="${3:-}"
    # POST to Prowlarr API v1
}

_display_prowlarr_torznab_info() {
    local name="$1" url="$2" notes="${3:-}"
    # Print manual setup instructions
}
```

### Phase 2: Core Installer (`zilean.sh`)

**Files to create/modify:**

#### 2.1 Create `zilean.sh` (new file)

Based on `mdblistarr.sh` pattern with these customizations:
- App variables: `app_name="zilean"`, fixed port 8181, image `ipromknight/zilean:latest`
- `_install_zilean()`: Generate compose with 2 services (zilean + postgres), secure DB password, Docker network, health checks
- `_systemd_zilean()`: Standard oneshot Docker Compose wrapper
- `_nginx_zilean()`: Subfolder proxy with API auth bypass for Torznab
- `_configure_prowlarr()`: Uses shared `lib/prowlarr-utils.sh`
- `_remove_zilean()`: Stop containers, remove images (both zilean + postgres), remove Docker volumes, cleanup
- `_update_zilean()`: Pull latest images, recreate containers

#### 2.2 Update `swizzin-app-info` (existing file)

Add to `APP_CONFIGS` dict:
```python
"zilean": {
    "config_paths": ["/opt/zilean/docker-compose.yml"],
    "format": "docker_compose",
    "keys": {
        "port": "8181",
        "image": "ipromknight/zilean:latest"
    },
    "default_port": 8181
}
```

### Phase 3: Post-Install Messaging

```bash
_post_install_info() {
    echo ""
    echo_warn "IMPORTANT: First run may take 24-48 hours for IMDB matching"
    echo_info "Zilean will return limited results until indexing completes"
    echo ""
    echo_info "Torznab URL: http://127.0.0.1:${app_port}"
    echo_info "Health check: http://127.0.0.1:${app_port}/healthchecks/ping"
    echo ""
    if [[ -f /install/.nginx.lock ]]; then
        echo_info "Web access: https://your-server/zilean/"
    fi
}
```

## Dependencies & Risks

- **Port conflict**: 8181 may be in use. Check with `ss`, warn and fallback to dynamic.
- **Docker already present**: `_install_docker()` handles this (existing pattern).
- **PostgreSQL memory**: `shm_size: 256m` is sufficient for indexer workload.
- **Prowlarr API stability**: v1 API is stable. Fail gracefully with manual fallback.
- **First-run duration**: IMDB matching can take 1.5+ days. Must warn user clearly.
- **Zilean scrape auth**: v3.2.1+ requires authentication for scrape endpoint (not anonymous). Default config should be fine.

### Edge Cases

- Zilean installed but Prowlarr installed later: User re-runs `zilean.sh` to trigger Prowlarr config
- Port 8181 occupied by another service: Fallback to dynamic port, update Prowlarr instructions
- PostgreSQL container fails to start: Health check prevents Zilean from starting, clean error message

## Sources & References

### Origin

- **Brainstorm document:** [docs/brainstorms/2026-03-07-zilean-brainstorm.md](../brainstorms/2026-03-07-zilean-brainstorm.md) - Key decisions: fixed port 8181, bundled PostgreSQL, no debrid config, Prowlarr auto-config.

### Internal References

- Docker template: `templates/template-docker.sh`
- Reference installer: `mdblistarr.sh` (closest pattern match)
- Prowlarr discovery: `mdblistarr.sh:457` (`_discover_arr_instances()`)
- Lingarr arr API pattern: `lingarr.sh` (`_discover_arr_api()`)
- Nginx utils: `lib/nginx-utils.sh`

### External References

- Zilean GitHub: https://github.com/iPromKnight/zilean
- Zilean docs: https://ipromknight.github.io/zilean/
- Zilean latest: v3.5.0 (April 2025)
- Prowlarr API: https://wiki.servarr.com/prowlarr/indexers (Generic Torznab)
- ElfHosted Zilean setup: https://docs.elfhosted.com/app/prowlarr/ (Torznab config reference)
- Prowlarr Torznab quirk: Enable "Remove year from search query" in synced Radarr indexer
