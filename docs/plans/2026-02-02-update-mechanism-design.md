# Update Mechanism Design

Unified update system for all swizzin installer scripts.

## Goals

1. Standardize update flag (`--update`) across all scripts
2. Add update support to templates that lack it (binary, python)
3. Consistent rollback on failure
4. Clear progress output using swizzin logging functions

## Flag Standard

### Primary Flag

All scripts use `--update` as the update flag.

### Modifiers

| Modifier    | Applies to     | Effect                                 |
| ----------- | -------------- | -------------------------------------- |
| `--full`    | Binary, Python | Full reinstall instead of smart update |
| `--verbose` | All            | Detailed progress output               |

### Default Behavior by App Type

| App Type | `--update` (default)            | `--update --full`     |
| -------- | ------------------------------- | --------------------- |
| Docker   | Pull image + recreate container | N/A                   |
| Binary   | Replace binary + restart        | Full reinstall        |
| Python   | Git pull + uv sync + restart    | Re-clone + full setup |

### Zurg Exception

Zurg keeps version pinning (`ZURG_VERSION_TAG`, `--latest`) due to paid/free complexity.

| Current                   | New               |
| ------------------------- | ----------------- |
| `--upgrade --binary-only` | `--update`        |
| `--upgrade`               | `--update --full` |

## Rollback System

### Backup Location

`/tmp/swizzin-update-backups/{app_name}/`

Auto-cleaned after successful update or on system reboot.

### What Gets Backed Up

| App Type | Backup Contents                      |
| -------- | ------------------------------------ |
| Docker   | Nothing (images versioned by Docker) |
| Binary   | Executable file only                 |
| Python   | Entire app directory (source code)   |

### Rollback Flow

```
1. Create backup in /tmp/swizzin-update-backups/{app}/
2. Stop service
3. Perform update
4. Start service
5. Verify service is running (systemctl is-active)
   - Success: Remove backup, print success
   - Failure: Restore from backup, restart, print error with guidance
```

Docker apps have no rollback - if pull fails, old image remains.

## Template Functions

### New Functions

Each template (binary, python) gets:

```bash
_backup_myapp() {
    local backup_dir="/tmp/swizzin-update-backups/${app_name}"
    mkdir -p "$backup_dir"
    # Binary: cp binary to backup_dir
    # Python: cp -r app_dir to backup_dir
}

_rollback_myapp() {
    local backup_dir="/tmp/swizzin-update-backups/${app_name}"
    # Restore from backup_dir
    # Restart service
    # Print error with guidance
}

_update_myapp() {
    _backup_myapp
    # Perform update
    # Verify service
    # On failure: _rollback_myapp
    # On success: rm -rf backup_dir
}
```

### Template Changes

| Template                  | Changes                                         |
| ------------------------- | ----------------------------------------------- |
| template-docker.sh        | Add `--verbose` support (update exists)         |
| template-binary.sh        | Add `_backup`, `_rollback`, `_update`, `--full` |
| template-python.sh        | Add `_backup`, `_rollback`, `_update`, `--full` |
| template-multiinstance.sh | Add update support (calls base app's update)    |
| template-subdomain.sh     | No changes (manages nginx, not apps)            |

## Output & Logging

### Functions Used

| Function        | Purpose            |
| --------------- | ------------------ |
| `echo_progress` | Step announcements |
| `echo_success`  | Success messages   |
| `echo_error`    | Error messages     |
| `echo_info`     | Informational      |
| `echo_log`      | Verbose details    |

### Output Levels

**Standard (default):**

```
Updating notifiarr...
Backing up current binary...
Downloading latest release...
Restarting service...
Update complete.
```

**Verbose (`--verbose`):**

```
Updating notifiarr...
Backing up current binary...
  Backup location: /tmp/swizzin-update-backups/notifiarr/
  Backed up: /opt/notifiarr/notifiarr (4.2MB)
Downloading latest release...
  GitHub API: https://api.github.com/repos/Notifiarr/notifiarr/releases/latest
  Version: v0.8.1
  Asset: notifiarr_linux_amd64.tar.gz
Restarting service...
  Service active: yes
Update complete.
```

## Scripts to Update

### Adjust for Consistency

| Script            | Current     | Changes                               |
| ----------------- | ----------- | ------------------------------------- |
| lingarr.sh        | `--update`  | Add `--verbose`                       |
| libretranslate.sh | `--update`  | Add `--verbose`                       |
| zurg.sh           | `--upgrade` | Rename to `--update`, add `--verbose` |

### Add Update Mechanism

| Script          | Type   | Update Behavior    |
| --------------- | ------ | ------------------ |
| notifiarr.sh    | Binary | GitHub releases    |
| decypharr.sh    | Binary | GitHub releases    |
| cleanuparr.sh   | Binary | GitHub releases    |
| flaresolverr.sh | Binary | GitHub releases    |
| huntarr.sh      | Python | Git pull + uv sync |
| byparr.sh       | Python | Git pull + uv sync |
| subgen.sh       | Python | Git pull + uv sync |

### No Update Needed

| Script                          | Reason                          |
| ------------------------------- | ------------------------------- |
| plex.sh, emby.sh, jellyfin.sh   | Apt/repo managed                |
| sonarr.sh, radarr.sh, bazarr.sh | Apt/repo managed, in-app update |
| organizr.sh, panel.sh           | Config scripts                  |

## Implementation Phases

### Phase 1: Templates

1. Update `template-binary.sh` with full update system
2. Update `template-python.sh` with full update system
3. Add `--verbose` support to `template-docker.sh`

### Phase 2: Standardize Existing

4. Migrate `zurg.sh` from `--upgrade` to `--update`
5. Add `--verbose` to `lingarr.sh` and `libretranslate.sh`

### Phase 3: Backfill Scripts

6. Binary apps: notifiarr, decypharr, cleanuparr, flaresolverr
7. Python apps: huntarr, byparr, subgen

### Phase 4: Documentation

8. Update `docs/templates.md` with update mechanism usage
9. Update `docs/maintenance-checklist.md` to include update testing
10. Add `docs/subsystems/update-system.md` for architecture docs
