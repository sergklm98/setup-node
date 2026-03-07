#!/bin/bash
# Common functions and variables used across setup scripts

# Determine functions.sh location (this file)
# When sourced, BASH_SOURCE[0] points to this file, not the calling script
FUNCTIONS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Repository root is always parent of infra directory (where functions.sh is located)
# This works regardless of where the calling script is located
if [[ -z "${REPO_ROOT:-}" ]]; then
    REPO_ROOT="$(cd "$FUNCTIONS_DIR/.." && pwd)"
fi

# Function to extract value from specified file by key
# Expects key=value format, trims everything after # (comments) in the line, removes quotes and whitespace
get_value() {
    local file="$1"
    local key="$2"
    local default="${3:-}"
    grep "^$key=" "$file" 2>/dev/null | sed 's/#.*$//' | cut -d'=' -f2- | tr -d '[:space:]' | tr -d '"' || echo "$default"
}

# Function to set value in specified file (using key=value format)
set_value() {
    local file="$1"
    local key="$2"
    local value="$3"
    if grep -q "^$key=" "$file" 2>/dev/null; then
        sed -i "s|^$key=.*|$key=$value|" "$file"
    else
        echo "$key=$value" >> "$file"
    fi
}

# Function to get node name from NODE_NAME env var or from creds/node.conf
get_node_name() {
    if [[ -n "${NODE_NAME:-}" ]]; then
        echo "$NODE_NAME"
        return
    fi
    get_value "$NODE_CONF" "NODE_NAME"
}

# Common paths
INFRA_DIR="${INFRA_DIR:-$REPO_ROOT/infra}"
APPS_DIR="${APPS_DIR:-$REPO_ROOT/apps}"
CREDS_DIR="${CREDS_DIR:-$REPO_ROOT/creds}"
SSH_KEYS_DIR="${SSH_KEYS_DIR:-$CREDS_DIR/ssh}"
MOUNTS_DIR="${MOUNTS_DIR:-$CREDS_DIR/mounts}"
NODE_CONF="${NODE_CONF:-$CREDS_DIR/node.conf}"
NODE_NAME="${NODE_NAME:-$(get_node_name)}"
NODE_DIR="${NODE_DIR:-$CREDS_DIR/nodes/$NODE_NAME}" # TODO: think to rewrite to get_node_dir and trigger it avary time

# Function to get value from configuration file with fallback
# Usage: get_conf_value key [app]
#   key - required: key to search for
#   app - optional: if specified, search in <app>.conf then both node.conf files
get_conf_value() {
    local key="$1"
    local app="${2:-}"
    local default="${3:-}"
    local value=""
    
    # If app is specified, try app-specific config
    if [[ -n "$app" ]] && [[ -f "$NODE_DIR/$app.conf" ]]; then
        value=$(get_value "$NODE_DIR/$app.conf" "$key")
        [[ -n "$value" ]] && echo "$value" && return
    fi
    
    # Try node-specific config
    if [[ -f "$NODE_DIR/node.conf" ]]; then
        value=$(get_value "$NODE_DIR/node.conf" "$key")
        [[ -n "$value" ]] && echo "$value" && return
    fi

    # Fallback to global node.conf
    [[ -f "$NODE_CONF" ]] && get_value "$NODE_CONF" "$key" "$default" || echo "$default"
}

# Function to set value in configuration with fallback
# Usage: set_conf_value key value [app]
#   key   - required: key to set
#   value - required: value to set
#   app   - optional: if specified and file exists, write to <app>.conf instead of node.conf
set_conf_value() {
    local key="$1"
    local value="$2"
    local app="${3:-}"
    
    # Try app-specific config first
    if [[ -n "$app" ]] && [[ -f "$NODE_DIR/$app.conf" ]]; then
        set_value "$NODE_DIR/$app.conf" "$key" "$value"
        return
    fi    

    # Try node-specific config
    if [[ -f "$NODE_DIR/node.conf" ]]; then
        set_value "$NODE_DIR/node.conf" "$key" "$value"
        return
    fi

    # Fallback to global node.conf (expected to exist)
    set_value "$NODE_CONF" "$key" "$value"
} # TODO: retest all things after rewriting

# Function to check if IPv4 is private
is_private_ipv4() {
    local ip="$1"
    # Check for 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8
    if [[ "$ip" =~ ^10\. ]] || \
       [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] || \
       [[ "$ip" =~ ^192\.168\. ]] || \
       [[ "$ip" =~ ^127\. ]]; then
        return 0
    fi
    return 1
}

# Function to check if IPv6 is private
is_private_ipv6() {
    local ip="$1"
    # Check for link-local (fe80::/10), ULA (fc00::/7, fd00::/8), loopback (::1)
    if [[ "$ip" =~ ^fe80: ]] || \
       [[ "$ip" =~ ^fc00: ]] || \
       [[ "$ip" =~ ^fd00: ]] || \
       [[ "$ip" == "::1" ]]; then
        return 0
    fi
    return 1
}

is_public_ip() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then   # Check for IPv4 (contains exactly 3 dots, no colons)
        is_private_ipv4 "$ip" && return 1 || return 0
    elif [[ "$ip" == *:* ]]; then   # Check for IPv6 (contains at least one colon)
        is_private_ipv6 "$ip" && return 1 || return 0
    fi
    return 2   # unknown format
}
