#!/bin/bash
# This script starts a local Syncthing container using Docker or Podman for managing node configurations via the Syncthing REST API.
# The script is idempotent - it will skip steps that are already completed.
#
# Steps:
# 1. Detect if Docker or Podman is installed (fail if neither is available).
# 2. Load Syncthing API configuration from creds/node.conf (SYNCTHING_API_URL and SYNCTHING_API_KEY).
# 3. Create persistent mount directories for Syncthing configuration and default folder location in creds/mounts/syncthing.
# 4. Start Syncthing container with:
#    - Mount of the entire setup-node repository at the same path as on host (for path consistency)
#    - Persistent configuration and default folder location from creds/mounts/syncthing
#    - Exposed ports: 8384 (web/API) and 22000/UDP (QUIC sync protocol)
#    Note: TCP port not needed for relay (uses outbound connections) or QUIC-only mode
# 5. Wait for Syncthing to initialize and verify it's accessible via API.
# 6. If API key is not configured, extract it from the container and update creds/node.conf.
# 7. If Device ID is not configured, extract it from the container and update creds/node.conf.

set -euo pipefail

# Source common functions and variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/functions.sh"

# Additional paths specific to this script
SYNCTHING_MOUNT_DIR="$MOUNTS_DIR/syncthing"
CONTAINER_NAME="setup-node-syncthing"

# Step 1: Detect Docker or Podman
echo "=== Starting Local Syncthing ==="
echo ""
echo "Step 1: Detecting Docker or Podman"

if command -v podman >/dev/null 2>&1; then
    CONTAINER_CMD="podman"
    echo "✓ Using Podman"
elif command -v docker >/dev/null 2>&1; then
    CONTAINER_CMD="docker"
    echo "✓ Using Docker"
else
    echo "Error: Neither Docker nor Podman is installed"
    echo "Please install Docker (https://docs.docker.com/get-docker/) or Podman (https://podman.io/getting-started/installation)"
    exit 1
fi

# Step 2: Load Syncthing API configuration
echo ""
echo "Step 2: Loading Syncthing API configuration..."

SYNCTHING_API_URL=$(get_conf_value "SYNCTHING_API_URL" "" "http://localhost:8384")
SYNCTHING_API_KEY=$(get_conf_value "SYNCTHING_API_KEY")
NODE_NAME="${NODE_NAME:-localhost}"

echo "API URL: $SYNCTHING_API_URL"
if [[ -n "$SYNCTHING_API_KEY" ]]; then
    echo "API Key: [configured]"
else
    echo "API Key: [not configured - will be extracted from container]"
fi

# Step 3: Create persistent mount directories
echo ""
echo "Step 3: Setting up persistent mount directories..."

for subdir in config data; do
    DIR_PATH="$SYNCTHING_MOUNT_DIR/$subdir"
    if [[ -d "$DIR_PATH" ]]; then
        echo "✓ Directory already exists: $DIR_PATH"
    else
        mkdir -p "$DIR_PATH"
        # Set proper permissions for Syncthing
        chmod 755 "$DIR_PATH"
        echo "✓ Created directory: $DIR_PATH"
    fi
done

echo "✓ Mount directories prepared: $SYNCTHING_MOUNT_DIR"


# Step 4: Start Syncthing container
echo ""
echo "Step 4: Starting Syncthing container..."

# Check if container already exists
if ! $CONTAINER_CMD ps -a --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
    # Create new container
    echo "Creating new Syncthing container..."
    
    $CONTAINER_CMD run -d \
        --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        -p 127.0.0.1:8384:8384 \
        -p 22000:22000/udp \
        -v "$REPO_ROOT:$REPO_ROOT" \
        -v "$SYNCTHING_MOUNT_DIR/config:/var/syncthing/config" \
        -v "$SYNCTHING_MOUNT_DIR/data:/var/syncthing/data" \
        docker.io/syncthing/syncthing:latest \
        --gui-address=0.0.0.0:8384 \
        --no-browser \
        --no-restart \
        --home=/var/syncthing/config
    
    echo "✓ Syncthing container created and started"
fi

# Container exists, check if running
if $CONTAINER_CMD ps --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
    echo "✓ Syncthing container is already running"
else
    echo "Starting existing Syncthing container..."
    $CONTAINER_CMD start "$CONTAINER_NAME"
    echo "✓ Syncthing container started"
fi

# Step 5: Wait for Syncthing to initialize
echo ""
echo "Step 5: Waiting for Syncthing to initialize..."

MAX_WAIT=10
WAIT_COUNT=4

while [[ $WAIT_COUNT -lt $MAX_WAIT ]]; do
    # Use the health endpoint to check readiness
    HEALTH_JSON=$(curl -sf "$SYNCTHING_API_URL/rest/noauth/health" 2>/dev/null)
    if command -v jq >/dev/null 2>&1; then
        STATUS=$(echo "$HEALTH_JSON" | jq -r '.status')
    else
        # Fallback if jq is unavailable
        STATUS=$(echo "$HEALTH_JSON" | grep -o '"status"\s*:\s*"[^"]*"' | awk -F'"' '{print $4}')
    fi
    if [[ "$STATUS" == "OK" ]]; then
        echo "✓ Syncthing reports ready"
        break
    fi

    echo -n "."
    sleep 1
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

if [[ $WAIT_COUNT -ge $MAX_WAIT ]]; then
    echo ""
    echo "Warning: Syncthing did not report ready within $MAX_WAIT seconds"
    echo "Container logs:"
    $CONTAINER_CMD logs --tail 20 "$CONTAINER_NAME"
    exit 1
fi

# Step 6: Extract API key if not configured
echo ""
if [[ -n "$SYNCTHING_API_KEY" ]]; then
    echo "Step 6: API key already configured, skipping extraction"
else
    echo "Step 6: Extracting API key from Syncthing configuration..."
    
    # Wait for config.xml to be created and contain API key
    CONFIG_XML="$SYNCTHING_MOUNT_DIR/config/config.xml"
    MAX_CONFIG_WAIT=30
    CONFIG_WAIT_COUNT=0
    EXTRACTED_KEY=""
    
    while [[ $CONFIG_WAIT_COUNT -lt $MAX_CONFIG_WAIT ]]; do
        if [[ -f "$CONFIG_XML" ]]; then
            # Extract API key from config.xml (between <apikey> tags)
            # Use sed for portability (works on Alpine/BusyBox)
            EXTRACTED_KEY=$(sed -n 's/.*<apikey>\([^<]*\)<\/apikey>.*/\1/p' "$CONFIG_XML" | head -1 || echo "")
            if [[ -n "$EXTRACTED_KEY" ]]; then
                break
            fi
        fi
        echo -n "."
        sleep 1
        CONFIG_WAIT_COUNT=$((CONFIG_WAIT_COUNT + 1))
    done
    
    if [[ -z "$EXTRACTED_KEY" ]]; then
        echo ""
        echo "Warning: Could not extract API key from config.xml within $MAX_CONFIG_WAIT seconds"
        if [[ -f "$CONFIG_XML" ]]; then
            echo "Config file exists but API key not found. You may need to set it manually in $NODE_CONF"
        else
            echo "Config file not found at $CONFIG_XML. You may need to set the API key manually in $NODE_CONF"
        fi
        exit 1
    else
        SYNCTHING_API_KEY="$EXTRACTED_KEY"
        echo ""
        echo "✓ API key extracted from configuration"
        
        # Update node.conf with the API key
        set_conf_value "SYNCTHING_API_KEY" "$SYNCTHING_API_KEY"
        echo "✓ API key saved to $NODE_CONF"
    fi
fi

# Test API key if available and extract device ID
if [[ -z "$SYNCTHING_API_KEY" ]]; then
    echo "⚠ Warning: API key not available. Skipping configuration steps."
    exit 1
fi

echo ""
echo "Testing API key..."
if ! curl -s -f -H "X-API-Key: $SYNCTHING_API_KEY" "$SYNCTHING_API_URL/rest/system/status" >/dev/null 2>&1; then
    echo "⚠ Warning: API key test failed. The key may be incorrect or Syncthing may not be fully initialized yet."
    echo "  You can test manually with: curl -H \"X-API-Key: $SYNCTHING_API_KEY\" $SYNCTHING_API_URL/rest/system/status"
    exit 1
fi

echo "✓ API key is valid and working"

# Extract device ID from Syncthing system status
echo "Extracting device ID..."
DEVICE_ID=$(curl -s -H "X-API-Key: $SYNCTHING_API_KEY" "$SYNCTHING_API_URL/rest/system/status" 2>/dev/null | jq -r '.myID // empty' 2>/dev/null)

if [[ -z "$DEVICE_ID" ]] || [[ "$DEVICE_ID" == "null" ]]; then
    echo "⚠ Warning: Could not extract device ID from Syncthing API"
    if ! command -v jq >/dev/null 2>&1; then
        echo "  Note: jq is required for device ID extraction. Please install 'jq' and rerun this script."
    fi
    exit 1
fi

echo "✓ Device ID extracted: $DEVICE_ID"

# Update node.conf with device ID
set_conf_value "SYNCTHING_DEVICE_ID" "$DEVICE_ID"
echo "✓ Device ID saved to $NODE_CONF"
# Ask user about relay and protocol priority
echo ""
echo "Configure relay and protocol priority:"
echo "1) Disable relay + prioritize QUIC (for direct connections)"
echo "2) Enable relay + prioritize it (for private networks)"
echo "3) Keep settings as is"
read -p "Choose option [1-3] (default: 3): " RELAY_OPTION
RELAY_OPTION="${RELAY_OPTION:-3}"

# Configure protocol priorities based on selection
if [[ "$RELAY_OPTION" == "3" ]]; then
    echo "Keeping settings as is"
elif [[ "$RELAY_OPTION" == "1" ]]; then
    echo "Configuring: Disable relay + prioritize QUIC..."
    
    RELAY_OPTIONS_PATCH='{"relaysEnabled":false,"connectionPriorityQuicLan":10,\
      "connectionPriorityQuicWan":20,"connectionPriorityTcpLan":30,"connectionPriorityTcpWan":40,\
      "connectionPriorityRelay":50}'
    
    if curl -s -X PATCH -H "X-API-Key: $SYNCTHING_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$RELAY_OPTIONS_PATCH" \
        "$SYNCTHING_API_URL/rest/config/options" >/dev/null 2>&1; then
        echo "✓ Relay disabled and QUIC prioritized"
    else
        echo "⚠ Warning: Failed to update Syncthing options"
        exit 1
    fi
elif [[ "$RELAY_OPTION" == "2" ]]; then
    echo "Configuring: Enable relay + prioritize it..."
    
    RELAY_OPTIONS_PATCH='{"relaysEnabled":true,"connectionPriorityRelay":10,"connectionPriorityTcpLan":20,\
      "connectionPriorityTcpWan":30,"connectionPriorityQuicLan":40,"connectionPriorityQuicWan":50}'
    
    if curl -s -X PATCH -H "X-API-Key: $SYNCTHING_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$RELAY_OPTIONS_PATCH" \
        "$SYNCTHING_API_URL/rest/config/options" >/dev/null 2>&1; then
        echo "✓ Relay enabled and prioritized"
    else
        echo "⚠ Warning: Failed to update Syncthing options"
        exit 1
    fi
fi
# If not option 3, configure global settings, folder defaults, and device defaults
if [[ "$RELAY_OPTION" != "3" ]]; then
    # Update device name
    echo ""
    echo "Updating device name..."
    
    DEVICE_NAME_PATCH="{\"name\":\"$NODE_NAME\"}"
    
    if curl -s -X PATCH -H "X-API-Key: $SYNCTHING_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$DEVICE_NAME_PATCH" \
        "$SYNCTHING_API_URL/rest/config/devices/$DEVICE_ID" >/dev/null 2>&1; then
        echo "✓ Device name set to: $NODE_NAME"
    else
        echo "⚠ Warning: Failed to update device name"
        exit 1
    fi
    
    # Update global options
    echo ""
    echo "Updating global options..."
    
    GLOBAL_OPTIONS_PATCH='{"minHomeDiskFree":{"value":10,"unit":"MB"},"urAccepted":-1}'
    # TODO: disable local discovery (21027)
    
    if curl -s -X PATCH -H "X-API-Key: $SYNCTHING_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$GLOBAL_OPTIONS_PATCH" \
        "$SYNCTHING_API_URL/rest/config/options" >/dev/null 2>&1; then
        echo "✓ Global options updated:"
        echo "  - Min free disk space: 10 MB"
        echo "  - Usage reporting: disabled"
    else
        echo "⚠ Warning: Failed to update global options"
        exit 1
    fi
    
    # Update default folder settings
    echo ""
    echo "Updating default folder settings..."
    
    FOLDER_DEFAULTS_PATCH='{"path":"/var/syncthing/data","ignorePerms":true,"minDiskFree":{"value":100,"unit":"MB"}}'
    
    if curl -s -X PATCH -H "X-API-Key: $SYNCTHING_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$FOLDER_DEFAULTS_PATCH" \
        "$SYNCTHING_API_URL/rest/config/defaults/folder" >/dev/null 2>&1; then
        echo "✓ Default folder settings updated:"
        echo "  - Path: /var/syncthing/data"
        echo "  - Ignore permissions: enabled"
        echo "  - Min free disk space: 100 MB"
    else
        echo "⚠ Warning: Failed to update default folder settings"
        exit 1
    fi
    
    # Update default device settings
    echo ""
    echo "Updating default device settings..."
    
    DEVICE_DEFAULTS_PATCH='{"compression":"always","untrusted":true}'
    
    if curl -s -X PATCH -H "X-API-Key: $SYNCTHING_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$DEVICE_DEFAULTS_PATCH" \
        "$SYNCTHING_API_URL/rest/config/defaults/device" >/dev/null 2>&1; then
        echo "✓ Default device settings updated:"
        echo "  - Compression: all data"
        echo "  - Introducer (untrusted): enabled"
    else
        echo "⚠ Warning: Failed to update default device settings"
        exit 1
    fi
fi

echo ""
echo "=== Local Syncthing Setup Completed ==="
echo "Container: $CONTAINER_NAME"
echo "Web UI: http://localhost:8384"
echo "API URL (health): $SYNCTHING_API_URL/rest/noauth/health"
echo "Configuration: $SYNCTHING_MOUNT_DIR/config"
echo "Data directory: $SYNCTHING_MOUNT_DIR/data"
echo ""
echo "To view logs: $CONTAINER_CMD logs -f $CONTAINER_NAME"
echo "To stop: $CONTAINER_CMD stop $CONTAINER_NAME"
echo "To remove: $CONTAINER_CMD rm -f $CONTAINER_NAME"
