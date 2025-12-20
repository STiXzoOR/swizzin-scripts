# Media Server Subdomain Conversion Scripts

## Overview

Scripts to convert Plex, Emby, and Jellyfin from subfolder access to subdomain mode with Let's Encrypt certificates and panel integration.

## Scripts

### New Scripts

| Script | Purpose | Port |
|--------|---------|------|
| `plex.sh` | Plex + nginx subfolder at `/plex` | 32400 |
| `plex-subdomain.sh` | Plex subfolder → subdomain | 32400 |
| `emby-subdomain.sh` | Emby subfolder → subdomain | 8096 |
| `jellyfin-subdomain.sh` | Jellyfin subfolder → subdomain | 8922 |

### Fixes to Existing Scripts

- `organizr-subdomain.sh` - Add panel meta `urloverride`
- `seerr.sh` - Add frame-ancestors CSP header

## plex.sh

Extends Swizzin's Plex install with nginx subfolder config.

### Install Flow

1. Check if Plex installed (`/install/.plex.lock`), run `box install plex` if not
2. Create `/etc/nginx/apps/plex.conf` with `/plex` location
3. Reload nginx

### Removal (`--remove [--force]`)

1. Check for `/install/.plex.lock` (skip if `--force`)
2. Remove `/etc/nginx/apps/plex.conf`
3. Reload nginx
4. Run `box remove plex`

### nginx Config

```nginx
location /plex/ {
    rewrite /plex/(.*) /$1 break;
    include /etc/nginx/snippets/proxy.conf;
    proxy_pass http://127.0.0.1:32400/;
}
```

No panel registration needed - Swizzin already handles Plex in the panel.

## Subdomain Scripts

Common structure for `plex-subdomain.sh`, `emby-subdomain.sh`, `jellyfin-subdomain.sh`.

### Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `<APP>_DOMAIN` | Yes | Public FQDN (e.g., `plex.example.com`) |
| `<APP>_LE_HOSTNAME` | No | Let's Encrypt hostname (defaults to domain) |
| `<APP>_LE_INTERACTIVE` | No | Set to `yes` for CloudFlare DNS validation |

### Install Flow

1. Check `<APP>_DOMAIN` is set
2. Run `box install <app>` if not installed (for Plex, run `plex.sh` to ensure nginx config exists)
3. Backup subfolder config to `/opt/swizzin/<app>-backups/`
4. Request Let's Encrypt certificate
5. Create subdomain vhost at `/etc/nginx/sites-available/<app>`
6. Remove subfolder config
7. Update panel meta with `urloverride` in `/opt/swizzin/core/custom/profiles.py`
8. Reload nginx

### Revert (`--revert`)

1. Remove subdomain vhost and symlink
2. Restore subfolder config from backup
3. Remove panel meta `urloverride` from `profiles.py`
4. Reload nginx
5. Keep backup dir and LE cert for future re-enable

### Remove (`--remove [--force]`)

1. Check for lock file (skip if `--force`)
2. Run `--revert` steps first
3. Run `box remove <app>`
4. Remove backup dir at `/opt/swizzin/<app>-backups/`
5. LE cert not removed

## Subdomain Vhost Template

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name <domain>;

    location /.well-known {
        alias /srv/.well-known;
        allow all;
        default_type "text/plain";
        autoindex on;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name <domain>;

    ssl_certificate /etc/nginx/ssl/<le_hostname>/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/<le_hostname>/key.pem;
    include snippets/ssl-params.conf;

    # Frame-ancestors for Organizr embedding (if configured)
    add_header Content-Security-Policy "frame-ancestors 'self' https://<organizr_domain>";

    location / {
        include snippets/proxy.conf;
        proxy_pass <upstream>;
    }
}
```

## Panel Meta Override

Add to `/opt/swizzin/core/custom/profiles.py`:

```python
class plex_meta(plex_meta):
    urloverride = "https://plex.example.com"
```

Remove on `--revert` by deleting the class definition.

## Frame-Ancestors Header

For Organizr iframe embedding:

1. Read `ORGANIZR_DOMAIN` from `/opt/swizzin/organizr-auth.conf`
2. If found: `add_header Content-Security-Policy "frame-ancestors 'self' https://<organizr_domain>";`
3. If not found: use `'self'` only or skip header

## Ports Reference

| App | Port | Protocol |
|-----|------|----------|
| Plex | 32400 | HTTP |
| Emby | 8096 | HTTP |
| Jellyfin | 8922 | HTTPS |

## File Structure

```
/opt/swizzin/
├── <app>-backups/
│   └── <app>.conf.bak          # Subfolder config backup

/etc/nginx/
├── sites-available/
│   └── <app>                   # Subdomain vhost
├── sites-enabled/
│   └── <app> -> ../sites-available/<app>
├── apps/
│   └── <app>.conf              # Removed on subdomain conversion

/opt/swizzin/core/custom/
└── profiles.py                 # Panel meta overrides
```
