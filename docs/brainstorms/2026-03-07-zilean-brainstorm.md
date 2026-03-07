# Brainstorm: Zilean Installer

**Date:** 2026-03-07
**Status:** Final

## What We're Building

A Docker-based Swizzin installer for **Zilean** - a DMM (DebridMediaManager) hashlist Torznab indexer. Zilean indexes cached content shared by DMM users and exposes it as a Torznab-compatible API that integrates directly with Prowlarr and the *arr stack.

## Why Zilean

Normal torrent indexers only find public torrents. Zilean searches content that's already cached on debrid services (shared via DebridMediaManager), meaning instant availability without waiting for downloads. It can also scrape from Zurg instances and other Zilean instances.

## Technical Details

- **Image:** `ipromknight/zilean:latest`
- **Language:** C# / .NET
- **Port:** 8181 (fixed, well-known - other tools expect this port)
- **Database:** PostgreSQL 17-alpine (bundled in compose)
- **Web UI:** None (pure Torznab API)
- **Nginx mode:** Subfolder (`/zilean`) for API access
- **Health check:** `/healthchecks/ping`

### Compose Services

| Service | Image | Purpose |
|---------|-------|---------|
| zilean | ipromknight/zilean:latest | Main app |
| postgres | postgres:17-alpine | Database |

### Key Environment Variables

| Variable | Value | Notes |
|----------|-------|-------|
| `Zilean__Database__ConnectionString` | `Host=zilean-postgres;Database=zilean;Username=postgres;Password=<generated>` | Postgres connection |
| `POSTGRES_PASSWORD` | Auto-generated at install | Secure random password |
| `POSTGRES_USER` | `postgres` | Default |
| `POSTGRES_DB` | `zilean` | App database |
| `PGDATA` | `/var/lib/postgresql/data/pgdata` | Data path |

### Volumes

- `zilean_data` - App data
- `zilean_tmp` - Temp storage
- `postgres_data` - PostgreSQL data

### Prowlarr Integration

- **Type:** Generic Torznab indexer
- **URL:** `http://127.0.0.1:8181`
- **API Key:** None required
- **Special note:** Must enable "Remove year from search query" in synced Radarr indexer (Zilean Torznab API quirk)
- Auto-configure via Prowlarr API + display manual instructions

## Key Decisions

1. **Fixed port 8181** - Well-known port, other tools (Sootio, MediaFusion, Comet) expect Zilean on this port
2. **Bundled PostgreSQL** - Own postgres instance in compose for isolation
3. **No debrid config needed** - Zilean indexes DMM hashlists, not debrid APIs directly
4. **Subfolder nginx** - No web UI, just API access at `/zilean`
5. **Simplest of the three** - Good starting point for the stack

## Implementation Notes

- Follow Docker template pattern from `templates/template-docker.sh`
- Use `network_mode: host` with postgres binding to localhost
- Generate secure postgres password at install time
- Register in swizzin-app-info, backup system
- Auto-detect and configure Prowlarr if installed
