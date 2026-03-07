# Brainstorm: StremThru Installer

**Date:** 2026-03-07
**Status:** Final

## What We're Building

A Docker-based Swizzin installer for **StremThru** - a Go-based debrid proxy/companion that provides a Torznab endpoint for searching cached content on debrid services. It bridges the gap between debrid cloud storage and the *arr ecosystem.

## Why StremThru

StremThru directly queries your debrid service's cache and exposes results as a Torznab feed. Unlike Zilean (which indexes DMM-shared hashes), StremThru searches what's actually cached on YOUR debrid account and available debrid-wide cached content.

## Technical Details

- **Image:** `muniftanjim/stremthru:latest`
- **Language:** Go
- **Port:** Dynamic via `port 10000 12000` (default 8080 conflicts easily)
- **Database:** SQLite (embedded, stored in data volume)
- **Web UI:** Minimal admin interface
- **Nginx mode:** Subfolder (`/stremthru`)

### Compose Services

| Service | Image | Purpose |
|---------|-------|---------|
| stremthru | muniftanjim/stremthru:latest | Main app (single container) |

### Key Environment Variables

| Variable | Value | Notes |
|----------|-------|-------|
| `STREMTHRU_AUTH` | `username:password` | App authentication |
| `STREMTHRU_STORE_AUTH` | `user:provider:apikey` | Debrid service credentials |

### Volumes

- `./data:/app/data` - SQLite database + app data

### Debrid Configuration

Installer prompts for:
1. **Debrid provider** - Menu: Real-Debrid, AllDebrid, TorBox, Premiumize, OffCloud, Debrid-Link, EasyDebrid
2. **API key** - User enters their debrid API key
3. Stored as `STREMTHRU_STORE_AUTH=<username>:<provider>:<apikey>` in compose env

### Prowlarr Integration

- **Type:** Generic Torznab indexer
- **URL:** `http://127.0.0.1:<port>/v0/torznab`
- **API Key:** Uses STREMTHRU_AUTH credentials
- Auto-configure via Prowlarr API + display manual instructions

## Key Decisions

1. **Dynamic port** - 8080 is commonly used, avoid conflicts
2. **Single container** - Simplest possible deployment, SQLite embedded
3. **Debrid prompt at install** - Interactive menu for provider selection
4. **Subfolder nginx** - Minimal UI accessible at `/stremthru`
5. **Credential security** - `chmod 600` on compose file / env file

## Implementation Notes

- Follow Docker template pattern from `templates/template-docker.sh`
- Single container, no database service needed (SQLite in volume)
- Port mapping: `127.0.0.1:<dynamic>:8080`
- Use `user: "${uid}:${gid}"` for proper file permissions
- Generate random password for STREMTHRU_AUTH at install
- Prompt for debrid provider and API key interactively
- Register in swizzin-app-info, backup system
- Auto-detect and configure Prowlarr if installed
