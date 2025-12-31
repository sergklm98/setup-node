#!/bin/bash
# This script configures the server by installing utilities, detecting IP addresses,
# and configuring SSH settings.
# The script is idempotent - it can be run multiple times safely.

set -euo pipefail

# Source common functions and variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/functions.sh"

echo "=== Server Configuration ==="
echo ""

# Step 1: Install required utilities
echo "Step 1: Installing required utilities..."

PACKAGES="jq curl wget iproute2 dnsutils net-tools nftables"

# Read ADDITIONAL_UTILS from node.conf and add to packages (skip commented ones with #)
if [[ -f "$NODE_CONF" ]]; then
    ADDITIONAL_UTILS=$(get_value "$NODE_CONF" "ADDITIONAL_UTILS")
    if [[ -n "$ADDITIONAL_UTILS" ]]; then
        for util in $(echo "$ADDITIONAL_UTILS" | tr ',' ' '); do
            # Skip if starts with #
            if [[ ! "$util" =~ ^# ]]; then
                PACKAGES="$PACKAGES $util"
            fi
        done
    fi
fi

apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq $PACKAGES >/dev/null 2>&1 || true
echo "✓ Utilities installed"

# Step 2: Detect IP addresses and NAT status
echo ""
echo "Step 2: Detecting IP addresses and NAT status..."

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
IPV6_EXTERNAL=$(curl -6 -s --max-time 5 https://api64.ipify.org 2>/dev/null || \
                curl -6 -s --max-time 5 https://ifconfig.me 2>/dev/null || \
                curl -6 -s --max-time 5 https://icanhazip.com 2>/dev/null || true)
# Validate that it's actually IPv6 (contains colons)
if [[ -n "$IPV6_EXTERNAL" ]] && [[ "$IPV6_EXTERNAL" =~ : ]]; then
    echo "IPv6 External: $IPV6_EXTERNAL"
else
    IPV6_EXTERNAL=""
fi

# Determine NAT status by comparing external IPs with local IPs
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

# 3. Other IPv4 addresses (excluding already added, prefix private with #)
for ip in "${IPV4_ALL[@]}"; do
    if [[ "$ip" != "127.0.0.1" ]]; then
        if [[ "$ip" == "$IPV4_EXTERNAL" ]]; then
            continue
        fi
        if is_private_ipv4 "$ip"; then
            NODE_IPS+=("#$ip")
        else
            NODE_IPS+=("$ip")
        fi
    fi
done

# 4. Other IPv6 addresses (excluding already added, prefix private with #)
for ip in "${IPV6_ALL[@]}"; do
    if [[ "$ip" != "::1" ]]; then
        if [[ "$ip" == "$IPV6_EXTERNAL" ]]; then
            continue
        fi
        if is_private_ipv6 "$ip"; then
            NODE_IPS+=("#$ip")
        else
            NODE_IPS+=("$ip")
        fi
    fi
done

# Write NODE_IPs to node.conf
if [[ ${#NODE_IPS[@]} -gt 0 ]]; then
    NODE_IPS_STR=$(IFS=','; echo "${NODE_IPS[*]}")
    set_value "$NODE_CONF" "NODE_IPs" "$NODE_IPS_STR"
fi

echo "✓ IP addresses detected and written to node.conf"

# Step 3: Configure SSH
echo ""
echo "Step 3: Configuring SSH..."

SSHD_CONFIG="/etc/ssh/sshd_config"
if [[ ! -f "$SSHD_CONFIG" ]]; then
    echo "Warning: SSH daemon config not found at $SSHD_CONFIG"
    echo "Skipping SSH configuration"
else
    # Backup original config
    if [[ ! -f "${SSHD_CONFIG}.bak" ]]; then
        cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak"
        echo "✓ Created backup of SSH config"
    fi

    # Configure SSH settings
    # Priority: key-based authentication
    # Root login only via key
    # Modern ciphers only
    
    # Enable key-based authentication and disable password for root
    if ! grep -q "^PubkeyAuthentication" "$SSHD_CONFIG"; then
        echo "PubkeyAuthentication yes" >> "$SSHD_CONFIG"
    else
        sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CONFIG"
    fi

    if ! grep -q "^PasswordAuthentication" "$SSHD_CONFIG"; then
        echo "PasswordAuthentication yes" >> "$SSHD_CONFIG"
    else
        sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' "$SSHD_CONFIG"
    fi

    # Root login only via key
    if ! grep -q "^PermitRootLogin" "$SSHD_CONFIG"; then
        echo "PermitRootLogin prohibit-password" >> "$SSHD_CONFIG"
    else
        sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSHD_CONFIG"
    fi

    # Configure modern ciphers (prefer curve-based and modern algorithms)
    if ! grep -q "^HostKeyAlgorithms" "$SSHD_CONFIG"; then
        echo "HostKeyAlgorithms ssh-ed25519,ecdsa-sha2-nistp521,ecdsa-sha2-nistp384,ecdsa-sha2-nistp256,rsa-sha2-512,rsa-sha2-256" >> "$SSHD_CONFIG"
    else
        sed -i 's/^#*HostKeyAlgorithms.*/HostKeyAlgorithms ssh-ed25519,ecdsa-sha2-nistp521,ecdsa-sha2-nistp384,ecdsa-sha2-nistp256,rsa-sha2-512,rsa-sha2-256/' "$SSHD_CONFIG"
    fi

    if ! grep -q "^KexAlgorithms" "$SSHD_CONFIG"; then
        echo "KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp521,ecdh-sha2-nistp384,ecdh-sha2-nistp256,diffie-hellman-group-exchange-sha256" >> "$SSHD_CONFIG"
    else
        sed -i 's/^#*KexAlgorithms.*/KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp521,ecdh-sha2-nistp384,ecdh-sha2-nistp256,diffie-hellman-group-exchange-sha256/' "$SSHD_CONFIG"
    fi

    if ! grep -q "^Ciphers" "$SSHD_CONFIG"; then
        echo "Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr" >> "$SSHD_CONFIG"
    else
        sed -i 's/^#*Ciphers.*/Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr/' "$SSHD_CONFIG"
    fi

    if ! grep -q "^MACs" "$SSHD_CONFIG"; then
        echo "MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256" >> "$SSHD_CONFIG"
    else
        sed -i 's/^#*MACs.*/MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256/' "$SSHD_CONFIG"
    fi

    echo "✓ SSH configuration updated"
    
    # Reload SSH daemon if running (Debian uses systemd)
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet sshd 2>/dev/null || systemctl is-active --quiet ssh 2>/dev/null; then
            echo "Reloading SSH daemon..."
            systemctl reload sshd >/dev/null 2>&1 || systemctl reload ssh >/dev/null 2>&1 || true
        fi
    fi
fi

echo ""
echo "✓ Server configuration completed"

exit 0

