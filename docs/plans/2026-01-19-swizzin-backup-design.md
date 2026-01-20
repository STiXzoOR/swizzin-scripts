# Swizzin Backup System Design

**Date:** 2026-01-19
**Status:** Approved

## Overview

Automated backup system for Swizzin servers with dual-destination redundancy, dynamic app discovery, and intelligent retention.

## Goals

- Backup all Swizzin configurations, databases, and app data (excluding media files)
- Dual destinations: Google Drive (offsite) + Windows Server (fast restore)
- Dynamic discovery of installed apps via lock files
- Handle multi-instance \*arr apps and custom paths
- Preserve symlink structures for \*arr root folders
- GFS rotation to manage storage within 15GB Google Drive limit
- Pushover notifications for backup status

## Architecture

### Backup Tool: Restic

- Built-in deduplication (critical for 15GB limit)
- Strong encryption (AES-256)
- Native support for rclone backend (Google Drive) and SFTP (Windows)
- GFS retention via `forget --keep-*` policies

### Destinations

1. **Google Drive** - via rclone backend
2. **Windows Server 2025** - via SFTP (OpenSSH)

### Directory Structure

```
/opt/swizzin-extras/backup/
├── swizzin-backup.sh           # Main backup script
├── swizzin-restore.sh          # Restore script
├── backup.conf                 # Main configuration
├── app-registry.conf           # App → path mappings
├── excludes.conf               # Global exclusions
├── hooks/
│   ├── pre-backup.sh           # Stop services, prep DBs
│   └── post-backup.sh          # Restart services, cleanup
├── manifests/                  # Generated at runtime
│   ├── symlinks-YYYYMMDD.json  # Symlink structure
│   ├── swizdb-YYYYMMDD.json    # swizdb export
│   └── paths-YYYYMMDD.json     # Custom path mappings
└── logs/
    └── backup.log              # Backup logs
```

## Dynamic App Discovery

### Lock File Pattern

Lock files at `/install/.<appname>.lock` are the source of truth:

- Base app: `/install/.sonarr.lock`
- Multi-instance: `/install/.sonarr_4k.lock` (underscore separator)

### App Registry

Maps apps to their file paths:

```bash
# APP|CONFIG_PATHS|DATA_PATHS|EXCLUDES|TYPE
sonarr|/home/*/.config/Sonarr/,/home/*/.config/sonarr-*/|/opt/Sonarr/|*.pid,logs/*|arr
radarr|/home/*/.config/Radarr/,/home/*/.config/radarr-*/|/opt/Radarr/|*.pid,logs/*|arr
plex|/var/lib/plexmediaserver/||Cache/*,Codecs/*|mediaserver
emby|/var/lib/emby/||cache/*,transcodes/*|mediaserver
jellyfin|/var/lib/jellyfin/,/etc/jellyfin/||cache/*,transcodes/*|mediaserver
# ... etc
```

### Dynamic Path Resolution

For apps with configurable paths:

- **Zurg**: `swizdb get zurg/mount_point`
- **Decypharr**: `swizdb get decypharr/mount_path`, config.json → downloads_path
- **\*arr root folders**: SQLite query on RootFolders table

## Backup Scope

### Full Backup (configs + data + databases)

| Category       | Paths                                                               |
| -------------- | ------------------------------------------------------------------- |
| Swizzin core   | `/etc/swizzin/`, `/opt/swizzin-extras/`, `/opt/swizzin-extras/db/`                |
| Lock files     | `/install/.*.lock`                                                  |
| Nginx          | `/etc/nginx/` (apps, sites, snippets, ssl, htpasswd)                |
| Let's Encrypt  | `/etc/letsencrypt/`                                                 |
| Systemd        | `/etc/systemd/system/*.service`                                     |
| Cron           | `/etc/cron.d/`, `/var/spool/cron/crontabs/`                         |
| \*arr configs  | `/home/*/.config/{Sonarr,Radarr,sonarr-*,radarr-*,...}/`            |
| \*arr binaries | `/opt/{Sonarr,Radarr,Lidarr,...}/`                                  |
| Custom apps    | notifiarr, decypharr, zurg, huntarr, byparr, subgen, seerr, etc.    |
| Panel          | `/opt/swizzin/core/custom/profiles.py`                              |
| System mods    | `/etc/hosts`, `/etc/fuse.conf`, `/usr/local/share/ca-certificates/` |

### Media Servers (config + DB only)

| App      | Include                                | Exclude                                 |
| -------- | -------------------------------------- | --------------------------------------- |
| Plex     | `/var/lib/plexmediaserver/`            | Cache/, Codecs/, Crash Reports/, \*.bif |
| Emby     | `/var/lib/emby/`                       | cache/, transcodes/                     |
| Jellyfin | `/var/lib/jellyfin/`, `/etc/jellyfin/` | cache/, transcodes/, log/               |

### Symlink Structures

\*arr root folders containing symlinks to Zurg mount are backed up:

- Direct backup (restic preserves symlinks)
- JSON manifest for visibility and potential path remapping

### Decypharr Downloads

Downloads path read from config.json and included in backup.

## Critical Exclusions

```bash
# VFS Caches (256GB+)
/home/*/.cache/rclone/**
*/zurg/data/rclone-cache/**

# Media server caches
*/Plex Media Server/Cache/**
*/emby/cache/**
*/jellyfin/cache/**

# Mount points
/mnt/zurg/**
/mnt/realdebrid/**

# Temp/regenerable
*.pid, *.tmp, */Backups/**, */MediaCover/**
```

## Retention Policy (GFS)

- **Daily**: Keep 7
- **Weekly**: Keep 4
- **Monthly**: Keep 3
- Total: ~14 snapshots max

With deduplication, estimated storage: 3-10GB initial, 50-200MB incremental.

## Execution Flow

1. **Initialize** - Load config, verify repos
2. **Discover** - Scan lock files, map paths, build include/exclude lists
3. **Pre-backup hooks** - Stop services if needed
4. **Backup** - Parallel to both destinations
5. **Prune** - Apply GFS retention
6. **Post-backup hooks** - Restart services
7. **Notify** - Pushover success/failure

## Restore Process

### Modes

1. **Full restore** - Rebuild entire server
2. **App restore** - Single app recovery
3. **Config restore** - Configs only, preserve DBs
4. **Browse files** - Interactive selection

### Restore Flow

1. Choose source (Google Drive or Windows Server)
2. List/select snapshot
3. Stop services
4. Restore files
5. Fix permissions
6. Reload systemd, restart services
7. Verify

## CLI Interface

### Backup

```bash
swizzin-backup.sh run              # Run full backup
swizzin-backup.sh run --gdrive     # Google Drive only
swizzin-backup.sh run --sftp       # Windows Server only
swizzin-backup.sh status           # Show status
swizzin-backup.sh list             # List snapshots
swizzin-backup.sh discover         # Preview what would be backed up
swizzin-backup.sh verify           # Verify integrity
swizzin-backup.sh init             # Initialize repos
swizzin-backup.sh test             # Test connectivity
```

### Restore

```bash
swizzin-restore.sh                              # Interactive
swizzin-restore.sh --source gdrive --app sonarr # Single app
swizzin-restore.sh --snapshot latest --dry-run  # Preview
```

## Installation

Interactive installer (`swizzin-backup-install.sh`):

1. Install dependencies (restic, rclone latest release, jq, sqlite3)
2. Create directory structure
3. Configuration wizard (restic password, Google Drive, Windows Server, Pushover)
4. Initialize restic repositories
5. Set up cron job (daily at 3 AM)
6. Run verification

## Dependencies

- **restic** - Latest release from GitHub
- **rclone** - Latest release from GitHub (required for Zurg compatibility)
- **jq** - JSON parsing
- **sqlite3** - \*arr database queries

## Configuration Files

### backup.conf

```bash
RESTIC_PASSWORD_FILE="/root/.swizzin-backup-password"

GDRIVE_ENABLED="yes"
GDRIVE_REMOTE="gdrive:swizzin-backups"

SFTP_ENABLED="yes"
SFTP_HOST="192.168.1.100"
SFTP_USER="backup"
SFTP_PORT="22"
SFTP_PATH="/C:/Backups/swizzin"

KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=3

PUSHOVER_ENABLED="yes"
PUSHOVER_USER_KEY="xxx"
PUSHOVER_API_TOKEN="xxx"

BACKUP_HOUR="03"
BACKUP_MINUTE="00"
```

## Security

- Restic password in `/root/.swizzin-backup-password` (mode 600)
- SSH key for Windows Server in `/root/.ssh/` (mode 600)
- All backups encrypted with AES-256
- Config files restricted to root

## Estimated Sizes

| Category                 | Size           |
| ------------------------ | -------------- |
| Swizzin core + nginx     | ~50 MB         |
| \*arr apps               | ~500 MB - 2 GB |
| Media servers (no cache) | ~1-5 GB each   |
| Symlink structures       | ~10-100 MB     |
| **Total (deduplicated)** | **~3-10 GB**   |
| **Daily incremental**    | **~50-200 MB** |

15GB Google Drive is sufficient with GFS rotation and deduplication.
