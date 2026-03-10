---
title: "feat: Add MediaFusion Docker installer"
type: feat
status: completed
date: 2026-03-07
deepened: 2026-03-07
origin: docs/brainstorms/2026-03-07-mediafusion-brainstorm.md
---

# feat: Add MediaFusion Docker Installer

## Enhancement Summary

**Deepened on:** 2026-03-07
**Sections enhanced:** 8
**Research sources:** Web (MediaFusion GitHub, configuration.md, deployment docs, Prowlarr wiki, ElfHosted), codebase (mdblistarr.sh, lingarr.sh, Docker template), Docker Compose multi-service best practices

### Key Improvements
1. Confirmed MediaFusion supports `HOST_URL` with subfolder path - eliminates need for `sub_filter`
2. Added `mediafusion.yaml` Prowlarr indexer import step to auto-configuration
3. Resource scaling: memory warnings, minimum RAM check, configurable worker threads
4. Container security hardening across all 5 services
5. First-run messaging: background scraper tasks need time, manual trigger option
6. Shared libraries (`lib/prowlarr-utils.sh`, `lib/debrid-utils.sh`) from Zilean/StremThru plans
7. Switched to hybrid networking (`network_mode: host` for app/worker, bridge for databases) + bind mounts for arr stack compatibility and backup support

## Overview

Create a Docker-based Swizzin installer for MediaFusion, a Python/FastAPI universal add-on for Stremio and Kodi with a native Torznab API for Prowlarr integration. This is the most complex of the three debrid indexer apps, requiring 5 containers: app, PostgreSQL, Redis, Dramatiq worker, and Browserless (headless Chrome).

## Problem Statement / Motivation

MediaFusion is the most comprehensive debrid-aware indexer available, aggregating 14+ torrent scrapers, Usenet sources, and HTTP streams into a single Torznab feed. It provides the broadest content coverage including live sports and regional content. Self-hosting enables full control over scraper configuration and eliminates dependency on shared instances.

## Proposed Solution

A `mediafusion.sh` installer following the Docker template pattern with an expanded compose file for the 5-service stack. Dynamic port allocation. Interactive debrid provider configuration. Subfolder nginx using `HOST_URL` env var (no sub_filter needed). Prowlarr auto-configuration with `mediafusion.yaml` indexer definition.

(see brainstorm: `docs/brainstorms/2026-03-07-mediafusion-brainstorm.md`)

## Technical Considerations

### Architecture

- **Five-container compose**:
  1. `mediafusion` - Main FastAPI app (port 8000 internal)
  2. `mediafusion-postgres` - PostgreSQL 18 primary database
  3. `mediafusion-redis` - Redis 7 cache + task queue
  4. `mediafusion-worker` - Dramatiq background task processor (same image, different entrypoint)
  5. `mediafusion-browserless` - Headless Chromium for scraping Cloudflare-protected sites
- **Networking**: `network_mode: host` for mediafusion + mediafusion-worker containers (matches mdblistarr/lingarr pattern — arr stack runs natively on host). PostgreSQL, Redis, and Browserless on internal bridge network with published localhost ports for app connectivity.
- **Port**: Dynamic via `port 10000 12000`
- **Web UI**: Full configuration interface for managing scrapers, debrid services, and content filters

#### Research Insights

**HOST_URL supports subfolder paths:** MediaFusion's `HOST_URL` environment variable accepts a full URL including path prefix (e.g., `https://server.example.com/mediafusion`). This means the app generates correct internal URLs for the subfolder context. No `sub_filter` rewrites needed - much simpler than Lingarr/MDBListarr's approach.

**Memory requirements:** Realistic breakdown:
| Container | Memory (idle) | Memory (active) |
|-----------|-------------|----------------|
| mediafusion | ~200MB | ~500MB |
| mediafusion-worker | ~150MB | ~400MB |
| mediafusion-postgres | ~100MB | ~300MB |
| mediafusion-redis | ~30MB | ~100MB |
| mediafusion-browserless | ~200MB | ~1GB+ (during scraping) |
| **Total** | **~680MB** | **~2.3GB** |

**`network_mode: host` for app containers:** The arr stack runs natively on the host — NOT in Docker. Using host networking for the app and worker containers:
1. Matches the established pattern (mdblistarr.sh, lingarr.sh both use `network_mode: host`)
2. App can reach Prowlarr and other host services on localhost directly
3. Internal services (postgres, redis, browserless) stay on bridge for isolation — published on localhost for the host-networked app containers to reach
4. Worker container also needs host networking to match the app's perspective

**Minimum system requirement:** 4GB RAM recommended. Add pre-install check:
```bash
total_mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
if (( total_mem_mb < 3072 )); then
    echo_warn "System has ${total_mem_mb}MB RAM. MediaFusion recommends 4GB+"
    if ! ask "Continue anyway?" N; then
        exit 0
    fi
fi
```

### Compose File Structure

```yaml
services:
  mediafusion:
    image: mhdzumair/mediafusion:latest
    container_name: mediafusion
    restart: unless-stopped
    network_mode: host
    environment:
      SECRET_KEY: <generated_32char>
      API_PASSWORD: <generated>
      POSTGRES_URI: "postgresql+asyncpg://mediafusion:<db_pass>@127.0.0.1:<pg_port>/mediafusion"
      REDIS_URL: "redis://127.0.0.1:<redis_port>"
      HOST_URL: "https://<server_hostname>/mediafusion"
      BROWSERLESS_URL: "http://127.0.0.1:<browser_port>"
    depends_on:
      mediafusion-postgres:
        condition: service_healthy
      mediafusion-redis:
        condition: service_healthy
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL

  mediafusion-worker:
    image: mhdzumair/mediafusion:latest
    container_name: mediafusion-worker
    restart: unless-stopped
    network_mode: host
    command: pipenv run dramatiq api.task -p 1 -t 4
    environment:
      SECRET_KEY: <same_as_app>
      POSTGRES_URI: <same_as_app>
      REDIS_URL: <same_as_app>
      BROWSERLESS_URL: "http://127.0.0.1:<browser_port>"
    depends_on:
      - mediafusion
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    deploy:
      resources:
        limits:
          memory: 1G

  mediafusion-postgres:
    image: postgres:18-alpine
    container_name: mediafusion-postgres
    restart: unless-stopped
    shm_size: 512m
    environment:
      POSTGRES_USER: mediafusion
      POSTGRES_PASSWORD: <generated>
      POSTGRES_DB: mediafusion
    volumes:
      - /opt/mediafusion/pgdata:/var/lib/postgresql/data
    ports:
      - "127.0.0.1:<pg_port>:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U mediafusion"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - mediafusion-net
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL

  mediafusion-redis:
    image: redis:7-alpine
    container_name: mediafusion-redis
    restart: unless-stopped
    command: redis-server --appendonly yes --maxmemory 256mb --maxmemory-policy allkeys-lru
    volumes:
      - /opt/mediafusion/redis:/data
    ports:
      - "127.0.0.1:<redis_port>:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - mediafusion-net
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL

  mediafusion-browserless:
    image: ghcr.io/browserless/chromium:latest
    container_name: mediafusion-browserless
    restart: unless-stopped
    environment:
      - TIMEOUT=60000
      - CONCURRENT=2
      - HEALTH=true
    ports:
      - "127.0.0.1:<browser_port>:3000"
    networks:
      - mediafusion-net
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    deploy:
      resources:
        limits:
          memory: 1536M

networks:
  mediafusion-net:
    driver: bridge
```

#### Research Insights

**Hybrid networking (host + bridge):**
- mediafusion and mediafusion-worker use `network_mode: host` for arr stack compatibility
- PostgreSQL, Redis, Browserless remain on bridge network for security isolation
- Bridge services publish ports on `127.0.0.1` only — accessible from host-networked containers
- Browserless also publishes a port (worker is on host networking and needs to reach it)

**Redis memory limit:** Add `--maxmemory 256mb --maxmemory-policy allkeys-lru` to prevent Redis from consuming unbounded memory. LRU eviction is appropriate for a cache.

**Browserless memory limit:** 1.5GB cap prevents headless Chrome from consuming all available RAM during heavy scraping.

**`shm_size: 512m`:** Larger than Zilean's 256m because MediaFusion has heavier query patterns (14+ scrapers writing results concurrently).

**`BROWSERLESS_URL`:** Critical env var missing from original plan. MediaFusion needs to know where Browserless is for Cloudflare bypass.

**`SECRET_KEY` must be exactly 32 characters:** Per MediaFusion docs. Use `openssl rand -hex 16` (produces 32 hex chars).

### Nginx Configuration

MediaFusion with `HOST_URL` subfolder - no `sub_filter` needed:

```nginx
location /mediafusion {
    return 301 /mediafusion/;
}

location ^~ /mediafusion/ {
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

    # Longer timeouts for scraper operations
    proxy_read_timeout 120s;
    proxy_send_timeout 120s;

    auth_basic "What's the password?";
    auth_basic_user_file /etc/htpasswd.d/htpasswd.<user>;
}

# Torznab API bypass for Prowlarr
location ^~ /mediafusion/torznab {
    auth_request off;
    proxy_pass http://127.0.0.1:<port>/torznab;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}

# Manifest endpoint bypass (Stremio needs unauthenticated access)
location ^~ /mediafusion/manifest.json {
    auth_request off;
    proxy_pass http://127.0.0.1:<port>/manifest.json;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

#### Research Insights

**No sub_filter needed:** `HOST_URL=https://server/mediafusion` tells MediaFusion to generate all internal URLs with the `/mediafusion` prefix. This is the cleanest approach.

**Longer proxy timeouts:** MediaFusion scraper operations can take 30-60+ seconds (especially when Browserless is resolving Cloudflare challenges). Default nginx timeout of 60s may not be enough.

**Manifest endpoint bypass:** If also using MediaFusion with Stremio (not just Torznab), the `/manifest.json` endpoint needs unauthenticated access for Stremio to discover the addon.

### Debrid Configuration

Uses shared `lib/debrid-utils.sh` from StremThru plan. Same interactive prompt:
- Provider selection (freeform with validation)
- API key input (silent)
- Stored in compose environment section
- Support `MEDIAFUSION_DEBRID_PROVIDER` and `MEDIAFUSION_DEBRID_KEY` env vars for unattended install

#### Research Insights

**MediaFusion debrid env vars:** The exact environment variable names for debrid in MediaFusion differ from StremThru. Check MediaFusion's `configuration.md` for the correct variable names. Likely patterns:
- `REALDEBRID_TOKEN`, `ALLDEBRID_TOKEN`, `TORBOX_TOKEN`, etc. (per-provider vars)
- The installer should map the generic provider+key input to the correct MediaFusion env var

### Security

- `SECRET_KEY` generated via `openssl rand -hex 16` (exactly 32 hex characters, as required)
- `API_PASSWORD` generated via `openssl rand -base64 16`
- PostgreSQL password generated via `openssl rand -base64 32 | tr -dc A-Za-z0-9 | cut -c -32`
- `chmod 600` on `docker-compose.yml`, `chown root:root`
- All containers: `no-new-privileges:true`
- All containers: `cap_drop: ALL`
- Browserless sandboxed in Docker bridge network (published on `127.0.0.1` only for host-networked worker access)
- Redis: no authentication needed (published on `127.0.0.1` only, no external access)

#### Research Insights

**Browserless isolation:** Browserless runs headless Chrome which is a high-risk attack surface. It stays on the bridge network with its port published only on `127.0.0.1` — accessible from host-networked worker container but not from external connections.

**Redis without auth:** Safe because Redis is only published on `127.0.0.1` within the bridge network. No external access possible.

### Resource Considerations

- 5 containers = ~2-3GB RAM active. Default `SYSTEMD_MEM_MAX=6G`
- Browserless (headless Chrome) capped at 1.5GB
- Dramatiq worker capped at 1GB
- First run: background scraper tasks need 30-60 minutes to populate initial results
- Pre-install RAM check (warn if <4GB)

### Prowlarr Integration

MediaFusion uses a custom Torznab indexer definition from `resources/yaml/mediafusion.yaml`:

1. Download `mediafusion.yaml` from MediaFusion GitHub repo
2. Place in Prowlarr's custom indexer definitions folder
3. Add MediaFusion indexer with the Torznab URL pointing to self-hosted instance
4. Alternative: Add as Generic Torznab (simpler but may miss some capabilities)

#### Research Insights

**Auto-configuration approach:**
```bash
_configure_prowlarr_mediafusion() {
    # Use shared _discover_prowlarr() from lib/prowlarr-utils.sh
    _discover_prowlarr || { _display_prowlarr_instructions; return; }

    # Option 1: Add as Generic Torznab (simpler, works for basic Torznab)
    _add_prowlarr_torznab "MediaFusion" "http://127.0.0.1:${app_port}" "${api_password}"

    # Option 2: Download and install mediafusion.yaml (more feature-complete)
    # This requires placing the YAML in Prowlarr's custom definitions dir
    # More fragile - skip for v1, offer as manual option
}
```

**Recommendation:** Start with Generic Torznab (simpler, no YAML management). Document the mediafusion.yaml approach as an advanced option in post-install instructions.

## System-Wide Impact

- **5 additional containers**: Significant resource usage. ~2-3GB RAM active.
- **PostgreSQL port conflict**: Docker bridge network prevents any conflicts with Zilean's postgres or system PostgreSQL.
- **Redis**: Isolated in Docker network, no conflict with system Redis.
- **Browserless**: Memory-hungry but capped at 1.5GB. Published on `127.0.0.1` only (required for host-networked worker access).
- **Disk space**: Docker images total ~2GB+ (MediaFusion ~500MB, Browserless ~500MB, PostgreSQL ~100MB, Redis ~30MB, duplicated MediaFusion for worker).

## Acceptance Criteria

- [x] `mediafusion.sh` installs all 5 containers via Docker Compose
- [x] Pre-install RAM check with warning if <4GB
- [x] Interactive debrid provider + API key prompt during install
- [x] All 5 containers healthy after install
- [x] `mediafusion.sh --update` pulls all images and recreates containers
- [x] `mediafusion.sh --remove` cleanly removes all 5 containers, images, volumes
- [x] Web UI accessible at `/mediafusion/` (no sub_filter needed with HOST_URL)
- [x] Torznab API accessible at `/mediafusion/torznab` without htpasswd auth
- [x] Prowlarr auto-configured as Generic Torznab (if installed)
- [x] Manual Prowlarr instructions displayed (always, including mediafusion.yaml advanced option)
- [x] Panel registration works
- [x] `swizzin-app-info` updated
- [x] SECRET_KEY exactly 32 chars, API_PASSWORD, DB password generated securely
- [x] Resource limits set on Browserless (1.5GB) and Dramatiq worker (1GB)
- [x] First-run messaging about scraper initialization delay
- [x] Idempotent: re-running preserves existing config and debrid credentials
- [x] Bind mounts at `/opt/mediafusion/` (not named volumes) for backup system compatibility
- [x] `network_mode: host` for app and worker containers (arr stack runs natively on host)
- [x] `cap_drop: ALL` on all containers

## Implementation Plan

### Phase 1: Prerequisites (shared libraries)

Ensure `lib/prowlarr-utils.sh` and `lib/debrid-utils.sh` exist from Zilean/StremThru implementations.

### Phase 2: Core Installer (`mediafusion.sh`)

**Files to create/modify:**

#### 2.1 Create `mediafusion.sh` (new file)

Based on `mdblistarr.sh` pattern with these customizations:
- App variables: `app_name="mediafusion"`, dynamic port, image `mhdzumair/mediafusion:latest`
- Pre-install RAM check (warn if <4GB)
- Source shared `lib/debrid-utils.sh` and `lib/prowlarr-utils.sh`
- `_prompt_debrid()`: Uses shared debrid utils, maps to MediaFusion-specific env vars
- `_install_mediafusion()`: Generate 5-service compose with hybrid networking (host for app/worker, bridge for databases), bind mounts, health checks, security hardening, all credentials
- `_systemd_mediafusion()`: Oneshot wrapper with `SYSTEMD_MEM_MAX=6G`, `SYSTEMD_CPU_QUOTA=600%`
- `_nginx_mediafusion()`: Subfolder proxy (no sub_filter), Torznab + manifest auth bypass, longer timeouts
- `_configure_prowlarr()`: Generic Torznab with API password
- `_remove_mediafusion()`: Stop all 5 containers, remove all images (5 images), `docker network rm`, cleanup volumes
- `_update_mediafusion()`: Pull all images, recreate all containers, prune old images

#### 2.2 Update `swizzin-app-info` (existing file)

Add to `APP_CONFIGS`:
```python
"mediafusion": {
    "config_paths": ["/opt/mediafusion/docker-compose.yml"],
    "format": "docker_compose",
    "keys": {
        "port": "PORT",
        "image": "mhdzumair/mediafusion:latest"
    }
}
```

### Phase 3: Post-Install Messaging

```bash
_post_install_info() {
    echo ""
    echo_info "MediaFusion installed with 5 containers"
    echo_warn "Background scrapers are initializing - results may be limited for 30-60 minutes"
    echo ""
    echo_info "Web UI: https://your-server/mediafusion/"
    echo_info "API Password: ${api_password}"
    echo_info "Torznab URL: http://127.0.0.1:${app_port}/torznab"
    echo ""
    echo_info "To manually trigger scrapers, visit the web UI scraper control page"
    echo ""
    # Prowlarr info from shared utils
}
```

## Dependencies & Risks

- **High resource usage**: 5 containers + headless Chrome. Pre-install RAM check mitigates surprise.
- **MediaFusion `HOST_URL`**: Confirmed via docs to support subfolder paths. No sub_filter needed.
- **Dramatiq worker entrypoint**: `pipenv run dramatiq api.task -p 1 -t 4` may change between versions. Monitor release notes.
- **Browserless image size**: ~500MB+. Slow initial pull on limited bandwidth. Consider progress indicator.
- **PostgreSQL 18**: Verify async SQLAlchemy compatibility. Fall back to `postgres:17-alpine` if issues arise.
- **First-run delay**: Background scraper tasks take 30-60 min. Clear messaging prevents user confusion.
- **MediaFusion debrid env var names**: Need to verify exact variable names per provider (may be `REALDEBRID_TOKEN` vs `RD_TOKEN` etc).

### Edge Cases

- System has <2GB RAM: Warn and exit (not enough for 5 containers)
- Browserless fails to start (ARM architecture?): MediaFusion works without it, just can't bypass Cloudflare
- PostgreSQL migration fails on update: Dramatiq worker won't start. Clear error via health check
- All 5 containers pulling simultaneously: Slow on limited bandwidth. Consider sequential pulls with progress
- User wants to use MediaFusion with Stremio AND Prowlarr: Manifest endpoint bypass handles Stremio access

## Sources & References

### Origin

- **Brainstorm document:** [docs/brainstorms/2026-03-07-mediafusion-brainstorm.md](../brainstorms/2026-03-07-mediafusion-brainstorm.md) - Key decisions: full stack in one compose, separate PostgreSQL, dynamic port, debrid prompt, subfolder nginx.

### Internal References

- Docker template: `templates/template-docker.sh`
- Reference installer: `mdblistarr.sh`
- Sub_filter pattern (not needed but reference): `lingarr.sh`, `newtarr.sh`
- Prowlarr discovery: `mdblistarr.sh:457`
- Shared libraries: `lib/prowlarr-utils.sh`, `lib/debrid-utils.sh`

### External References

- MediaFusion GitHub: https://github.com/mhdzumair/MediaFusion
- MediaFusion configuration: https://github.com/mhdzumair/MediaFusion/blob/main/docs/configuration.md
- MediaFusion Docker deployment: https://github.com/mhdzumair/MediaFusion/blob/main/deployment/docker-compose/README.md
- MediaFusion Torznab YAML: `resources/yaml/mediafusion.yaml` in the repo
- HOST_URL documentation: Required env var, supports HTTPS URLs with path prefixes
- SECRET_KEY requirement: Must be exactly 32 characters
- Prowlarr indexer API: https://wiki.servarr.com/prowlarr/indexers
- ElfHosted MediaFusion: https://docs.elfhosted.com/app/mediafusion/
