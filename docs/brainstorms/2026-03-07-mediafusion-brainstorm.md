# Brainstorm: MediaFusion Installer

**Date:** 2026-03-07
**Status:** Final

## What We're Building

A Docker-based Swizzin installer for **MediaFusion** - a Python/FastAPI universal add-on for Stremio and Kodi that also exposes a native Torznab API for direct integration with Prowlarr, Sonarr, and Radarr. It's the most feature-rich of the three debrid indexer apps.

## Why MediaFusion

MediaFusion aggregates 14+ torrent scrapers, Usenet sources, HTTP streaming, and debrid cache lookups into a single service with a Torznab API. It provides the broadest content coverage of any single indexer - including live sports, regional content (Tamil, Hindi, Malayalam), and standard movies/TV.

## Technical Details

- **Image:** `mhdzumair/mediafusion:latest`
- **Language:** Python / FastAPI
- **Port:** Dynamic via `port 10000 12000` (default 8000)
- **Databases:** PostgreSQL 18 + Redis (both bundled in compose)
- **Web UI:** Full configuration interface
- **Nginx mode:** Subfolder (`/mediafusion`)

### Compose Services (5 containers)

| Service | Image | Purpose |
|---------|-------|---------|
| mediafusion | mhdzumair/mediafusion:latest | Main FastAPI app |
| postgres | postgres:18-alpine | Primary database |
| redis | redis:7-alpine | Cache + task queue |
| dramatiq-worker | mhdzumair/mediafusion:latest | Background task processor |
| browserless | ghcr.io/browserless/chromium | Headless browser for scraping |

### Key Environment Variables

| Variable | Value | Notes |
|----------|-------|-------|
| `SECRET_KEY` | Auto-generated | App encryption key |
| `API_PASSWORD` | Auto-generated | API endpoint protection |
| `POSTGRES_URI` | `postgresql+asyncpg://mediafusion:mediafusion@postgres:5432/mediafusion` | DB connection |
| `REDIS_URL` | `redis://redis:6379` | Cache connection |
| Debrid keys | User-provided | Per-provider API keys |

### Volumes

- `postgres_data` - PostgreSQL data
- `redis_data` - Redis AOF persistence

### Debrid Configuration

Installer prompts for:
1. **Debrid provider** - Menu: Real-Debrid, AllDebrid, TorBox, Premiumize, Debrid-Link
2. **API key** - User enters their debrid API key
3. Stored in compose environment section

### Prowlarr Integration

- **Type:** Custom Torznab indexer (may need mediafusion.yaml definition)
- **URL:** `http://127.0.0.1:<port>` + configured manifest Torznab path
- **Setup:** Import mediafusion.yaml into Prowlarr, configure with manifest URL
- Auto-configure via Prowlarr API + display manual instructions

### Resource Considerations

- 5 containers = significant memory footprint
- Browserless (headless Chrome) is the heaviest component
- Dramatiq workers configurable: `-p 1 -t 4` (1 process, 4 threads)
- Consider systemd MemoryMax limit (default 4G from template)
- First run: scraped results not immediately available until background tasks complete

## Key Decisions

1. **Full stack in one compose** - All 5 services bundled for self-containment
2. **Separate PostgreSQL from Zilean** - Own postgres instance, avoids version conflicts
3. **Dynamic port** - Avoid conflicts with other services
4. **Debrid prompt at install** - Interactive menu for provider + API key
5. **Subfolder nginx** - Full config UI accessible at `/mediafusion`
6. **Most complex installer** - Build last after Zilean and StremThru

## Implementation Notes

- Follow Docker template pattern from `templates/template-docker.sh`
- Dramatiq worker uses same image as main app with different entrypoint
- Browserless needs `--no-sandbox` flag for Docker
- Redis with AOF persistence for task queue durability
- Generate SECRET_KEY and API_PASSWORD with `openssl rand`
- Need extensive nginx sub_filter if app doesn't support base URL prefix
- May need to investigate MediaFusion's base URL / prefix support
- Register in swizzin-app-info, backup system
- Auto-detect and configure Prowlarr if installed
- Consider offering to manually trigger initial scrape tasks post-install
