#!/bin/bash
# ==============================================================================
# Nginx Utilities - Shared helper functions for nginx management
# ==============================================================================
# Source this file from scripts that need to reload nginx:
#   . "${SCRIPT_DIR}/lib/nginx-utils.sh" 2>/dev/null || true
#
# Provides:
#   _reload_nginx  - Validate config then reload (returns 1 on failure)
# ==============================================================================

_reload_nginx() {
    if [[ -f /install/.nginx.lock ]]; then
        local test_output
        if test_output=$(nginx -t 2>&1); then
            systemctl reload nginx
        else
            echo_error "Nginx configuration test failed:"
            echo_error "$test_output"
            return 1
        fi
    fi
}
