---
title: "feat: Add StremThru Docker installer"
type: feat
status: active
date: 2026-03-07
deepened: 2026-03-07
origin: docs/brainstorms/2026-03-07-stremthru-brainstorm.md
---

# feat: Add StremThru Docker Installer

## Enhancement Summary

**Deepened on:** 2026-03-07
**Sections enhanced:** 6
**Research sources:** Web (StremThru GitHub, Docker Hub, ElfHosted docs, StremThru official docs), codebase (mdblistarr.sh, Docker template), Docker security best practices

### Key Improvements
1. Simplified debrid prompt: freeform provider name + API key (no numbered menu)
2. Shared `lib/debrid-utils.sh` proposal for reuse between StremThru and MediaFusion
3. Container security hardening (read-only rootfs, no-new-privileges, tmpfs)
4. StremThru subfolder support verified via X-Forwarded headers
5. Concrete Prowlarr Torznab payload with Basic auth credentials
6. Switched to `network_mode: host` + bind mounts for arr stack compatibility and backup support

## Overview

Create a Docker-based Swizzin installer for StremThru, a Go-based debrid proxy/companion that provides a Torznab endpoint (`/v0/torznab`) for searching cached content on debrid services. Single-container deployment with SQLite storage.

## Problem Statement / Motivation

Debrid services cache vast libraries of content, but the *arr stack has no native way to search what's cached. StremThru acts as a bridge - querying debrid caches and exposing results as a standard Torznab feed that Prowlarr can consume. Unlike Zilean (which indexes DMM-shared hashes), StremThru searches content cached on the debrid service itself.

## Proposed Solution

A single `stremthru.sh` installer following the Docker template pattern. Single container (StremThru only - uses embedded SQLite). Dynamic port allocation. Interactive debrid provider/API key prompt at install time. Subfolder nginx. Prowlarr auto-configuration.

(see brainstorm: `docs/brainstorms/2026-03-07-stremthru-brainstorm.md`)

## Technical Considerations

### Architecture

- **Single container**: StremThru is self-contained with embedded SQLite - no external database needed
- **Networking**: `network_mode: host` (matches mdblistarr/lingarr pattern — arr stack runs natively on host, not in Docker). App listens on `127.0.0.1:<dynamic_port>` directly.
- **Port**: Dynamic via `port 10000 12000` (default 8080 conflicts easily with other services)
- **Web UI**: Minimal admin interface - subfolder access

**`network_mode: host` rationale:** The arr stack (Prowlarr, Sonarr, Radarr) runs natively on the host — NOT in Docker. Using host networking:
1. Matches the established pattern (mdblistarr.sh, lingarr.sh both use `network_mode: host`)
2. App can reach any host service on localhost without bridge networking indirection
3. Prowlarr connects to StremThru at `127.0.0.1:<port>` directly
4. Simpler than port mapping for a single-container app

#### Research Insights

**Simplest of the three architecturally:** Single container, no database service, embedded SQLite. This makes it the fastest to install and lowest resource usage. Good second installer after Zilean.

**StremThru subfolder support:** StremThru is a Go app that respects `X-Forwarded-*` headers. The ElfHosted deployment confirms it works behind a reverse proxy without path rewriting issues. No `sub_filter` needed.

### Debrid Service Configuration

Interactive prompt at install time, simplified from the original 7-option menu:

```bash
_prompt_debrid() {
    # Skip if env vars set (unattended install)
    if [[ -n "${STREMTHRU_PROVIDER:-}" && -n "${STREMTHRU_API_KEY:-}" ]]; then
        debrid_provider="$STREMTHRU_PROVIDER"
        debrid_key="$STREMTHRU_API_KEY"
        return
    fi

    # Skip if already configured (re-run protection)
    if [[ -f "${app_dir}/docker-compose.yml" ]] && grep -q "STREMTHRU_STORE_AUTH" "${app_dir}/docker-compose.yml" 2>/dev/null; then
        echo_info "Debrid credentials already configured, keeping existing"
        return
    fi

    echo_info "Supported providers: realdebrid, alldebrid, torbox, premiumize, offcloud, debridlink, easydebrid"
    echo_query "Enter debrid provider name:"
    read -r debrid_provider </dev/tty

    echo_query "Enter your ${debrid_provider} API key:"
    read -rs debrid_key </dev/tty
    echo "" # newline after silent read
}
```

#### Research Insights

**Simplify the menu:** A numbered menu of 7 providers adds complexity for little benefit. Users who install a debrid indexer already know their provider name. Freeform input with validation is simpler:

```bash
local valid_providers="realdebrid alldebrid torbox premiumize offcloud debridlink easydebrid"
if [[ ! " $valid_providers " =~ " $debrid_provider " ]]; then
    echo_error "Unknown provider: $debrid_provider"
    echo_info "Valid: $valid_providers"
    exit 1
fi
```

**Shared library opportunity:** Extract debrid prompting to `lib/debrid-utils.sh` for reuse in MediaFusion:
- `_prompt_debrid_provider()` - returns provider name + API key
- `_validate_debrid_provider()` - checks against known provider list

### Compose File Structure

```yaml
services:
  stremthru:
    image: muniftanjim/stremthru:latest
    container_name: stremthru
    restart: unless-stopped
    network_mode: host
    user: "<uid>:<gid>"
    environment:
      STREMTHRU_AUTH: "<username>:<generated_password>"
      STREMTHRU_STORE_AUTH: "<username>:<provider>:<api_key>"
    volumes:
      - /opt/stremthru/data:/app/data
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    read_only: true
    tmpfs:
      - /tmp
```

#### Research Insights

**`user: "${uid}:${gid}"`:** Essential for SQLite file ownership. Without this, the data volume files would be owned by root inside the container, causing permission issues.

**`read_only: true`:** StremThru writes only to `/app/data` (SQLite) and `/tmp`. Making the container filesystem read-only improves security.

**No health check in compose:** StremThru doesn't expose a dedicated health endpoint. Use Docker's default restart policy instead. Could add a TCP health check:
```yaml
healthcheck:
  test: ["CMD-SHELL", "wget -q --spider http://localhost:8080/ || exit 1"]
  interval: 30s
  timeout: 10s
  retries: 3
```

### Nginx Configuration

Subfolder proxy with API auth bypass for Torznab:

```nginx
location /stremthru {
    return 301 /stremthru/;
}

location ^~ /stremthru/ {
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

    auth_basic "What's the password?";
    auth_basic_user_file /etc/htpasswd.d/htpasswd.<user>;
}

# Torznab API bypass for Prowlarr (localhost access)
location ^~ /stremthru/v0/torznab {
    auth_request off;
    proxy_pass http://127.0.0.1:<port>/v0/torznab;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

#### Research Insights

**No sub_filter needed:** StremThru's Go web server handles proxied requests correctly with standard `X-Forwarded-*` headers. The ElfHosted deployment confirms reverse proxy compatibility.

**Torznab auth:** StremThru's Torznab endpoint at `/v0/torznab` uses `STREMTHRU_AUTH` credentials for authentication. Prowlarr will need these credentials configured. The nginx bypass removes htpasswd auth, but StremThru's own auth still applies.

### Security

- `STREMTHRU_AUTH` password auto-generated via `openssl rand`
- Debrid API key read with `-rs` flag (silent input, not echoed to terminal)
- `chmod 600` on `docker-compose.yml` (contains debrid credentials)
- `chown root:root` on compose file
- Prowlarr API key via `curl --config` pattern (hidden from `ps`)
- Container: `read_only`, `no-new-privileges`, `cap_drop: ALL`, non-root user

#### Research Insights

**Debrid API key sensitivity:** The debrid API key in `STREMTHRU_STORE_AUTH` grants full access to the user's debrid account. Extra care:
1. `read -rs` for input (no echo, no history)
2. Compose file `chmod 600` + `chown root:root`
3. Never log the key (check that `set -x` debug mode doesn't expose it)
4. On removal with purge, securely delete: `shred -u` the compose file before `rm -rf`

### Prowlarr Integration

Same `_configure_prowlarr()` pattern as Zilean (using shared `lib/prowlarr-utils.sh`) but with:
- Torznab URL: `http://127.0.0.1:<port>/v0/torznab`
- API Key: StremThru auth credentials (username:password from `STREMTHRU_AUTH`)
- No special quirks (unlike Zilean's year removal)

#### Research Insights

**Prowlarr Torznab with Basic Auth:** StremThru requires authentication on its Torznab endpoint. When adding to Prowlarr:
- URL: `http://127.0.0.1:<port>/v0/torznab`
- API Key: The `<password>` portion of `STREMTHRU_AUTH`
- Or configure Basic Auth in the Prowlarr indexer settings

The auto-configure function should pass the auth credentials in the Prowlarr API payload.

## Acceptance Criteria

- [ ] `stremthru.sh` installs StremThru via Docker Compose
- [ ] Interactive debrid provider + API key prompt during install
- [ ] Debrid provider validated against known provider list
- [ ] `stremthru.sh --update` pulls latest image and recreates container
- [ ] `stremthru.sh --remove` cleanly removes container, image, configs
- [ ] `stremthru.sh --remove` with purge securely removes data directory
- [ ] Nginx subfolder at `/stremthru` proxies to StremThru (no sub_filter needed)
- [ ] Torznab API accessible at `/stremthru/v0/torznab` without htpasswd auth
- [ ] Prowlarr auto-configured (if installed) + manual instructions displayed
- [ ] Panel registration works
- [ ] `swizzin-app-info` updated
- [ ] Debrid credentials stored securely (`chmod 600`, `chown root:root`)
- [ ] Idempotent: re-running preserves existing debrid config
- [ ] Unattended install via `STREMTHRU_PROVIDER` + `STREMTHRU_API_KEY` env vars
- [ ] Bind mounts at `/opt/stremthru/` (not named volumes) for backup system compatibility
- [ ] `network_mode: host` used (arr stack runs natively on host)

## Implementation Plan

### Phase 1: Shared Libraries

#### 1.1 Create `lib/debrid-utils.sh` (new file)

Reusable debrid prompting for StremThru and MediaFusion:
```bash
_prompt_debrid_provider() {
    # Sets: debrid_provider, debrid_key
    # Supports env var override for unattended install
    # Validates provider name
}
```

#### 1.2 Create `lib/prowlarr-utils.sh` (new file - shared with Zilean)

If not already created during Zilean implementation.

### Phase 2: Core Installer (`stremthru.sh`)

#### 2.1 Create `stremthru.sh` (new file)

Based on `mdblistarr.sh` pattern:
- App variables: `app_name="stremthru"`, dynamic port, image `muniftanjim/stremthru:latest`
- Source `lib/debrid-utils.sh` and `lib/prowlarr-utils.sh`
- `_prompt_debrid()`: Calls shared `_prompt_debrid_provider()`
- `_install_stremthru()`: Generate single-service compose, `user: "${uid}:${gid}"`, port mapping
- `_systemd_stremthru()`: Standard oneshot wrapper
- `_nginx_stremthru()`: Subfolder proxy with `/v0/torznab` auth bypass
- `_configure_prowlarr()`: Uses shared Prowlarr utils with StremThru Torznab URL
- `_remove_stremthru()`: Stop container, `shred` compose file if purging, cleanup
- `_update_stremthru()`: Pull latest, recreate

#### 2.2 Update `swizzin-app-info` (existing file)

Add to `APP_CONFIGS`:
```python
"stremthru": {
    "config_paths": ["/opt/stremthru/docker-compose.yml"],
    "format": "docker_compose",
    "keys": {
        "port": "PORT",
        "image": "muniftanjim/stremthru:latest"
    }
}
```

## Dependencies & Risks

- **Debrid API key validity**: Can't verify at install time without making API call. Accept and let StremThru handle validation.
- **Port 8080 conflict**: Dynamic allocation avoids this.
- **File permissions**: `user: "${uid}:${gid}"` ensures SQLite data is owned by the Swizzin user.
- **StremThru base URL**: Confirmed working via ElfHosted - respects X-Forwarded headers, no sub_filter needed.
- **StremThru Torznab auth**: The `/v0/torznab` endpoint requires `STREMTHRU_AUTH` credentials. Prowlarr must be configured with matching credentials.

### Edge Cases

- User enters wrong debrid provider name: Validated against known list, clear error
- Debrid API key expired/invalid: StremThru will report errors in its logs, installer can't verify
- Re-run after debrid provider change: Config guard preserves existing, user must manually edit compose

## Sources & References

### Origin

- **Brainstorm document:** [docs/brainstorms/2026-03-07-stremthru-brainstorm.md](../brainstorms/2026-03-07-stremthru-brainstorm.md) - Key decisions: dynamic port, single container, debrid prompt at install, Prowlarr auto-config.

### Internal References

- Docker template: `templates/template-docker.sh`
- Reference installer: `mdblistarr.sh`
- Prowlarr discovery pattern: `mdblistarr.sh:457`

### External References

- StremThru GitHub: https://github.com/MunifTanjim/stremthru
- StremThru docs: https://docs.stremthru.13377001.xyz/getting-started/installation
- StremThru Docker Hub: https://hub.docker.com/r/muniftanjim/stremthru
- StremThru Torznab: `/v0/torznab` endpoint (confirmed via ElfHosted: `http://elfhosted-internal.stremthru/v0/torznab`)
- ElfHosted StremThru: https://docs.elfhosted.com/app/stremthru/
