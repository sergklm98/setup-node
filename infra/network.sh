#!/bin/bash
# This script creates a dualstack Podman network (supporting both IPv4 and IPv6) using Quadlet.
# The script is idempotent - it will skip steps that are already completed.
#
# Steps:
# 1. Check if Podman is installed and running.
# 2. Read network configuration from creds/node.conf (NETWORK_IP4_CIDR required, NETWORK_IP6_CIDR optional).
# 3. Install aardvark-dns and netavark if not present.
# 4. Create default containers.conf for logging configuration.
# 5. Create Podman network using Quadlet .network file.
# 6. Verify the network creation and list available networks.

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

# Function to get PODMAN_BIN from config or default to podman
get_podman_bin() {
    if [[ -f "$NODE_CONF" ]]; then
        local podman_bin=$(get_value "$NODE_CONF" "PODMAN_BIN")
        if [[ -n "$podman_bin" ]]; then
            echo "$podman_bin"
            return
        fi
    fi
    echo "podman"
}

PODMAN_BIN=$(get_podman_bin)
NETWORK_NAME="main"

echo "=== Podman Network Setup ==="
echo ""

# Step 1: Check if Podman is installed and running
echo "Step 1: Checking Podman installation..."
if ! command -v "$PODMAN_BIN" >/dev/null 2>&1; then
    echo "Error: $PODMAN_BIN is not installed"
    echo "Please run infra/podman.sh first"
    exit 1
fi

if ! $PODMAN_BIN ps -a >/dev/null 2>&1; then
    echo "Error: $PODMAN_BIN is installed but not working"
    exit 1
fi
echo "✓ Podman is installed and working"

# Step 2: Read network configuration
echo ""
echo "Step 2: Reading network configuration..."
if [[ ! -f "$NODE_CONF" ]]; then
    echo "Error: Node configuration file not found: $NODE_CONF"
    exit 1
fi

NETWORK_IP4_CIDR=$(get_value "$NODE_CONF" "NETWORK_IP4_CIDR")
NETWORK_IP6_CIDR=$(get_value "$NODE_CONF" "NETWORK_IP6_CIDR")

if [[ -z "$NETWORK_IP4_CIDR" ]]; then
    echo "Error: NETWORK_IP4_CIDR is not set in $NODE_CONF"
    echo "Please set NETWORK_IP4_CIDR (e.g., NETWORK_IP4_CIDR=10.88.0.0/16)"
    exit 1
fi

echo "IPv4 CIDR: $NETWORK_IP4_CIDR"
if [[ -n "$NETWORK_IP6_CIDR" ]]; then
    echo "IPv6 CIDR: $NETWORK_IP6_CIDR"
    echo "Creating dualstack network (IPv4 + IPv6)"
else
    echo "Creating IPv4-only network"
fi

# Check if network already exists
if $PODMAN_BIN network exists "$NETWORK_NAME" >/dev/null 2>&1; then
    echo ""
    echo "✓ Network '$NETWORK_NAME' already exists"
    echo "Network details:"
    $PODMAN_BIN network inspect "$NETWORK_NAME" 2>/dev/null | jq -r '(.Name, .Subnet, .IPv6Subnet)' 2>/dev/null || \
        $PODMAN_BIN network inspect "$NETWORK_NAME" 2>/dev/null | grep -E "(Name|Subnet|IPv6Subnet)" || true
    echo ""
    echo "Available networks:"
    $PODMAN_BIN network ls
    echo ""
    echo "Network setup completed successfully!"
    exit 0
fi

# Step 3: Install aardvark-dns and netavark if not present
echo ""
echo "Step 3: Checking network dependencies..."

apt-get install -y -qq aardvark-dns netavark >/dev/null 2>&1
echo "✓ Network dependencies installed"

# Step 4: Create default containers.conf for logging
echo ""
echo "Step 4: Configuring container logging..."
CONTAINERS_CONF="/etc/containers/containers.conf"
if [[ ! -f "$CONTAINERS_CONF" ]] || ! grep -q "\[containers\]" "$CONTAINERS_CONF" 2>/dev/null; then
    echo "Creating default containers.conf..."
    mkdir -p /etc/containers
    cat <<'EOF' > "$CONTAINERS_CONF"
[containers]
log_driver = "json-file"
log_size_max = 52428800
EOF
    echo "✓ Default containers.conf created"
else
    echo "✓ $CONTAINERS_CONF already exists"
fi

# Step 5: Create Podman network using Quadlet
echo ""
echo "Step 5: Creating Podman network using Quadlet..."
# Create Quadlet network directory
QUADLET_NETWORK_DIR="/etc/containers/systemd"
mkdir -p "$QUADLET_NETWORK_DIR"

# Create .network file for Quadlet
NETWORK_FILE="$QUADLET_NETWORK_DIR/${NETWORK_NAME}.network"

echo "Creating Quadlet network file: $NETWORK_FILE"
cat > "$NETWORK_FILE" <<EOF
[Network]
NetworkName=$NETWORK_NAME
Subnet=$NETWORK_IP4_CIDR
EOF
    
# Add IPv6 subnet if provided
if [[ -n "$NETWORK_IP6_CIDR" ]]; then
    echo "IPv6=true" >> "$NETWORK_FILE"
    echo "Subnet=$NETWORK_IP6_CIDR" >> "$NETWORK_FILE"
fi

# Reload systemd to pick up the new network file
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    
    # Start the network service (Quadlet will create the network)
    echo "Starting network service..."
    systemctl start "${NETWORK_NAME}-network.service" 2>/dev/null || true
    
    # Wait a moment for network to be created
    sleep 1
fi

# Verify network was created by Quadlet, if not create manually
if ! $PODMAN_BIN network exists "$NETWORK_NAME" >/dev/null 2>&1; then
    echo "Network not created by Quadlet, creating manually..."
    if [[ -n "$NETWORK_IP6_CIDR" ]]; then
        $PODMAN_BIN network create --subnet "$NETWORK_IP4_CIDR" --ipv6 --subnet "$NETWORK_IP6_CIDR" "$NETWORK_NAME"
    else
        $PODMAN_BIN network create --subnet "$NETWORK_IP4_CIDR" "$NETWORK_NAME"
    fi
fi

echo "✓ Network '$NETWORK_NAME' created successfully"

# Step 6: Verify network creation
echo ""
echo "Step 6: Verifying network..."
if $PODMAN_BIN network exists "$NETWORK_NAME" >/dev/null 2>&1; then
    echo "✓ Network '$NETWORK_NAME' is available"
    echo ""
    echo "Network information:"
    $PODMAN_BIN network inspect "$NETWORK_NAME" 2>/dev/null | grep -E "(Name|Subnet|IPv6Subnet|Driver)" || true
    echo ""
    echo "Available networks:"
    $PODMAN_BIN network ls
else
    echo "Error: Network '$NETWORK_NAME' was not created"
    exit 1
fi

echo ""
echo "Network setup completed successfully!"
