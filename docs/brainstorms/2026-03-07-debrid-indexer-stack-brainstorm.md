# Brainstorm: Debrid Indexer Stack (Zilean + StremThru + MediaFusion)

**Date:** 2026-03-07
**Status:** Draft

## What We're Building

Three independent Docker-based Swizzin installer scripts that together form a debrid-powered indexer stack for the *arr ecosystem:

1. **Zilean** - DMM (DebridMediaManager) hashlist Torznab indexer
2. **StremThru** - Debrid proxy/companion with Torznab endpoint
3. **MediaFusion** - Universal streaming addon with Torznab API

Each installer is standalone (install any combination), follows the existing Docker template pattern, and integrates with Prowlarr as a Torznab indexer.

## Why These Three

| App | Role in Stack | Torznab Endpoint | Unique Value |
|-----|--------------|------------------|--------------|
| **Zilean** | Indexes DMM-shared cached content | `http://127.0.0.1:8181` | Searches debrid hashlists that normal trackers don't have |
| **StremThru** | Debrid proxy + cached content search | `http://127.0.0.1:<port>/v0/torznab` | Aggregates cached content from your debrid service directly |
| **MediaFusion** | Full scraper engine + Torznab API | `http://127.0.0.1:<port>/torznab/...` | 14+ scraper sources, live sports, regional content |

**Together with Prowlarr:** All three feed Torznab results into Prowlarr, which distributes to Sonarr/Radarr. This gives the arr stack access to debrid-cached content that traditional torrent indexers miss.

## Per-App Technical Details

### 1. Zilean (`zilean.sh`)

- **Image:** `ipromknight/zilean:latest`
- **Language:** C# / .NET
- **Port:** 8181 (fixed, well-known)
- **Database:** PostgreSQL 17 (bundled in compose)
- **Web UI:** None (pure API)
- **Nginx mode:** Subfolder (`/zilean`) for API access
- **Compose services:** zilean + postgres
- **Key env vars:**
  - `Zilean__Database__ConnectionString` = postgres connection
  - `POSTGRES_PASSWORD` = generated at install
- **Prowlarr integration:** Generic Torznab indexer
  - URL: `http://127.0.0.1:8181`
  - Note: Must enable "Remove year from search query" in synced Radarr indexer
- **Complexity:** Low - simplest of the three

### 2. StremThru (`stremthru.sh`)

- **Image:** `muniftanjim/stremthru:latest`
- **Language:** Go
- **Port:** 8080 default (use dynamic port - 8080 conflicts easily)
- **Database:** SQLite (embedded, stored in data volume)
- **Web UI:** Minimal admin UI
- **Nginx mode:** Subfolder (`/stremthru`)
- **Compose services:** stremthru only (single container)
- **Key env vars:**
  - `STREMTHRU_AUTH` = `username:password`
  - `STREMTHRU_STORE_AUTH` = `user:provider:apikey` (debrid config)
- **Prowlarr integration:** Generic Torznab indexer
  - URL: `http://127.0.0.1:<port>/v0/torznab`
- **Debrid config:** Installer prompts for provider + API key
- **Complexity:** Low - single container, minimal deps

### 3. MediaFusion (`mediafusion.sh`)

- **Image:** `mhdzumair/mediafusion:latest`
- **Language:** Python / FastAPI
- **Port:** 8000 default (use dynamic port)
- **Database:** PostgreSQL 18 + Redis (bundled in compose)
- **Web UI:** Full configuration UI
- **Nginx mode:** Subfolder (`/mediafusion`)
- **Compose services:** mediafusion, postgres, redis, dramatiq-worker, browserless (5 containers)
- **Key env vars:**
  - `SECRET_KEY` = generated at install
  - `API_PASSWORD` = generated at install
  - `POSTGRES_URI` = postgres connection
  - `REDIS_URL` = redis connection
  - Debrid API keys (prompted at install)
- **Prowlarr integration:** Custom Torznab indexer (mediafusion.yaml definition)
  - URL: `http://127.0.0.1:<port>` + manifest path
- **Debrid config:** Installer prompts for provider + API key
- **Complexity:** High - 5 containers, multiple databases, workers

## Key Decisions

### 1. Independent Installers (not a single mega-script)
Each app gets its own `<app>.sh` script following the standard Docker template. Users can install any combination. This follows YAGNI and existing Swizzin conventions.

### 2. Subfolder Nginx Mode for All Three
- Zilean has no web UI - subfolder exposes the API
- StremThru has minimal UI - subfolder works fine
- MediaFusion has full UI - subfolder works, no DNS needed
- Consistent with existing Docker apps (lingarr, mdblistarr, etc.)

### 3. Prowlarr Integration: Auto-configure + Display Info
- Detect Prowlarr via lock file (`/install/.prowlarr.lock`)
- Read API key from `/home/<user>/.config/Prowlarr/config.xml`
- Add indexer via Prowlarr API (`POST /api/v1/indexer`)
- Also print Torznab URL/instructions for manual setup
- If Prowlarr not installed, just display info

### 4. Debrid Service: Prompt at Install Time
- StremThru and MediaFusion need debrid credentials
- Installer presents menu: Real-Debrid, AllDebrid, TorBox, Premiumize, etc.
- User enters API key interactively
- Credentials stored in compose env with `chmod 600`
- Zilean doesn't need debrid config (it indexes DMM hashlists)

### 5. PostgreSQL Isolation
- Zilean and MediaFusion both need PostgreSQL but get SEPARATE instances
- Each app's postgres runs in its own compose with its own volume
- Avoids version conflicts and simplifies removal
- Trade-off: more RAM usage, but cleaner isolation

### 6. Dynamic Ports (except Zilean)
- Zilean: Fixed 8181 (well-known, other tools expect it)
- StremThru: Dynamic via `port 10000 12000` (8080 conflicts too easily)
- MediaFusion: Dynamic via `port 10000 12000`
- All bind to `127.0.0.1` only, nginx handles external access

## Integration Flow

```
                    Prowlarr (indexer manager)
                   /         |              \
                  /          |               \
           Zilean      StremThru        MediaFusion
        (DMM hashes)  (debrid cache)  (14+ scrapers)
             |              |               |
        PostgreSQL     SQLite/data    PostgreSQL + Redis
                            |          + Dramatiq workers
                       Debrid API      + Browserless
                    (RD/AD/TB/etc)

    Prowlarr distributes results to:
    Sonarr -> qBittorrent/rclone -> Plex/Jellyfin/Emby
    Radarr -> qBittorrent/rclone -> Plex/Jellyfin/Emby
```

## Open Questions

_None - all key decisions resolved._

## Implementation Order

1. **Zilean** first (simplest, 2 containers, no debrid config)
2. **StremThru** second (single container, debrid prompt)
3. **MediaFusion** third (most complex, 5 containers)

## Next Steps

Run `/ce:plan` to create detailed implementation plan, then use `/new-installer` skill with Docker template for each app.
