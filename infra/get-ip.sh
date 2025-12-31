#!/bin/bash
# This script detects private/public IP addresses (IPv4/IPv6) and NAT status,
# then writes the results to creds/node.conf.
# The script is idempotent - it can be run multiple times safely.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NODE_CONF="$REPO_ROOT/creds/node.conf"

# Function to extract value from key=value format (removes quotes and whitespace)
get_value() {
    local file="$1"
    local key="$2"
    grep "^$key=" "$file" 2>/dev/null | cut -d'=' -f2- | tr -d '[:space:]' | tr -d '"'
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

echo "=== IP Address Detection ==="
echo ""

# Collect all IP addresses
IPV4_ALL=()
IPV6_ALL=()

if command -v ip >/dev/null 2>&1; then
    # Get all IPv4 addresses
    while IFS= read -r line; do
        # Extract IP from "inet 192.168.1.1/24" format
        ip=$(echo "$line" | awk '{print $2}' | cut -d'/' -f1)
        if [[ -n "$ip" ]] && [[ "$ip" != "127.0.0.1" ]]; then
            IPV4_ALL+=("$ip")
        fi
    done < <(ip -4 addr show 2>/dev/null | grep 'inet ' || true)

    # Get all IPv6 addresses
    while IFS= read -r line; do
        # Extract IP from "inet6 2001:db8::1/64" format
        ip_full=$(echo "$line" | awk '{print $2}' | cut -d'/' -f1)
        if [[ -n "$ip_full" ]] && [[ "$ip_full" != "::1" ]]; then
            # Remove scope identifier (e.g., fe80::1%eth0 -> fe80::1)
            ip="${ip_full%%%*}"
            IPV6_ALL+=("$ip")
        fi
    done < <(ip -6 addr show 2>/dev/null | grep 'inet6 ' || true)
fi

# Get external IP addresses (IPv4 and IPv6)
IPV4_EXTERNAL=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
                curl -s --max-time 5 https://ifconfig.me 2>/dev/null || \
                wget -qO- --timeout=5 https://api.ipify.org 2>/dev/null || \
                wget -qO- --timeout=5 https://ifconfig.me 2>/dev/null || true)
# Validate that it's actually IPv4 (contains dots, no colons)
if [[ -n "$IPV4_EXTERNAL" ]] && [[ "$IPV4_EXTERNAL" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "IPv4 External: $IPV4_EXTERNAL"
else
    IPV4_EXTERNAL=""
fi

# Try to get IPv6 external (force IPv6 connection)
IPV6_EXTERNAL=$(curl -6 -s --max-time 5 https://api6.ipify.org 2>/dev/null || \
                curl -6 -s --max-time 5 https://ifconfig.co 2>/dev/null || \
                curl -6 -s --max-time 5 https://ipv6.icanhazip.com 2>/dev/null || true)
# Validate that it's actually IPv6 (contains colons)
if [[ -n "$IPV6_EXTERNAL" ]] && [[ "$IPV6_EXTERNAL" =~ : ]]; then
    echo "IPv6 External: $IPV6_EXTERNAL"
else
    IPV6_EXTERNAL=""
fi

# Determine NAT status by comparing external IPs with local IPs
# If external IP is empty, protocol is not available (not NAT, just no internet access via that protocol)
# If external IP exists but doesn't match local IP, server is behind NAT
# If external IP exists and matches local IP, server has direct internet access (no NAT)

NAT_STATUS="unknown"
IPV4_NAT="yes"
IPV6_NAT="yes"

# Check if external IPv4 matches any local IPv4
if [[ -n "$IPV4_EXTERNAL" ]]; then
    for ip in "${IPV4_ALL[@]}"; do
        if [[ "$ip" == "$IPV4_EXTERNAL" ]]; then
            IPV4_NAT="no"
            break
        fi
    done
else
    IPV4_NAT="no"
fi

# Check if external IPv6 matches any local IPv6
if [[ -n "$IPV6_EXTERNAL" ]]; then
    for ip in "${IPV6_ALL[@]}"; do
        if [[ "$ip" == "$IPV6_EXTERNAL" ]]; then
            IPV6_NAT="no"
            break
        fi
    done
else
    IPV6_NAT="no"
fi

# Set NAT status based on the results
if [[ "$IPV4_NAT" == "yes" && "$IPV6_NAT" == "yes" ]]; then
    NAT_STATUS="both"
    # Both behind NAT, so remove both externals
    IPV4_EXTERNAL=""
    IPV6_EXTERNAL=""
elif [[ "$IPV6_NAT" == "yes" ]]; then
    NAT_STATUS="IPv6"
    # IPv6 NAT, so remove IPV6_EXTERNAL
    IPV6_EXTERNAL=""
elif [[ "$IPV4_NAT" == "yes" ]]; then
    NAT_STATUS="IPv4"
    # IPv4 NAT, so remove IPV4_EXTERNAL
    IPV4_EXTERNAL=""
elif [[ "$IPV4_NAT" == "no" && "$IPV6_NAT" == "no" ]]; then
    NAT_STATUS="no"
    # Neither behind NAT, keep externals
else
    NAT_STATUS="unknown"
fi
echo "NAT Status: $NAT_STATUS"

# Separate IPs for display
IPV4_PRIVATE=()
IPV4_PUBLIC=()
IPV6_PRIVATE=()
IPV6_PUBLIC=()

for ip in "${IPV4_ALL[@]}"; do
    if is_private_ipv4 "$ip"; then
        IPV4_PRIVATE+=("$ip")
    else
        IPV4_PUBLIC+=("$ip")
    fi
done

for ip in "${IPV6_ALL[@]}"; do
    if is_private_ipv6 "$ip"; then
        IPV6_PRIVATE+=("$ip")
    else
        IPV6_PUBLIC+=("$ip")
    fi
done

# Display results
if [[ ${#IPV4_PRIVATE[@]} -gt 0 ]]; then
    echo "IPv4 Private: $(IFS=','; echo "${IPV4_PRIVATE[*]}")"
fi
if [[ ${#IPV4_PUBLIC[@]} -gt 0 ]]; then
    echo "IPv4 Public: $(IFS=','; echo "${IPV4_PUBLIC[*]}")"
fi
if [[ ${#IPV6_PRIVATE[@]} -gt 0 ]]; then
    echo "IPv6 Private: $(IFS=','; echo "${IPV6_PRIVATE[*]}")"
fi
if [[ ${#IPV6_PUBLIC[@]} -gt 0 ]]; then
    echo "IPv6 Public: $(IFS=','; echo "${IPV6_PUBLIC[*]}")"
fi

# Build NODE_IPs in order: public IPv4 (no NAT), public IPv6 (no NAT), other IPv4, other IPv6
NODE_IPS=()

# 1. Public IPv4 without NAT (if external IPv4 matches one of our IPv4)
if [[ -n "$IPV4_EXTERNAL" ]]; then
    NODE_IPS+=("$IPV4_EXTERNAL")
fi

# 2. Public IPv6 without NAT (if external IPv6 matches one of our IPv6)
if [[ -n "$IPV6_EXTERNAL" ]]; then
    NODE_IPS+=("$IPV6_EXTERNAL")
fi

# 3. Other IPv4 addresses (excluding already added)
for ip in "${IPV4_ALL[@]}"; do
    if [[ "$ip" != "127.0.0.1" ]]; then
        if [[ "$ip" == "$IPV4_EXTERNAL" ]]; then
            continue
        fi
        NODE_IPS+=("$ip")
    fi
done

# 4. Other IPv6 addresses (excluding already added)
for ip in "${IPV6_ALL[@]}"; do
    if [[ "$ip" != "::1" ]]; then
        if [[ "$ip" == "$IPV6_EXTERNAL" ]]; then
            continue
        fi
        NODE_IPS+=("$ip")
    fi
done

# Write NODE_IPs to node.conf
if [[ ${#NODE_IPS[@]} -gt 0 ]]; then
    NODE_IPS_STR=$(IFS=','; echo "${NODE_IPS[*]}")
    set_value "$NODE_CONF" "NODE_IPs" "$NODE_IPS_STR"
fi

echo "✓ IP addresses detected and written to node.conf"

exit 0
