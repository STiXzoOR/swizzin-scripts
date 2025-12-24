# Interactive Prompts Design

**Date:** 2025-12-24
**Status:** Approved

## Overview

Improve UX by replacing environment variable requirements with interactive prompts. Environment variables remain as bypass for automation.

## Zurg Script Changes

### New Interactive Prompts

1. **Mount point:**
   ```
   Enter zurg mount point [/mnt/zurg]:
   ```
   - Default: `/mnt/zurg`
   - Validate absolute path (starts with `/`)
   - Create directory if doesn't exist
   - Store in swizdb: `zurg/mount_point`

2. **API key** (existing prompt, add storage):
   - Store in swizdb: `zurg/api_key`

### Cross-Integration with Decypharr

If decypharr is installed when zurg installs/updates:
- Update `debrids[].folder` for `realdebrid` entry
- Update `debrids[].api_key` for `realdebrid` entry
- Restart decypharr service

### Environment Bypass

- `ZURG_MOUNT_POINT=/custom/path` - skips mount point prompt
- `RD_TOKEN=xxx` - existing, skips API key prompt

## Decypharr Script Changes

### New Interactive Prompts

1. **Rclone mount path:**
   ```
   Enter rclone mount path [/mnt]:
   ```
   - Default: `/mnt`
   - Store in swizdb: `decypharr/mount_path`

### Cross-Integration with Zurg

If zurg is installed when decypharr installs:
- Read `zurg/mount_point` from swizdb
- Read `zurg/api_key` from swizdb
- Pre-populate `debrids[]` realdebrid entry:
  - `folder`: `<zurg_mount>/__all__/`
  - `api_key`: from zurg config

### Config Structure

```json
{
  "debrids": [{
    "name": "realdebrid",
    "api_key": "<from zurg or prompt>",
    "folder": "<zurg_mount>/__all__/",
    ...
  }],
  "rclone": {
    "mount_path": "<decypharr_mount_path>",
    ...
  }
}
```

## Subdomain Scripts Changes

### Affected Scripts

- `organizr-subdomain.sh`
- `plex-subdomain.sh`
- `emby-subdomain.sh`
- `jellyfin-subdomain.sh`
- `templates/template-subdomain.sh`

### New Interactive Prompts

1. **Domain:**
   ```
   Enter domain for <App>:
   ```
   - Required, no default on first run
   - On re-run, show existing as default: `Enter domain for Organizr [organizr.example.com]: `
   - Basic validation (contains dots, no spaces)
   - Store in swizdb: `<app>/domain`

2. **Let's Encrypt mode:**
   ```
   Use interactive Let's Encrypt (for DNS challenges)? [y/N]:
   ```
   - Default: No (standard HTTP challenge)
   - Interactive mode for wildcard certs, CloudFlare DNS, etc.

### Environment Bypass (Preserved)

- `ORGANIZR_DOMAIN=xxx` - skips domain prompt
- `ORGANIZR_LE_INTERACTIVE=yes` - skips LE prompt

Same pattern for other apps (`PLEX_DOMAIN`, `EMBY_DOMAIN`, etc.)

## Default Paths Summary

| Setting | Default | Storage |
|---------|---------|---------|
| Zurg mount point | `/mnt/zurg` | `swizdb: zurg/mount_point` |
| Zurg API key | (prompted) | `swizdb: zurg/api_key` |
| Decypharr rclone mount | `/mnt` | `swizdb: decypharr/mount_path` |
| Decypharr realdebrid folder | `<zurg_mount>/__all__/` | in config.json |

## Implementation Order

1. Update `zurg.sh` with mount point prompt and swizdb storage
2. Update `decypharr.sh` with mount path prompt and zurg integration
3. Update `organizr-subdomain.sh` with domain prompts
4. Update other subdomain scripts following same pattern
5. Update `templates/template-subdomain.sh`
