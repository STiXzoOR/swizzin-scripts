# LibreTranslate Installer Design

**Date:** 2026-01-30
**Status:** Ready for implementation

## Overview

A Docker-based installer for LibreTranslate, a self-hosted machine translation API. Follows the Lingarr pattern with systemd wrapper, auto-discovery, and dual nginx modes.

## Deliverables

| File                          | Action                                                                     |
| ----------------------------- | -------------------------------------------------------------------------- |
| `libretranslate.sh`           | New installer (main deliverable)                                           |
| `local/backup/borg-backup.sh` | Add libretranslate to SERVICE_TYPES + SERVICE_STOP_ORDER                   |
| `bootstrap/lib/apps.sh`       | Add libretranslate to bundles, install order, source, script, menus        |
| `local/swizzin-app-info.py`   | Add libretranslate config + fix lingarr config + add docker_compose parser |
| `CLAUDE.md`                   | Document the new script                                                    |

## Usage

```bash
bash libretranslate.sh                    # Interactive setup
bash libretranslate.sh --subdomain        # Convert to subdomain mode
bash libretranslate.sh --subdomain --revert  # Revert to subfolder
bash libretranslate.sh --update           # Pull latest image, recreate container
bash libretranslate.sh --remove [--force] # Complete removal
bash libretranslate.sh --register-panel   # Re-register with panel
```

## Key Paths

| Item               | Path                                        |
| ------------------ | ------------------------------------------- |
| App directory      | `/opt/libretranslate/`                      |
| Config/DB          | `/opt/libretranslate/config/`               |
| Model cache        | `/opt/libretranslate/models/`               |
| docker-compose.yml | `/opt/libretranslate/docker-compose.yml`    |
| Systemd service    | `libretranslate.service`                    |
| Nginx (subfolder)  | `/etc/nginx/apps/libretranslate.conf`       |
| Nginx (subdomain)  | `/etc/nginx/sites-available/libretranslate` |
| Lock file          | `/install/.libretranslate.lock`             |

**Port:** Dynamic allocation via `port 10000 12000` (stored in swizdb)

## Environment Variables

| Variable                           | Description                                      |
| ---------------------------------- | ------------------------------------------------ |
| `LIBRETRANSLATE_OWNER`             | App owner username (defaults to master user)     |
| `LIBRETRANSLATE_DOMAIN`            | Public FQDN for subdomain mode                   |
| `LIBRETRANSLATE_LE_HOSTNAME`       | Let's Encrypt hostname (defaults to domain)      |
| `LIBRETRANSLATE_LE_INTERACTIVE`    | Set to `yes` for interactive LE (CloudFlare DNS) |
| `LIBRETRANSLATE_LANGUAGES`         | Comma-separated language codes to pre-download   |
| `LIBRETRANSLATE_GPU`               | Force `cuda` or `cpu` (skips auto-detection)     |
| `LIBRETRANSLATE_CONFIGURE_LINGARR` | Set to `yes` or `no` to skip Lingarr prompt      |

## Design Decisions

### 1. GPU Auto-Detection

```bash
_detect_gpu() {
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
        if docker info 2>/dev/null | grep -q "nvidia"; then
            echo "cuda"
            return
        fi
    fi
    echo "cpu"
}
```

- Uses `libretranslate/libretranslate:latest-cuda` if NVIDIA GPU + nvidia-container-toolkit detected
- Falls back to `libretranslate/libretranslate:latest` (CPU) otherwise

### 2. Docker Compose Configuration

**CPU version:**

```yaml
services:
  libretranslate:
    image: libretranslate/libretranslate:latest
    container_name: libretranslate
    network_mode: host
    environment:
      - LT_HOST=127.0.0.1
      - LT_PORT=${app_port}
      - LT_URL_PREFIX=/libretranslate # For subfolder mode only
      - LT_LOAD_ONLY=${selected_languages}
      - LT_UPDATE_MODELS=true
    volumes:
      - ${app_configdir}/db:/app/db
      - ${app_configdir}/models:/home/libretranslate/.local
```

**CUDA version adds:**

```yaml
image: libretranslate/libretranslate:latest-cuda
deploy:
  resources:
    reservations:
      devices:
        - driver: nvidia
          count: 1
          capabilities: [gpu]
volumes:
  - ${app_configdir}/models:/root/.local # Different path for CUDA image
```

### 3. Language Selection (Whiptail)

48 supported languages with whiptail multi-select picker:

```bash
declare -A LANGUAGES=(
    ["en"]="English"
    ["es"]="Spanish"
    ["fr"]="French"
    ["de"]="German"
    ["it"]="Italian"
    ["pt"]="Portuguese"
    ["ru"]="Russian"
    ["zh"]="Chinese"
    ["ja"]="Japanese"
    ["ko"]="Korean"
    ["ar"]="Arabic"
    ["hi"]="Hindi"
    # ... 36 more languages
)

LANGUAGE_ORDER=(en es fr de it pt ru zh ja ko ar hi nl pl tr vi uk th sv
               fi da cs el he hu id ro bg ca et ga lv lt sk sl sq az eu
               bn eo gl ky ms nb fa tl ur zt pb)
```

- Pre-selects English by default
- Falls back to comma-separated text input if whiptail unavailable
- Languages stored in swizdb: `libretranslate/languages`

### 4. Lingarr Integration

When Lingarr is detected (`/install/.lingarr.lock` exists):

```bash
_configure_lingarr() {
    if [[ ! -f /install/.lingarr.lock ]]; then
        return 0
    fi

    if ! ask "Configure Lingarr to use this LibreTranslate instance?" Y; then
        echo_info "Manual config: Settings > Translation > LibreTranslate URL = http://127.0.0.1:${app_port}"
        return 0
    fi

    # Update via SQLite if possible
    local lingarr_db="/opt/lingarr/config/lingarr.db"
    if [[ -f "$lingarr_db" ]] && command -v sqlite3 &>/dev/null; then
        sqlite3 "$lingarr_db" "UPDATE Settings SET Value='http://127.0.0.1:${app_port}' WHERE Key='LibreTranslateUrl';" 2>/dev/null || true
        systemctl restart lingarr 2>/dev/null || true
    fi
}
```

### 5. Nginx Configuration

**Subfolder mode** (`/etc/nginx/apps/libretranslate.conf`):

LibreTranslate natively supports `LT_URL_PREFIX`, so no `sub_filter` needed:

```nginx
location /libretranslate {
    return 301 /libretranslate/;
}

location ^~ /libretranslate/ {
    proxy_pass http://127.0.0.1:${app_port}/libretranslate/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_http_version 1.1;
    proxy_read_timeout 300s;  # Translation can take time

    auth_basic "What's the password?";
    auth_basic_user_file /etc/htpasswd.d/htpasswd.${user};
}

# API endpoints bypass auth for programmatic access
location ^~ /libretranslate/translate {
    auth_request off;
    proxy_pass http://127.0.0.1:${app_port}/libretranslate/translate;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 300s;
}

location ^~ /libretranslate/languages {
    auth_request off;
    proxy_pass http://127.0.0.1:${app_port}/libretranslate/languages;
    # ... same headers
}
```

**Subdomain mode** (`/etc/nginx/sites-available/libretranslate`):

Standard vhost - no `LT_URL_PREFIX` needed when on root:

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name translate.example.com;

    ssl_certificate /etc/nginx/ssl/translate.example.com/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/translate.example.com/key.pem;
    include snippets/ssl-params.conf;

    # CSP for Organizr embedding (if configured)
    add_header Content-Security-Policy "frame-ancestors 'self' https://organizr.example.com";

    location / {
        proxy_pass http://127.0.0.1:${app_port};
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_read_timeout 300s;
    }
}
```

### 6. Authentication

- **Web UI**: Protected by htpasswd (standard Swizzin pattern)
- **API endpoints**: Auth bypassed for programmatic access (`/translate`, `/languages`, `/detect`)
- LibreTranslate's built-in API key system (`LT_API_KEYS`) not enabled by default

## Side-Effect Updates

### borg-backup.sh

```bash
# SERVICE_TYPES (after lingarr):
["libretranslate"]="system"

# SERVICE_STOP_ORDER (in utilities section):
filebrowser syncthing pyload netdata subgen lingarr libretranslate
```

### bootstrap/lib/apps.sh

```bash
# APP_BUNDLES[helpers]:
APP_BUNDLES[helpers]="huntarr cleanuparr byparr notifiarr filebrowser librespeed libretranslate"

# INSTALL_ORDER (Phase 7, after lingarr):
"lingarr"
"libretranslate"

# APP_SOURCE:
APP_SOURCE[libretranslate]="repo"

# APP_SCRIPT:
APP_SCRIPT[libretranslate]="libretranslate.sh"

# Whiptail menu (Helpers section):
"libretranslate" "LibreTranslate (Translation API)" "OFF"

# Fallback menu helper_apps:
"libretranslate:LibreTranslate (Translation API)"
```

### swizzin-app-info.py

**Update lingarr entry:**

```python
"lingarr": {
    "config_paths": ["/opt/lingarr/docker-compose.yml"],
    "format": "docker_compose",
    "keys": {
        "port": "ASPNETCORE_URLS",
    },
    "default_port": 9876,
},
```

**Add libretranslate entry:**

```python
"libretranslate": {
    "config_paths": ["/opt/libretranslate/docker-compose.yml"],
    "format": "docker_compose",
    "keys": {
        "port": "LT_PORT",
    },
},
```

**Add new parser:**

```python
def parse_docker_compose_env(path: str, keys: Dict[str, str]) -> Dict[str, Any]:
    """Parse environment variables from docker-compose.yml."""
    result = {}
    try:
        with open(path, "r") as f:
            content = f.read()

        for result_key, env_key in keys.items():
            pattern = rf"-\s*{env_key}[=:]([^\n]+)"
            match = re.search(pattern, content)
            if match:
                value = match.group(1).strip()
                if "://" in value:
                    port_match = re.search(r":(\d+)", value)
                    if port_match:
                        value = port_match.group(1)
                result[result_key] = value
    except Exception as e:
        result["_error"] = str(e)
    return result
```

**Update parse_app_config():**

```python
elif fmt == "docker_compose":
    parsed = parse_docker_compose_env(config_file, keys)
```

## Implementation Order

1. Create `libretranslate.sh` (main installer)
2. Update `local/backup/borg-backup.sh`
3. Update `bootstrap/lib/apps.sh`
4. Update `local/swizzin-app-info.py`
5. Update `CLAUDE.md` documentation
