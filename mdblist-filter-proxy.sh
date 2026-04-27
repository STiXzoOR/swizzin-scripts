#!/bin/bash
# mdblist-filter-proxy installer
# Local HTTP proxy that strips/normalizes mdblist.com list payloads so
# Sonarr's CustomImport and Radarr's RadarrListImport don't crash on
# items with `tvdbid: null` / `tmdbid: null`.
#
# Usage:
#   bash mdblist-filter-proxy.sh                # install + enable + start
#   bash mdblist-filter-proxy.sh --remove       # full uninstall
#   bash mdblist-filter-proxy.sh --status       # service status
#   bash mdblist-filter-proxy.sh --rewrite-arr  # repoint existing
#                                                 [mdblist-auto] lists at proxy

set -euo pipefail

# ==============================================================================
# Configuration
# ==============================================================================

SCRIPT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mdblist-filter-proxy.py"
SCRIPT_DST="/usr/local/bin/mdblist-filter-proxy.py"
SERVICE_NAME="mdblist-filter-proxy"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SERVICE_USER="${SERVICE_USER:-raflix}"
PROXY_HOST="${MDBLIST_PROXY_HOST:-127.0.0.1}"
PROXY_PORT="${MDBLIST_PROXY_PORT:-11550}"
PROXY_TTL="${MDBLIST_PROXY_TTL:-300}"
UPSTREAM_HOST="https://mdblist.com"
PROXY_BASE="http://${PROXY_HOST}:${PROXY_PORT}"

# ==============================================================================
# Helpers
# ==============================================================================

echo_info() { echo -e "\033[0;36m[INFO]\033[0m $*"; }
echo_ok() { echo -e "\033[0;32m[OK]\033[0m $*"; }
echo_warn() { echo -e "\033[0;33m[WARN]\033[0m $*"; }
echo_error() { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

# Pick the first home dir that owns an *arr config; fall back to SERVICE_USER.
_pick_user() {
    for d in /home/*/; do
        [[ -d "${d}.config/Sonarr" || -d "${d}.config/Radarr" ]] || continue
        basename "$d"
        return
    done
    echo "$SERVICE_USER"
}

# ==============================================================================
# Cleanup Trap (rollback partial install)
# ==============================================================================
_cleanup_needed=false
_unit_written=""
_script_written=""

cleanup() {
    local exit_code=$?
    if [[ "$_cleanup_needed" == "true" && $exit_code -ne 0 ]]; then
        echo_error "Installation failed (exit $exit_code). Cleaning up..."
        [[ -n "$_unit_written" ]] && {
            systemctl stop "$SERVICE_NAME" 2>/dev/null || true
            systemctl disable "$SERVICE_NAME" 2>/dev/null || true
            rm -f "$_unit_written"
            systemctl daemon-reload
        }
        [[ -n "$_script_written" ]] && rm -f "$_script_written"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap '' PIPE

# ==============================================================================
# Install
# ==============================================================================

_install() {
    echo_info "Installing mdblist-filter-proxy..."

    if [[ ! -f "$SCRIPT_SRC" ]]; then
        echo_error "Source script not found: $SCRIPT_SRC"
        exit 1
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        echo_error "python3 is required but not installed"
        exit 1
    fi

    local svc_user
    svc_user=$(_pick_user)
    if ! id "$svc_user" >/dev/null 2>&1; then
        echo_error "Service user '$svc_user' does not exist"
        exit 1
    fi
    echo_ok "Using service user: $svc_user"

    # Refuse to clobber an unrelated process on the chosen port.
    if ss -tlnp 2>/dev/null | grep -q ":${PROXY_PORT} "; then
        local owner
        owner=$(ss -tlnp 2>/dev/null | awk -v p=":${PROXY_PORT}" '$4 ~ p {print $0; exit}')
        if [[ "$owner" != *"$SERVICE_NAME"* && "$owner" != *"python3"* ]]; then
            echo_error "Port ${PROXY_PORT} is in use by another process — set MDBLIST_PROXY_PORT to override"
            echo_error "  $owner"
            exit 1
        fi
    fi

    _cleanup_needed=true

    cp "$SCRIPT_SRC" "$SCRIPT_DST"
    chmod 0755 "$SCRIPT_DST"
    _script_written="$SCRIPT_DST"
    echo_ok "Script deployed to $SCRIPT_DST"

    cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Local mdblist.com filter proxy (drops list items missing required tvdbid/tmdbid that crash Sonarr CustomImport)
Documentation=https://github.com/STiXzoOR/swizzin-scripts/blob/main/mdblist-filter-proxy.sh
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${svc_user}
Group=${svc_user}
Environment=MDBLIST_PROXY_HOST=${PROXY_HOST}
Environment=MDBLIST_PROXY_PORT=${PROXY_PORT}
Environment=MDBLIST_PROXY_TTL=${PROXY_TTL}
ExecStart=/usr/bin/python3 ${SCRIPT_DST}
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

# Hardening
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=true
NoNewPrivileges=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF
    _unit_written="$SERVICE_FILE"
    echo_ok "Service unit created at $SERVICE_FILE"

    systemctl daemon-reload
    systemctl enable --now "$SERVICE_NAME"
    sleep 2

    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        echo_error "Service failed to start"
        journalctl -u "$SERVICE_NAME" --no-pager -n 20
        exit 1
    fi
    echo_ok "Service started"

    # Smoke test against a known-good list
    echo_info "Smoke-testing proxy..."
    local test_path="/lists/garycrawfordgc/latest-tv-shows/json"
    local code
    code=$(curl -sS -m 15 -o /dev/null -w "%{http_code}" "${PROXY_BASE}${test_path}" 2>/dev/null || true)
    if [[ "$code" != "200" ]]; then
        echo_warn "Smoke test got HTTP $code (network or upstream issue, not necessarily fatal)"
    else
        echo_ok "Smoke test: HTTP 200"
    fi

    _cleanup_needed=false

    cat <<EOF

$(echo_ok "Installation complete!")

To use the proxy in Sonarr/Radarr Custom Lists, replace the upstream URL prefix:
  ${UPSTREAM_HOST}/lists/<user>/<slug>/json
->
  ${PROXY_BASE}/lists/<user>/<slug>/json

To repoint *every* existing list whose name starts with [mdblist-auto]:
  bash $0 --rewrite-arr

EOF
}

# ==============================================================================
# Remove
# ==============================================================================

_remove() {
    echo_info "Removing mdblist-filter-proxy..."

    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    rm -f "$SCRIPT_DST"

    echo_ok "Removal complete"
    echo_warn "Lists in Sonarr/Radarr still pointing at ${PROXY_BASE} will break."
    echo_warn "Re-run --rewrite-arr-undo (or edit them manually) before removing."
}

# ==============================================================================
# Repoint *arr lists  (--rewrite-arr [--undo])
# ==============================================================================

_rewrite_arr() {
    local mode="${1:-to-proxy}"
    local from to
    if [[ "$mode" == "undo" ]]; then
        from="$PROXY_BASE"; to="$UPSTREAM_HOST"
        echo_info "Repointing [mdblist-auto] lists back to $UPSTREAM_HOST"
    else
        from="$UPSTREAM_HOST"; to="$PROXY_BASE"
        echo_info "Repointing [mdblist-auto] lists at $PROXY_BASE"
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        echo_error "python3 is required"; exit 1
    fi

    python3 - "$from" "$to" <<'PY'
import json, os, sys, urllib.request, urllib.error, xml.etree.ElementTree as ET
from pathlib import Path

FROM, TO = sys.argv[1], sys.argv[2]

INSTANCES = [
    ("Sonarr",       "v3", ["Sonarr", "sonarr-4k", "sonarr-anime"]),
    ("Radarr",       "v3", ["Radarr", "radarr-4k"]),
]

def discover():
    out = []
    for home in Path("/home").iterdir():
        cfg = home / ".config"
        if not cfg.is_dir(): continue
        for app, ver, dirs in INSTANCES:
            for d in dirs:
                xml = cfg / d / "config.xml"
                if not xml.is_file(): continue
                root = ET.parse(xml).getroot()
                port = root.findtext("Port"); apikey = root.findtext("ApiKey")
                urlbase = (root.findtext("UrlBase") or "").strip("/")
                if port and apikey:
                    out.append((d, app, ver, int(port), apikey, urlbase))
    return out

def call(method, url, apikey, body=None, timeout=20):
    req = urllib.request.Request(url, method=method)
    req.add_header("X-Api-Key", apikey)
    if body is not None:
        req.add_header("Content-Type", "application/json")
        body = json.dumps(body).encode()
    try:
        with urllib.request.urlopen(req, body, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()

total_changed = 0
for inst, app, ver, port, apikey, urlbase in discover():
    base = f"http://localhost:{port}"
    if urlbase: base += f"/{urlbase}"
    base += f"/api/{ver}/importlist"
    status, raw = call("GET", base, apikey)
    if status != 200:
        print(f"  [{inst}] could not list import lists (HTTP {status})")
        continue
    lists = json.loads(raw)
    changed = 0
    for L in lists:
        if "mdblist-auto" not in L.get("name", ""): continue
        any_change = False
        for f in L.get("fields", []):
            v = f.get("value")
            if isinstance(v, str) and v.startswith(FROM):
                f["value"] = v.replace(FROM, TO, 1)
                any_change = True
        if not any_change: continue
        st, _ = call("PUT", f"{base}/{L['id']}", apikey, body=L, timeout=30)
        ok = "OK" if 200 <= st < 300 else f"FAIL HTTP {st}"
        print(f"  [{inst}] id={L['id']:<4} {L['name'][:50]:<50} {ok}")
        if 200 <= st < 300: changed += 1
    total_changed += changed
    print(f"  [{inst}] updated {changed} list(s)")
print(f"Total updated: {total_changed}")
PY
}

# ==============================================================================
# Status
# ==============================================================================

_status() {
    systemctl status "$SERVICE_NAME" --no-pager || true
    echo
    echo_info "Recent log:"
    journalctl -u "$SERVICE_NAME" --no-pager -n 15
}

# ==============================================================================
# Main
# ==============================================================================

case "${1:-}" in
    --remove)
        _remove
        ;;
    --status)
        _status
        ;;
    --rewrite-arr)
        _rewrite_arr to-proxy
        ;;
    --rewrite-arr-undo)
        _rewrite_arr undo
        ;;
    "")
        if systemctl list-unit-files "${SERVICE_NAME}.service" 2>/dev/null | grep -q "${SERVICE_NAME}.service"; then
            echo_info "Already installed. Updating script and restarting..."
            cp "$SCRIPT_SRC" "$SCRIPT_DST"
            chmod 0755 "$SCRIPT_DST"
            systemctl daemon-reload
            systemctl restart "$SERVICE_NAME"
            sleep 2
            systemctl is-active --quiet "$SERVICE_NAME" && echo_ok "Restarted" || {
                echo_error "Service failed to restart"
                journalctl -u "$SERVICE_NAME" --no-pager -n 20
                exit 1
            }
        else
            _install
        fi
        ;;
    *)
        echo "Usage: $0 [--remove | --status | --rewrite-arr | --rewrite-arr-undo]"
        exit 2
        ;;
esac
