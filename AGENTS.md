# AGENTS.md

Swizzin installer scripts - bash installation scripts for integrating applications into the [Swizzin](https://swizzin.ltd/) self-hosted media server management platform.

## Quick Reference

| Task                        | Documentation                                                                                                 |
| --------------------------- | ------------------------------------------------------------------------------------------------------------- |
| Create a new installer      | Start with a [template](docs/templates.md), follow the [maintenance checklist](docs/maintenance-checklist.md) |
| Understand script structure | [Architecture](docs/architecture.md)                                                                          |
| Code style questions        | [Coding Standards](docs/coding-standards.md)                                                                  |
| Environment variables       | [Environment Variables](docs/environment-variables.md)                                                        |

## App-Specific Documentation

- [Docker Apps](docs/apps/docker-apps.md) - Lingarr, LibreTranslate
- [Media Servers](docs/apps/media-servers.md) - Plex, Emby, Jellyfin subdomain scripts
- [Organizr](docs/apps/organizr.md) - SSO gateway
- [Multi-Instance](docs/apps/multi-instance.md) - Sonarr/Radarr instance management
- [Zurg](docs/apps/zurg.md) - Real-Debrid WebDAV + rclone

## Subsystems

- [Backup System](docs/subsystems/backup.md) - BorgBackup
- [Watchdog](docs/subsystems/watchdog.md) - Service health monitoring
- [App Info Tool](docs/subsystems/app-info.md) - swizzin-app-info utility

## Testing

No automated tests. Scripts must be tested on a Swizzin-installed system.

```bash
bash plex.sh                                          # Interactive
PLEX_DOMAIN="plex.example.com" bash plex.sh --subdomain  # Automated
```
