# Zurg Version Switching Design

## Overview

Add mechanism to switch between free and paid Zurg versions with automatic cleanup of version-specific artifacts to prevent duplicate caches and orphaned services.

## Problem

When manually switching versions, users don't know which files to clean up:
- Free version leaves `rclone-zurg.service` and `~/.cache/rclone/vfs/`
- Paid version leaves `~/.config/zurg/data/rclone-cache/`
- Result: 500G+ duplicate caches

## User Interface

### New Flag
```bash
bash zurg.sh --switch-version [free|paid]
```

- `--switch-version` alone: prompt for target version
- `--switch-version paid`: switch to paid (no prompt)
- `--switch-version free`: switch to free (no prompt)

### During Reinstall
When zurg is installed and user runs `bash zurg.sh`:
1. Detect current version from swizdb
2. Prompt: "Currently running [free]. Switch to [paid]?"
3. If declined, continue with current version
4. If accepted, trigger version switch flow

### Environment Variable
`ZURG_VERSION=paid` triggers switch if different from installed version.

## Version Artifacts

| Component | Free Version | Paid Version |
|-----------|--------------|--------------|
| Rclone service | `rclone-zurg.service` | Internal (managed by zurg) |
| Rclone config | `~/.config/rclone/rclone.conf` | `~/.config/zurg/data/rclone.conf` |
| VFS cache | `~/.cache/rclone/vfs/zurg/` | `~/.config/zurg/data/rclone-cache/` |
| Config format | Older YAML options | Newer with `rclone_enabled` |

## Cleanup Logic

### Function: `_cleanup_version_artifacts()`

**Free → Paid cleanup:**
- Remove `rclone-zurg.service`
- Clear `~/.cache/rclone/vfs/zurg/`
- Remove zurg entry from `~/.config/rclone/rclone.conf`

**Paid → Free cleanup:**
- Clear `~/.config/zurg/data/rclone-cache/`
- Remove `~/.config/zurg/data/rclone.conf`

**Both directions:**
1. Get mount point: `swizdb get "zurg/mount_point"` (fallback to `/mnt/zurg`)
2. Stop `rclone-zurg.service` (if exists)
3. Stop `zurg.service`
4. Unmount with `fusermount -uz $mount_point`
5. Remove version-specific files
6. Log what was removed

**Preserved:** Config files (`config.yml`, token) - only cache and service files cleaned.

## Config Migration

### Function: `_migrate_config()`

Extract from existing `config.yml`:
- `token` - Real-Debrid API token
- `port` - Current port (default 9999)
- `mount_path` - From config or swizdb

### Migration Matrix

| Field | Free → Paid | Paid → Free |
|-------|-------------|-------------|
| token | Copy directly | Copy directly |
| port | Copy directly | Copy directly |
| mount_path | Read from swizdb, write to config | Read from config, store in swizdb |
| rclone_enabled | Set `true` | Remove |
| rclone_extra_args | Set defaults | Remove |

## Implementation Flow

```
parse args
  └─ --switch-version [free|paid]? → set switch_mode=true, target_version

if switch_mode:
    current_version = swizdb get "zurg/version"
    if current_version == target_version:
        echo_info "Already running $target_version"
        exit 0

    if target_version == "paid":
        _get_github_token()  # Verify auth BEFORE any changes
        if failed: exit 1

    _migrate_config()            # Extract token, port, mount
    _cleanup_version_artifacts() # Remove old version files
    # Continue to normal install with migrated values

else if reinstall (lock exists):
    current_version = swizdb get "zurg/version"
    ask "Currently running $current. Switch version?"
    if yes: trigger switch flow above
    if no: continue normal reinstall

else:
    normal fresh install (existing behavior)
```

## User Feedback

```
Switching zurg from free → paid...
✓ GitHub access verified
✓ Migrated: token, port 9999, mount /mnt/zurg
✓ Stopped services
✓ Cleared free version cache (256G freed)
✓ Removed rclone-zurg.service
Installing paid version...
```

## Implementation Checklist

- [ ] Add `--switch-version` flag parsing
- [ ] Create `_migrate_config()` function
- [ ] Create `_cleanup_version_artifacts()` function
- [ ] Modify `_select_zurg_version()` to detect and prompt for switch on reinstall
- [ ] Add user feedback for each cleanup step
- [ ] Test free → paid switch
- [ ] Test paid → free switch
- [ ] Test reinstall without switch (no regression)
