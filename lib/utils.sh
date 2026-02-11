#!/bin/bash
# ==============================================================================
# Shared Utilities - General helper functions for swizzin scripts
# ==============================================================================
# Source this file from scripts that need these helpers:
#   . "${SCRIPT_DIR}/lib/utils.sh" 2>/dev/null || true
#
# Provides:
#   _sed_escape_value  - Escape a string for safe use in sed replacement
# ==============================================================================

# Escape a string for safe use in sed replacement (right-hand side of s|...|...|)
# Handles: & (backreference), \ (escape char), | (delimiter), newlines
# Usage: sed -i "s|pattern|$(_sed_escape_value "$value")|" file
_sed_escape_value() {
    printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}
