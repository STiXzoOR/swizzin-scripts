#!/bin/bash
# ==============================================================================
# Shared Utilities - General helper functions for swizzin scripts
# ==============================================================================
# Source this file from scripts that need these helpers:
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/utils.sh" 2>/dev/null || true
#
# Provides:
#   port (override)    - SIGPIPE-safe replacement for Swizzin's port()
#   _sed_escape_value  - Escape a string for safe use in sed replacement
# ==============================================================================

# Override Swizzin's port() to avoid SIGPIPE under set -o pipefail.
# Upstream uses `shuf | head -n 1` which triggers broken pipe errors.
# Fix: use `shuf -n 1` to pick one random line without a pipe.
port() {
    comm -23 \
        <(seq "$1" "$2" | sort) \
        <(ss -Htan | awk '{print $4}' | cut -d':' -f2 | sort -u) \
        | shuf -n 1
}

# Escape a string for safe use in sed replacement (right-hand side of s|...|...|)
# Handles: & (backreference), \ (escape char), | (delimiter), newlines
# Usage: sed -i "s|pattern|$(_sed_escape_value "$value")|" file
_sed_escape_value() {
    printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}
