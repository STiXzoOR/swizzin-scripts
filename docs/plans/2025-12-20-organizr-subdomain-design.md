# Organizr Subdomain Conversion with SSO Authentication

## Overview

Extension script that converts Swizzin's default Organizr installation (subfolder) to subdomain mode with SSO authentication for other apps.

## Usage

```bash
# Install & convert to subdomain
export ORGANIZR_DOMAIN="organizr.example.com"
bash organizr-subdomain.sh

# Modify protected apps later
bash organizr-subdomain.sh --configure

# Revert to subfolder mode
bash organizr-subdomain.sh --revert

# Remove completely (runs box remove organizr too)
bash organizr-subdomain.sh --remove
```

## Main Flow

1. Check if `ORGANIZR_DOMAIN` is set (required)
2. Run `box install organizr` if not already installed
3. Request Let's Encrypt certificate via `LE_HOSTNAME LE_DEFAULTCONF=no LE_BOOL_CF=no box install letsencrypt`
4. Create subdomain nginx vhost replacing the subfolder config
5. Create Organizr auth snippet (`/etc/nginx/snippets/organizr-auth.conf`)
6. Present interactive app selection menu (whiptail)
7. Generate config file with selected apps and auth levels
8. Modify selected app nginx configs to use Organizr auth
9. Reload nginx and PHP-FPM

## Nginx Configuration

### Subdomain Vhost

Location: `/etc/nginx/sites-available/organizr`

```nginx
server {
    listen 80;
    server_name organizr.example.com;

    location /.well-known {
        alias /srv/.well-known;
        allow all;
        default_type "text/plain";
        autoindex on;
    }

    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name organizr.example.com;

    ssl_certificate /etc/nginx/ssl/organizr.example.com/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/organizr.example.com/key.pem;
    include snippets/ssl-params.conf;

    root /srv/organizr;
    index index.php;

    location / {
        try_files $uri $uri/ /index.php$is_args$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php<version>-fpm.sock;
    }

    location /api/v2 {
        try_files $uri /api/v2/index.php$is_args$args;
    }
}
```

### Auth Snippet

Location: `/etc/nginx/snippets/organizr-auth.conf`

```nginx
location ~ /organizr-auth/auth-([0-9]+) {
    internal;
    proxy_pass https://organizr.example.com/api/v2/auth?group=$1;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
}

# 401 redirect to Organizr login
error_page 401 = @organizr_login;
location @organizr_login {
    return 302 https://organizr.example.com/?error=$status&return=$scheme://$http_host$request_uri;
}
```

## Config File

Location: `/opt/swizzin/organizr-auth.conf`

```bash
# Organizr SSO Configuration
# Format: app_name:auth_level
# Auth levels: 0=Admin, 1=Co-Admin, 2=Super User, 3=Power User, 4=User, 998=Logged In
# Re-run 'bash organizr-subdomain.sh --configure' after editing

ORGANIZR_DOMAIN="organizr.example.com"

# Protected apps (default: 0 = Admin only)
sonarr:0
radarr:0
prowlarr:0
bazarr:0
# deluge:0  (commented = not protected)
```

## App Config Modification

For each protected app in `/etc/nginx/apps/<app>.conf`:

```nginx
# Added at top of location block:
include /etc/nginx/snippets/organizr-auth.conf;
auth_request /organizr-auth/auth-0;

# Existing auth_basic lines get commented out (for revert):
#auth_basic "What's the password?";
#auth_basic_user_file /etc/htpasswd.d/htpasswd.user;
```

## Revert Functionality

`--revert` flag (back to subfolder mode):

1. Restore original `/etc/nginx/apps/organizr.conf` from backup
2. Remove subdomain vhost and symlink
3. Restore `auth_basic` lines in protected app configs (uncomment)
4. Remove `include organizr-auth.conf` and `auth_request` lines
5. Keep config file (preserves selections for future re-enable)
6. Reload nginx

## Remove Functionality

`--remove` flag (complete removal):

1. Run revert steps first
2. Run `box remove organizr`
3. Remove `/opt/swizzin/organizr-auth.conf`
4. Remove `/etc/nginx/snippets/organizr-auth.conf`
5. Let's Encrypt cert is kept

## File Structure

```
/opt/swizzin/
├── organizr-auth.conf              # Protected apps config
├── organizr-backups/
│   ├── organizr-subfolder.conf.bak # Original nginx apps config
│   ├── sonarr.conf.bak             # App config backups
│   └── ...

/etc/nginx/
├── sites-available/
│   └── organizr                    # Subdomain vhost
├── sites-enabled/
│   └── organizr -> ../sites-available/organizr
├── snippets/
│   └── organizr-auth.conf          # Auth request snippet
├── apps/
│   └── organizr.conf               # REMOVED (was subfolder config)

/etc/nginx/ssl/organizr.example.com/
├── fullchain.pem
└── key.pem
```

## Error Handling

### Pre-flight Checks

- Verify nginx is installed (`/install/.nginx.lock`)
- Verify `ORGANIZR_DOMAIN` is set
- Check if Organizr already on subdomain (skip conversion, go to configure)

### Handling Existing Installs

- If `/install/.organizr.lock` exists but subfolder config present: convert only
- If already on subdomain: skip to app selection
- If no Organizr installed: run `box install organizr` first

### App Config Safety

- Only modify files in `/etc/nginx/apps/`
- Skip apps that already have `auth_request` directive
- Backup before modification
- Restore from backup if modification fails

## Dependencies

- Swizzin functions: `php_service_version`, `echo_progress_start`, `echo_progress_done`, etc.
- whiptail for interactive menu
- Let's Encrypt via `box install letsencrypt`
