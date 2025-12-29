# Emby Extended Installer with Premiere Bypass

## Overview

Rename `emby-subdomain.sh` to `emby.sh` and extend it to:
1. Install Emby via swizzin box (if not installed)
2. Convert to subdomain mode (existing functionality)
3. Enable Emby Premiere bypass (new feature)

## Usage

```
emby.sh [OPTIONS]

Options:
  (no args)             Interactive setup - asks about subdomain & premiere
  --subdomain           Convert to subdomain mode
  --subdomain --revert  Revert to subfolder mode
  --premiere            Enable Emby Premiere bypass
  --premiere --revert   Disable Emby Premiere bypass
  --remove [--force]    Complete removal
```

## Interactive Mode (no args)

1. Check if Emby installed → if not, run `box install emby`
2. Ask: "Convert Emby to subdomain mode?" [y/N]
   - If yes: prompt domain, LE mode, create vhost
3. Ask: "Enable Emby Premiere?" [y/N]
   - If yes: generate cert, create nginx site, patch hosts, compute key

## State Tracking (swizdb)

- `emby/domain` - subdomain domain
- `emby/premiere` - "enabled" or empty
- `emby/premiere_key` - computed MD5 key (for reference)
- `emby/server_id` - cached serverId

## Premiere Bypass Implementation

### Step 1: Get ServerId

Try API first, fall back to config file:

```bash
_get_server_id() {
    # Try API first (Emby must be running)
    local api_response
    api_response=$(curl -s "http://127.0.0.1:8096/emby/System/Info/Public" 2>/dev/null)
    if [[ -n "$api_response" ]]; then
        server_id=$(echo "$api_response" | jq -r '.Id // empty')
        if [[ -n "$server_id" ]]; then
            echo "$server_id"
            return 0
        fi
    fi

    # Fallback: parse system.xml
    local config_file="/var/lib/emby/config/system.xml"
    if [[ -f "$config_file" ]]; then
        server_id=$(grep -oP '<ServerId>\K[^<]+' "$config_file")
        echo "$server_id"
        return 0
    fi

    return 1
}
```

### Step 2: Compute MD5 Key

Formula: `MD5("MBSupporter" + serverId + "Ae3#fP!wi")`

```bash
_compute_premiere_key() {
    local server_id="$1"
    echo -n "MBSupporter${server_id}Ae3#fP!wi" | md5sum | cut -d' ' -f1
}
```

### Step 3: Generate Self-Signed Certificate

Location: `/etc/nginx/ssl/mb3admin.com/`

```bash
_generate_premiere_cert() {
    local cert_dir="/etc/nginx/ssl/mb3admin.com"
    mkdir -p "$cert_dir"

    # Generate self-signed cert (10 years)
    openssl req -x509 -nodes -days 3650 \
        -newkey rsa:2048 \
        -keyout "$cert_dir/key.pem" \
        -out "$cert_dir/fullchain.pem" \
        -subj "/CN=mb3admin.com"
}
```

### Step 3.5: Add Certificate to System CA Trust

Emby validates SSL certificates, so the self-signed cert must be trusted by the system:

```bash
_install_premiere_ca() {
    cp /etc/nginx/ssl/mb3admin.com/fullchain.pem /usr/local/share/ca-certificates/mb3admin.crt
    update-ca-certificates
}

_remove_premiere_ca() {
    rm -f /usr/local/share/ca-certificates/mb3admin.crt
    update-ca-certificates
}
```

### Step 4: Create nginx Site

Location: `/etc/nginx/sites-available/mb3admin.com`

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name mb3admin.com;
    return 301 https://mb3admin.com$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name mb3admin.com;

    ssl_certificate /etc/nginx/ssl/mb3admin.com/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/mb3admin.com/key.pem;
    include snippets/ssl-params.conf;

    location /admin/service/registration/validateDevice {
        default_type application/json;
        return 200 '{"cacheExpirationDays":3650,"message":"Device Valid","resultCode":"GOOD","isPremiere":true}';
    }

    location /admin/service/registration/validate {
        default_type application/json;
        return 200 '{"featId":"","registered":true,"expDate":"2099-01-01","key":"${PREMIERE_KEY}"}';
    }

    location /admin/service/registration/getStatus {
        default_type application/json;
        return 200 '{"planType":"Lifetime","deviceStatus":0,"subscriptions":[]}';
    }

    location /admin/service/appstore/register {
        default_type application/json;
        return 200 '{"featId":"","registered":true,"expDate":"2099-01-01","key":"${PREMIERE_KEY}"}';
    }

    location /emby/Plugins/SecurityInfo {
        default_type application/json;
        return 200 '{"SupporterKey":"","IsMBSupporter":true}';
    }

    add_header Access-Control-Allow-Origin * always;
    add_header Access-Control-Allow-Headers * always;
    add_header Access-Control-Allow-Method * always;
    add_header Access-Control-Allow-Credentials true always;
}
```

### Step 5: Patch /etc/hosts

With backup and marker comments:

```bash
_patch_hosts() {
    # Backup first
    cp /etc/hosts /etc/hosts.emby-premiere.bak

    # Add with markers
    cat >> /etc/hosts <<'EOF'
# EMBY-PREMIERE-START
127.0.0.1 mb3admin.com
# EMBY-PREMIERE-END
EOF
}

_unpatch_hosts() {
    sed -i '/^# EMBY-PREMIERE-START$/,/^# EMBY-PREMIERE-END$/d' /etc/hosts
}
```

### Success Output

```
Emby Premiere enabled successfully!
Server ID: abc123-def456-...
Premiere Key: fdf15f823f6e8149d97f18f2489093be

Save this key for reference. Restart Emby to activate.
```

## Revert Logic

### Premiere Revert (`--premiere --revert`)

1. Remove nginx site (sites-enabled and sites-available)
2. Remove hosts patch (using markers)
3. Ask about removing SSL cert
4. Clear swizdb entries
5. Reload nginx
6. Inform user to restart Emby

### Subdomain Revert (`--subdomain --revert`)

Existing logic from emby-subdomain.sh

### Full Removal (`--remove`)

1. Revert premiere if enabled
2. Revert subdomain if configured
3. Run `box remove emby`
4. Clean up all swizdb entries

## File Locations

| Item | Location |
|------|----------|
| SSL cert | `/etc/nginx/ssl/mb3admin.com/` |
| CA trust cert | `/usr/local/share/ca-certificates/mb3admin.crt` |
| nginx site | `/etc/nginx/sites-available/mb3admin.com` |
| hosts backup | `/etc/hosts.emby-premiere.bak` |
| Emby config | `/var/lib/emby/config/system.xml` |
