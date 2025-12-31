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

# Common paths
INFRA_DIR="${INFRA_DIR:-$REPO_ROOT/infra}"
APPS_DIR="${APPS_DIR:-$REPO_ROOT/apps}"
CREDS_DIR="${CREDS_DIR:-$REPO_ROOT/creds}"
NODE_CONF="${NODE_CONF:-$CREDS_DIR/node.conf}"
NODES_DIR="${NODES_DIR:-$CREDS_DIR/nodes}"
SSH_KEYS_DIR="${SSH_KEYS_DIR:-$CREDS_DIR/ssh}"
MOUNTS_DIR="${MOUNTS_DIR:-$CREDS_DIR/mounts}"

# Function to extract value from key=value format (removes quotes and whitespace)
# Trims everything after # (comments) in the line
get_value() {
    local file="$1"
    local key="$2"
    grep "^$key=" "$file" 2>/dev/null | sed 's/#.*$//' | cut -d'=' -f2- | tr -d '[:space:]' | tr -d '"'
}

# Function to set value in config file
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

