# Swizzin Backup System

Automated backup system for Swizzin servers with dual-destination redundancy, dynamic app discovery, and intelligent retention.

## Features

- **Dual destinations**: Google Drive (offsite) + Windows Server via SFTP (fast restore)
- **Dynamic discovery**: Automatically detects installed apps via lock files
- **Multi-instance support**: Handles sonarr-4k, radarr-anime, etc.
- **Custom path resolution**: Reads paths from swizdb and app configs
- **Symlink preservation**: Backs up \*arr root folders with symlink structures
- **Smart exclusions**: Skips VFS caches (256GB+), transcodes, and regenerable data
- **GFS rotation**: 7 daily, 4 weekly, 3 monthly snapshots
- **Pushover notifications**: Success/failure alerts
- **Encrypted backups**: AES-256 encryption via restic

## Quick Start

```bash
# Copy to server
scp -r backup/ root@server:/tmp/

# Run installer
cd /tmp/backup
bash swizzin-backup-install.sh
```

The installer will:

1. Install latest restic and rclone from GitHub releases
2. Walk through configuration (Google Drive, SFTP, Pushover)
3. Initialize encrypted restic repositories
4. Set up daily cron job at 3 AM

## Commands

### Backup

```bash
swizzin-backup run              # Run backup to both destinations
swizzin-backup run --gdrive     # Google Drive only
swizzin-backup run --sftp       # SFTP only

swizzin-backup status           # Show backup status
swizzin-backup list             # List available snapshots
swizzin-backup discover         # Preview what would be backed up
swizzin-backup verify           # Verify backup integrity
swizzin-backup stats            # Show repository statistics
swizzin-backup test             # Test connectivity
```

### Restore

```bash
swizzin-restore                              # Interactive wizard
swizzin-restore --source gdrive --app sonarr # Restore single app
swizzin-restore --snapshot latest --dry-run  # Preview restore
swizzin-restore --config-only                # Configs only, skip DBs
```

## What Gets Backed Up

### Always Included

- Swizzin core (`/etc/swizzin/`, `/opt/swizzin/`)
- Nginx configs (`/etc/nginx/`)
- Let's Encrypt certs (`/etc/letsencrypt/`)
- Systemd services (`/etc/systemd/system/*.service`)
- Cron jobs (`/etc/cron.d/`)
- Lock files (`/install/.*.lock`)

### Per-App (auto-discovered)

- \*arr apps: configs, databases, instances
- Media servers: Plex, Emby, Jellyfin (config + DB, no cache)
- Custom apps: Notifiarr, Decypharr, Zurg, Huntarr, Byparr, etc.
- Download clients: Transmission, Deluge, qBittorrent, etc.

### Dynamic Paths

- Decypharr downloads (from config.json)
- \*arr root folders with symlinks (from SQLite)
- Custom mount points (from swizdb)

## Excluded (Never Backed Up)

```
# VFS caches (can be 256GB+)
/home/*/.cache/rclone/**
*/zurg/data/rclone-cache/**

# Media server caches
*/Plex Media Server/Cache/**
*/emby/cache/**
*/jellyfin/cache/**

# Mount points (cloud data)
/mnt/zurg/**
```

## Configuration

### Main Config (`/opt/swizzin/backup/backup.conf`)

```bash
# Encryption
RESTIC_PASSWORD_FILE="/root/.swizzin-backup-password"

# Google Drive (via rclone)
GDRIVE_ENABLED="yes"
GDRIVE_REMOTE="gdrive:swizzin-backups"

# Windows Server (via SFTP)
SFTP_ENABLED="yes"
SFTP_HOST="192.168.1.100"
SFTP_USER="backup"
SFTP_PATH="/C:/Backups/swizzin"

# Retention (GFS)
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=3

# Notifications
PUSHOVER_ENABLED="yes"
PUSHOVER_USER_KEY="xxx"
PUSHOVER_API_TOKEN="xxx"
```

### App Registry (`app-registry.conf`)

Maps apps to their file paths. Format:

```
APP|CONFIG_PATHS|DATA_PATHS|EXCLUDES|TYPE
```

Add custom apps by editing this file.

### Exclusions (`excludes.conf`)

Global exclusion patterns. Uses restic/gitignore syntax.

## Hooks

Create custom pre/post backup scripts:

```bash
# /opt/swizzin/backup/hooks/pre-backup.sh
#!/bin/bash
# Stop services for consistent DB state
systemctl stop sonarr

# /opt/swizzin/backup/hooks/post-backup.sh
#!/bin/bash
# Restart services
systemctl start sonarr
```

## Restore Modes

| Mode           | Description                        |
| -------------- | ---------------------------------- |
| Full restore   | Everything - rebuild entire server |
| App restore    | Single app (e.g., just Sonarr)     |
| Config restore | Configs only, preserve databases   |
| Browse files   | Interactive file selection         |

## File Structure

```
/opt/swizzin/backup/
├── swizzin-backup.sh        # Main backup script
├── swizzin-restore.sh       # Restore script
├── backup.conf              # Configuration
├── app-registry.conf        # App → path mappings
├── excludes.conf            # Exclusion patterns
├── hooks/
│   ├── pre-backup.sh        # Pre-backup hook
│   └── post-backup.sh       # Post-backup hook
└── manifests/               # Generated at runtime
    ├── symlinks-*.json      # Symlink structure
    ├── swizdb-*.json        # swizdb export
    └── paths-*.json         # Custom path mappings
```

## Requirements

- **restic** - Installed automatically (latest from GitHub)
- **rclone** - Installed automatically (latest from GitHub)
- **jq** - For JSON parsing
- **sqlite3** - For \*arr database queries

## Estimated Backup Sizes

| Category                 | Size           |
| ------------------------ | -------------- |
| Swizzin core + nginx     | ~50 MB         |
| \*arr apps               | ~500 MB - 2 GB |
| Media servers (no cache) | ~1-5 GB each   |
| Symlink structures       | ~10-100 MB     |
| **Total (deduplicated)** | **~3-10 GB**   |
| **Daily incremental**    | **~50-200 MB** |

15GB Google Drive is sufficient with GFS rotation and deduplication.

## Troubleshooting

### "Repository not found"

```bash
swizzin-backup init
```

### "Permission denied" on restore

The restore script automatically fixes permissions. If issues persist:

```bash
chown -R <user>:<user> /home/<user>/.config/
```

### Check backup logs

```bash
tail -f /var/log/swizzin-backup.log
```

### Test connectivity

```bash
swizzin-backup test
```

## Security

- All backups are encrypted with AES-256 (restic)
- Password stored in `/root/.swizzin-backup-password` (mode 600)
- SSH key for SFTP in `/root/.ssh/` (mode 600)
- Config files restricted to root only

## License

GPL-3.0 - Same as parent repository.
