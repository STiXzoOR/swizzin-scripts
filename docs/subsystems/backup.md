# Backup System

BorgBackup-based backup system supporting any SSH-accessible borg server (Hetzner Storage Box, Rsync.net, BorgBase, self-hosted).

## Directory Structure

```
backup/
├── swizzin-backup-install.sh   # Interactive setup wizard
├── swizzin-backup.sh           # Main backup script
├── swizzin-restore.sh          # Interactive restore
├── swizzin-backup.conf         # Configuration template
├── swizzin-excludes.txt        # Exclusion patterns
├── swizzin-backup.service      # Systemd service unit
├── swizzin-backup.timer        # Systemd timer (daily at 4 AM)
├── swizzin-backup-logrotate    # Log rotation config
└── README.md                   # Setup documentation
```

## Runtime Files (on server)

| File                                   | Purpose                    |
| -------------------------------------- | -------------------------- |
| `/etc/swizzin-backup.conf`             | Configuration              |
| `/etc/swizzin-excludes.txt`            | Exclusion patterns         |
| `/usr/local/bin/swizzin-backup.sh`     | Backup script              |
| `/usr/local/bin/swizzin-restore.sh`    | Restore script             |
| `/etc/systemd/system/swizzin-backup.*` | Systemd service + timer    |
| `/root/.ssh/id_backup`                 | SSH key for remote server  |
| `/root/.swizzin-backup-passphrase`     | Borg encryption passphrase |
| `/var/log/swizzin-backup.log`          | Backup log                 |

## Features

- Automatic service stop/start for consistent SQLite backups
- Multi-instance app support (sonarr-4k, radarr-anime, etc.)
- Zurg `.zurgtorrent` file backup for Real-Debrid setups
- `/mnt/symlinks` backup for arr root folder symlinks
- Notifications via Discord, Pushover, Notifiarr, email
- Healthchecks.io integration
- GFS retention: 7 daily, 4 weekly, 6 monthly, 2 yearly

## Commands

```bash
swizzin-backup.sh               # Run full backup
swizzin-backup.sh --dry-run     # Show what would be backed up
swizzin-backup.sh --list        # List archives
swizzin-backup.sh --services    # List discovered services
swizzin-restore.sh              # Interactive restore
swizzin-restore.sh --app sonarr # Restore single app
swizzin-restore.sh --mount      # FUSE mount for browsing
```

## Adding New App Support

See [Maintenance Checklist](../maintenance-checklist.md#3-update-backup-system) for the arrays to update in backup/restore scripts.
